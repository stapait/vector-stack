#!/bin/sh
set -e
filebeat -e -c /etc/filebeat/filebeat.yml --strict.perms=false &
exec node dist/main.js
