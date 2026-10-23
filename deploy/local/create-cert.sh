#!/bin/sh
set -eu
base="$(dirname "$0")"
certs="$base/certs"
if [ -e "$certs/ca.key" ] || [ -e "$certs/localhost.key" ]; then
    printf '%s\n' 'Certificates already exist; remove them explicitly before regenerating.' >&2
    exit 1
fi
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -sha256 \
    -subj '/CN=RoadScout Local Development CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$certs/ca.key" -out "$certs/ca.crt"
openssl req -new -newkey rsa:2048 -nodes -subj '/CN=localhost' \
    -keyout "$certs/localhost.key" -out "$certs/localhost.csr"
openssl x509 -req -in "$certs/localhost.csr" -CA "$certs/ca.crt" \
    -CAkey "$certs/ca.key" -CAcreateserial -days 90 -sha256 \
    -extfile "$base/localhost.ext" -out "$certs/localhost.crt"
