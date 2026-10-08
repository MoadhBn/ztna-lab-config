#!/bin/bash
# ztna-digest.sh - readable daily summary of the ZTNA logs and detection alerts.
# Usage: ztna-digest.sh [YYYY-MM-DD]   (default: today)
# Runs hourly as user ztnadetect (ztna-digest.timer), so the current day's digest is
# never more than an hour old, even when LOG1 is powered off in the evening.
set -u
export LC_ALL=C

DAY=${1:-$(date +%F)}
[[ $DAY =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "usage: $0 [YYYY-MM-DD]" >&2; exit 2; }
OUTDIR=/var/log/ztna-detect
STATE=/var/lib/ztna-detect
OUT=$OUTDIR/daily-$DAY.txt

LIB='
function clean(s) { gsub(/[^A-Za-z0-9@._:\/=-]/, "?", s); return substr(s, 1, 64) }
function kv(k,   m) { return match($0, "(^|[ ,])" k "=\"([^\"]*)\"", m) ? m[2] : "" }
'

DAYLOG=$(mktemp "$STATE/digest.XXXXXX")
trap 'rm -f "$DAYLOG"' EXIT
# Every collected line whose event time falls on $DAY (current file and archives)
zcat -f /var/log/ztna/all.log* 2>/dev/null | grep -a "^$DAY" > "$DAYLOG"
touch "$STATE/kc-users" "$OUTDIR/alerts.log"

gawk -e "$LIB" -v day="$DAY" -v now="$(date '+%F %T')" -e '
ARGIND == 1 { name[$1] = $2; next }
ARGIND == 2 {
    if (index($0, day) == 1 && $2 == "ALERT") {
        k = $3 " " $4; alerts[k]++
        if (substr($1, 12, 8) > alast[k]) alast[k] = substr($1, 12, 8)
    }
    next
}
{
    host = ($2 ~ /^rcv=/) ? $3 : $2
    lines[host]++
    t = substr($1, 12, 8); if (t > seen[host]) seen[host] = t
}
/ Login OK: \[/ && match($0, /Login OK: \[([^]]*)\] \(from client ([^ ]+)/, m) { rok[clean(m[1]) "  via " clean(m[2])]++ }
/ Login incorrect/ && match($0, /\[([^]]*)\] \(from client ([^ ]+)/, m) { rbad[clean(m[1]) "  via " clean(m[2])]++ }
/ type="LOGIN",/ { kok[clean(kv("realmName")) "/" clean(kv("clientId")) "  " clean(kv("username")) "  from " clean(kv("ipAddress"))]++ }
/ type="LOGIN_ERROR",/ {
    uid = kv("userId")
    u = (uid != "" && (uid in name)) ? name[uid] : (kv("username") != "" ? kv("username") : "id:" uid)
    kbad[clean(kv("realmName")) "/" clean(kv("clientId")) "  " clean(u) "  " clean(kv("error"))]++
}
/ access forbidden by rule, client: / && match($0, /client: ([^,]+), server: ([^,]+),/, m) { place[clean(m[1]) " -> " clean(m[2])]++ }
/ status=403 / && / upstream=403 / && match($0, /nginx:? ([0-9.]+) host=([^ ]+) /, m) { group[clean(m[1]) " -> " clean(m[2])]++ }
/ filterlog\[/ {
    n = split($NF, f, ",")
    if (n >= 22 && f[7] == "block" && f[9] == "4") {
        fwtotal++; fwsrc[clean(f[19])]++
        if (!((f[19], f[20], f[22]) in fwseen)) { fwseen[f[19], f[20], f[22]] = 1; fwtgt[clean(f[19])]++ }
    }
}
/\[UFW BLOCK\]/ {
    src = "-"
    for (i = 1; i <= NF; i++) if ($i ~ /^SRC=/) src = substr($i, 5)
    ufw[clean(host) " <- " clean(src)]++
}
function section(t) { print ""; print t }
function top(a, max,   k, i) {
    if (length(a) == 0) { print "      (none)"; return }
    PROCINFO["sorted_in"] = "@val_num_desc"; i = 0
    for (k in a) { if (++i > max) break; printf "      %-62s %6d\n", k, a[k] }
}
END {
    print "ZTNA daily digest - " day
    print "Generated " now " from /var/log/ztna/all.log* (event time) and alerts.log"
    section("1. Detection alerts (rule severity: count, latest)")
    if (length(alerts) == 0) print "      (none)"
    else { PROCINFO["sorted_in"] = "@ind_str_asc"; for (k in alerts) printf "      %-14s %5d   latest %s\n", k, alerts[k], alast[k] }
    section("2. Successful logins")
    print "   RADIUS (VPN and pfSense GUI):"; top(rok, 10)
    print "   Keycloak (realm/client  user  source):"; top(kok, 10)
    section("3. Failed logins")
    print "   RADIUS:"; top(rbad, 10)
    print "   Keycloak (realm/client  user  error):"; top(kbad, 10)
    section("4. Denied by nginx context rule (wrong place): client -> app"); top(place, 10)
    section("5. Denied by oauth2-proxy (wrong group): client -> app"); top(group, 10)
    section("6. FW1 blocks: " (fwtotal + 0) " in total; top sources (blocks)"); top(fwsrc, 5)
    print "   distinct targets per source:"; top(fwtgt, 5)
    section("7. Host firewall (ufw) blocks: host <- source"); top(ufw, 10)
    section("8. Log sources: lines and last event time")
    PROCINFO["sorted_in"] = "@ind_str_asc"
    for (h in lines) printf "      %-20s %8d lines   last %s\n", clean(h), lines[h], seen[h]
}' "$STATE/kc-users" "$OUTDIR/alerts.log" "$DAYLOG" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"

# Keep 30 days of digests
find "$OUTDIR" -name 'daily-*.txt' -mtime +30 -delete
exit 0
