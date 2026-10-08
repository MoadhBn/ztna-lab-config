#!/bin/bash
# pin-images.sh - pin every service image in docker-compose.yml to the digest
# of the image its running container uses (pins what was tested, not what the tag points to now).
set -u
cd ~/ztna
for s in $(docker compose config --services); do
    cid=$(docker compose ps -q "$s")
    if [ -z "$cid" ]; then echo "SKIP $s: not running"; continue; fi
    img=$(docker inspect --format '{{.Config.Image}}' "$cid")        # reference as written in compose
    case "$img" in *@sha256:*) echo "OK   $s already pinned"; continue ;; esac
    iid=$(docker inspect --format '{{.Image}}' "$cid")               # local ID of the running image
    digest=$(docker image inspect --format '{{range .RepoDigests}}{{.}}{{"\n"}}{{end}}' "$iid" \
             | grep -m1 "^${img%:*}@" | cut -d@ -f2)                  # registry digest of that image
    if [ -z "$digest" ]; then echo "FAIL $s: no registry digest for $img"; continue; fi
    sed -i "s|image: ${img}\$|image: ${img}@${digest}|" docker-compose.yml
    echo "PIN  $s  ${img}@${digest}"
done
