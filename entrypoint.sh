#!/bin/sh
# Start crond as root (needs root to run user crontabs), then exec start.sh as freeciv.
# Uses setpriv so start.sh replaces this process (PID 1) and receives signals directly.
FREECIV_UID=$(id -u freeciv)
FREECIV_GID=$(id -g freeciv)

# Ensure /data/saves is writable by freeciv (Fly volume mounts as root)
chown freeciv:freeciv /data/saves

busybox crond -c /etc/crontabs -L /dev/stderr
exec setpriv --reuid="$FREECIV_UID" --regid="$FREECIV_GID" --init-groups /opt/freeciv/start.sh
