#!/bin/bash
# ztna-detect.sh - ZTNA detection rules R1-R7 over the LOG1 collector.
# Runs every 5 minutes as user ztnadetect (systemd timer ztna-detect.timer).
# Reads only the lines added to /var/log/ztna/all.log since the previous run;
# alerts go to /var/log/ztna-detect/alerts.log and to syslog (tag ztna-detect).
set -u
export LC_ALL=C

LOG=/var/log/ztna/all.log
STATE=/var/lib/ztna-detect
ALERTS=/var/log/ztna-detect/alerts.log
MAP=$STATE/kc-users            # Keycloak userId -> username, learned from LOGIN events

# Thresholds (per 5-minute window unless stated otherwise)
R1_TARGETS=10   # distinct destination host:port pairs blocked by FW1 for one source
R2_BLOCKS=3     # ufw blocks from one source on one host
R3_REJECTS=3    # RADIUS rejects for one user
R4_ERRORS=3     # Keycloak login errors for one user
R5_DENIES=3     # nginx / oauth2-proxy denials for one client and application
R6_SKEW=60      # seconds between event time and reception time (latest line of a host)
R7_SILENT=900   # seconds without any line from an expected host
EXPECTED_HOSTS="fw1.ztna.lab radius1 appserver log1"

# Shared gawk helpers. Values copied into alerts come from log lines, some of them
# attacker-controlled (usernames typed at a login page), so clean() keeps only safe
# characters and limits the length.
LIB='
function clean(s) { gsub(/[^A-Za-z0-9@._:\/=-]/, "?", s); return substr(s, 1, 64) }
function kv(k,   m) { return match($0, "(^|[ ,])" k "=\"([^\"]*)\"", m) ? m[2] : "" }
function ts(t,   m, s) {
    if (!match(t, /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?(Z|([+-])([0-9]{2}):([0-9]{2}))$/, m)) return ""
    s = mktime(m[1] " " m[2] " " m[3] " " m[4] " " m[5] " " m[6], 1)
    if (m[8] != "Z") s -= (m[9] == "-" ? -1 : 1) * (m[10] * 3600 + m[11] * 60)
    return s
}
'

# ---- Lines added since the previous run ------------------------------------------
CHUNK=$(mktemp "$STATE/chunk.XXXXXX")
trap 'rm -f "$CHUNK"' EXIT
size=$(stat -c %s "$LOG")
if [ -f "$STATE/offset" ]; then
    offset=$(cat "$STATE/offset")
    if [ "$size" -lt "$offset" ]; then
        # all.log was rotated: finish the previous file, then read the new one from the start
        [ -f "$LOG.1" ] && tail -c +"$((offset + 1))" "$LOG.1" >> "$CHUNK"
        offset=0
    fi
    tail -c +"$((offset + 1))" "$LOG" | head -c "$((size - offset))" >> "$CHUNK"
    # An incomplete last line is left for the next run
    if [ -s "$CHUNK" ] && [ -n "$(tail -c 1 "$CHUNK")" ]; then
        partial=$(tail -n 1 "$CHUNK" | wc -c)
        truncate -s -"$partial" "$CHUNK"
        size=$((size - partial))
    fi
fi
# On the first run nothing is read: detection starts from the current end of the file
echo "$size" > "$STATE/offset"

alert() {   # $1 rule, $2 severity, $3 details
    local now
    now=$(date '+%Y-%m-%dT%H:%M:%S%:z')
    printf '%s ALERT %s %s %s\n' "$now" "$1" "$2" "$3" >> "$ALERTS"
    logger -t ztna-detect -p auth.warning "ALERT $1 $2 $3"
}

# ---- R1: scan - one source blocked by FW1 on many targets ------------------------
r1() {
    gawk -e "$LIB" -v th="$R1_TARGETS" -e '
    $4 ~ /^filterlog/ {
        n = split($NF, f, ",")
        if (n < 22 || f[7] != "block" || f[9] != "4") next
        if (f[17] != "tcp" && f[17] != "udp") next
        src = f[19]; target = f[20] ":" f[22]
        if (!((src, target) in seen)) { seen[src, target] = 1; targets[src]++ }
        blocks[src]++; iface[src] = f[5]
    }
    END {
        for (s in targets) if (targets[s] >= th)
            printf "R1|MEDIUM|scan src=%s targets=%d blocks=%d iface=%s\n", clean(s), targets[s], blocks[s], clean(iface[s])
    }' "$CHUNK"
}

# ---- R2: host firewall - ufw blocks east-west traffic FW1 cannot see -------------
r2() {
    gawk -e "$LIB" -v th="$R2_BLOCKS" -e '
    /\[UFW BLOCK\]/ {
        src = dpt = proto = "-"
        for (i = 5; i <= NF; i++) {
            if ($i ~ /^SRC=/) src = substr($i, 5)
            else if ($i ~ /^PROTO=/) proto = substr($i, 7)
            else if ($i ~ /^DPT=/) dpt = substr($i, 5)
        }
        k = $3 SUBSEP src; n[k]++; last[k] = proto "/" dpt
    }
    END {
        for (k in n) if (n[k] >= th) {
            split(k, p, SUBSEP)
            printf "R2|MEDIUM|host-firewall host=%s src=%s blocks=%d last=%s\n", clean(p[1]), clean(p[2]), n[k], clean(last[k])
        }
    }' "$CHUNK"
}

