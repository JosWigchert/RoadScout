#!/usr/bin/env sh
set -eu

case "${1:-}" in
  staging|production) DEPLOY_TARGET="$1" ;;
  *) echo 'Usage: sh scripts/deploy-nas.sh staging|production' >&2; exit 2 ;;
esac

repo_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
NAS_ENV_FILE="${NAS_ENV_FILE:-/mnt/user/appdata/roadscout/$DEPLOY_TARGET.env}"
RELEASE_ID="${RELEASE_ID:-${GITHUB_SHA:-$(git -C "$repo_root" rev-parse HEAD)}}"
export DEPLOY_TARGET NAS_ENV_FILE RELEASE_ID

case "$NAS_ENV_FILE" in
  /*) ;;
  *) echo 'NAS_ENV_FILE must be an absolute path' >&2; exit 2 ;;
esac
case "$RELEASE_ID" in
  ''|*[!a-zA-Z0-9_.-]*) echo 'Invalid release ID' >&2; exit 2 ;;
esac
if [ ! -f "$NAS_ENV_FILE" ]; then
  echo "Missing NAS environment file: $NAS_ENV_FILE" >&2
  exit 1
fi

compose() {
  docker compose --project-name "roadscout-$DEPLOY_TARGET" \
    --env-file "$NAS_ENV_FILE" -f "$repo_root/deploy/compose.nas.yaml" "$@"
}

# Compose parses the NAS file; never source it as shell code or print its contents.
compose config --quiet
deploy_url="$(compose config --format json | python3 -c 'import json,sys; c=json.load(sys.stdin); e=c["services"]["routing-api"]["environment"]; print("https://" + e["ROUTING_HOST"])')"
compose build --pull
if ! compose up -d --wait --wait-timeout 120; then
  compose ps >&2 || true
  compose logs --tail 100 >&2 || true
  exit 1
fi
if ! compose exec -T routing-api wget -q -T 20 -O /dev/null http://127.0.0.1:8080/readyz; then
  echo 'API started, but Valhalla readiness failed' >&2
  compose logs --tail 100 >&2 || true
  exit 1
fi

echo "Deployed $DEPLOY_TARGET ($RELEASE_ID): $deploy_url"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "url=$deploy_url" >> "$GITHUB_OUTPUT"
fi
