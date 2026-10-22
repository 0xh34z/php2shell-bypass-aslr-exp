#!/bin/bash
# Isolated lab target: official php:8.4.26-apache + stock php.ini-production.
#
# The target keeps the official config untouched:
#   display_errors=Off, memory_limit=128M, post_max_size=8M, single prefork worker.
# The exploit path is HTTP only; gdb is not required and is not used.
#
# Container: p2s-pure-18110, port 18110, workspace ./out (proof files).
#
# usage:
#   ./run_pure.sh             # recreate the container with php:8.4.26-apache
#   ./run_pure.sh --dbg       # same build with symbols + gdb (calibration only)
#   IMAGE=... ./run_pure.sh   # explicit image override
set -eu

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
R=$(cd "$HERE/.." && pwd)

if [ -n "${DOCKER:-}" ]; then
  :
elif docker info >/dev/null 2>&1; then
  DOCKER=docker
else
  DOCKER="sudo docker"
fi
IMAGE=${IMAGE:-php:8.4.26-apache}
NAME=${NAME:-p2s-pure-18110}
PORT=${PORT:-18110}
CAP=""

if [ "${1:-}" = "--dbg" ]; then
  IMAGE=${IMAGE_DBG:-php2shell-dbg:gdb}
  CAP="--cap-add=SYS_PTRACE"
fi

# shellcheck disable=SC2086
$DOCKER rm -f "$NAME" >/dev/null 2>&1 || true
mkdir -p "$R/out"

# shellcheck disable=SC2086
$DOCKER run -d --name "$NAME" $CAP \
  -p "127.0.0.1:$PORT:80" \
  -v "$R/docker/apache.conf:/etc/apache2/conf-enabled/zz-p2s.conf:ro" \
  -v "$R/docker/www:/var/www/html:ro" \
  -v "$R/out:/out" \
  "$IMAGE" /bin/sh -c \
  'cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini;
   chown -R www-data:www-data /out 2>/dev/null || true;
   exec apache2-foreground' >/dev/null

for _ in $(seq 1 40); do
  if curl -s -m 2 "http://127.0.0.1:$PORT/index.php" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
echo "target: $(curl -s -m 3 "http://127.0.0.1:$PORT/index.php")"
$DOCKER exec "$NAME" php -v | head -1
$DOCKER exec "$NAME" php -i 2>/dev/null | \
  grep -E '^display_errors|^display_startup_errors|^memory_limit|^post_max_size|^output_buffering|^session.sid_length|^session.use_strict_mode|^session.save_path|^max_file_uploads|^max_input_vars|^max_multipart_body_parts' | head -20