# ---- R3: RADIUS rejects per user (no RADIUS lockout exists, limitation #18) ------
r3() {
    gawk -e "$LIB" -v th="$R3_REJECTS" -e '
    $4 ~ /^radiusd/ && / Login incorrect/ {
        user = "?"; nas = "?"
        if (match($0, /\[([^]]*)\] \(from client ([^ ]+)/, m)) { user = m[1]; nas = m[2] }
        sub(/\/.*/, "", user)
        n[user]++; via[user] = nas
    }
    END {
        for (u in n) if (n[u] >= th)
            printf "R3|HIGH|radius-rejects user=%s rejects=%d nas=%s\n", clean(u), n[u], clean(via[u])
    }' "$CHUNK"
}

# ---- R4: Keycloak login errors per user (application and admin realms) ----------
r4() {
    # LOGIN_ERROR lines carry only the userId: learn userId -> username from LOGIN lines
    local src=$CHUNK
    [ -f "$MAP" ] || src=$LOG
    gawk -e "$LIB" -e '/ type="LOGIN",/ { u = kv("userId"); n = kv("username"); if (u != "" && n != "") print u, clean(n) }' "$src" >> "$MAP"
    sort -u -o "$MAP" "$MAP"
    gawk -e "$LIB" -v th="$R4_ERRORS" -e '
    ARGIND == 1 { name[$1] = $2; next }
    / type="LOGIN_ERROR",/ {
        uid = kv("userId"); uname = kv("username")
        who = (uid != "" && (uid in name)) ? name[uid] : (uname != "" ? uname : (uid != "" ? "id:" uid : "unknown"))
        k = kv("realmName") SUBSEP who
        n[k]++; ip[k] = kv("ipAddress"); err[k] = kv("error"); cl[k] = kv("clientId")
    }
    END {
        for (k in n) if (n[k] >= th) {
            split(k, p, SUBSEP)
            printf "R4|HIGH|keycloak-login-failures realm=%s user=%s failures=%d ip=%s error=%s client=%s\n", clean(p[1]), clean(p[2]), n[k], clean(ip[k]), clean(err[k]), clean(cl[k])
        }
    }' "$MAP" "$CHUNK"
}

# ---- R5: application denials - wrong place (nginx) or wrong group (oauth2-proxy) -
r5() {
    gawk -e "$LIB" -v th="$R5_DENIES" -e '
    / access forbidden by rule, client: / {
        if (match($0, /client: ([^,]+), server: ([^,]+),/, m)) { k = "wrong-place" SUBSEP m[1] SUBSEP m[2]; n[k]++ }
    }
    / status=403 / && / upstream=403 / {
        if (match($0, /nginx:? ([0-9.]+) host=([^ ]+) /, m)) { k = "wrong-group" SUBSEP m[1] SUBSEP m[2]; n[k]++ }
    }
    END {
        for (k in n) if (n[k] >= th) {
            split(k, p, SUBSEP)
            printf "R5|MEDIUM|%s client=%s app=%s denials=%d\n", p[1], clean(p[2]), clean(p[3]), n[k]
        }
    }' "$CHUNK"
}

# ---- R6: clock skew - event time vs reception time on the latest line of a host --
r6() {
    gawk -e "$LIB" -v th="$R6_SKEW" -e '
    $2 ~ /^rcv=/ {
        ev = ts($1); rc = ts(substr($2, 5))
        if (ev != "" && rc != "") skew[$3] = rc - ev
    }
    END {
        for (h in skew) {
            s = skew[h]; a = (s < 0) ? -s : s
            if (a >= th) printf "R6|MEDIUM|clock-skew host=%s skew_s=%d\n", clean(h), s
        }
    }' "$CHUNK"
}

# ---- R7: source silent - an expected host stopped sending logs ------------------
r7() {
    touch "$STATE/lastseen"
    gawk -e "$LIB" -v now="$(date +%s)" -v th="$R7_SILENT" -v expected="$EXPECTED_HOSTS" -v statef="$STATE/lastseen" -e '
    ARGIND == 1 { seen[$1] = $2; flag[$1] = $3; next }
    $2 ~ /^rcv=/ { cur[$3] = 1 }
    END {
        n = split(expected, hosts, " ")
        for (i = 1; i <= n; i++) {
            h = hosts[i]
            if (h in cur) {
                if (flag[h] == 1) printf "R7|INFO|source-restored host=%s\n", h
                seen[h] = now; flag[h] = 0
            } else if (!(h in seen)) {
                seen[h] = now; flag[h] = 0
            } else if (now - seen[h] >= th && flag[h] != 1) {
                printf "R7|HIGH|source-silent host=%s silent_s=%d\n", h, now - seen[h]
                flag[h] = 1
            }
        }
        printf "" > statef
        for (h in seen) printf "%s %d %d\n", h, seen[h], flag[h] > statef
    }' "$STATE/lastseen" "$CHUNK"
}

{ r1; r2; r3; r4; r5; r6; r7; } | while IFS='|' read -r rule sev details; do
    [ -n "$rule" ] && alert "$rule" "$sev" "$details"
done
exit 0
