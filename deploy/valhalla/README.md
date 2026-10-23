# Valhalla deployment · Phase 2

**Current owner deployment:** reuse the existing Europe graph at `http://Valhalla:8002`. The app calls the Go API, not Valhalla directly. Follow `backend/README.md` and `deploy/compose.api*.yaml` for the NAS/Traefik setup. The bootstrap recipe below is an optional standalone development stack, not a required second import. Its direct-Valhalla TLS proxy does not implement the RoadScout app API.

Uses upstream `ghcr.io/valhalla/valhalla-scripted:3.9.1` (Linux arm64 and amd64), not the archived GIS-OPS image. Upstream documentation: https://github.com/valhalla/valhalla/blob/3.9.1/docker/README.md. Nginx terminates local TLS; production uses your existing Traefik. No Go API or database is needed.

## Local bootstrap

Run from repository root. Requires Docker with Compose v2 (or standalone `docker-compose`), OpenSSL 3 supporting `-addext`, network access and disk space. Allow at least 4 GB VM memory, 2 CPUs and several GB free disk for the initial small graph; larger regions need substantially more. On this Mac the standalone `docker-compose` command is installed; substitute it for `docker compose` if needed.

```sh
sh deploy/local/create-cert.sh
docker compose -f deploy/compose.yaml --profile local up -d
docker compose -f deploy/compose.yaml logs -f valhalla
```

First boot downloads **Utrecht, Netherlands, 2026-10-20**, builds admin/timezone databases and the routing graph, then starts the service. It can take minutes. Data/config/tiles persist in ignored `deploy/valhalla/data/`; do not commit those or the local certificates/keys. Only the TLS proxy binds a host port, on loopback 8443. Build failures/missing tiles are not a healthy route service.

```sh
curl --cacert deploy/local/certs/ca.crt https://localhost:8443/status
curl --fail --cacert deploy/local/certs/ca.crt https://localhost:8443/route \
  -H 'Content-Type: application/json' --data-binary @deploy/valhalla/smoke-request.json
shasum -a 256 deploy/valhalla/data/*.osm.pbf
docker image inspect ghcr.io/valhalla/valhalla-scripted:3.9.1 --format '{{json .RepoDigests}}'
```

Record the PBF checksum, graph build time and resolved image digest with each deployment. The default dated extract gives a reproducible starting snapshot while Geofabrik retains it; archive it with the checksum for long-term rebuilds. Version tags can be retagged: use the recorded `image@sha256:...` digest when promoting to production. Admin/timezone downloads also need archiving for bit-for-bit rebuilds.

### Trust local HTTPS on the simulator

Boot your simulator, then:

```sh
xcrun simctl keychain booted add-root-cert deploy/local/certs/ca.crt
```

Set the app's Valhalla base URL to **https://localhost:8443**. Normal URLSession trust checking remains enabled. No ATS bypass, HTTP routing or insecure certificate delegate is used. Local certificates are development-only, expire, and are not shipped in the app. Regeneration requires explicitly removing old ignored certificates; trust the new CA afterwards.

For a physical phone use your actual public HTTPS hostname below; loopback localhost points at the phone, not your Mac.

## Unraid + existing Traefik

Copy `deploy/` to your server, preserve the graph volume, point DNS at your existing HTTPS ingress, and set:

```sh
export ROUTING_HOST=routing.your-domain.example
export TRAEFIK_NETWORK=proxy
export TRAEFIK_CERT_RESOLVER=letsencrypt
docker compose -f deploy/compose.yaml -f deploy/compose.traefik.yaml config
docker compose -f deploy/compose.yaml -f deploy/compose.traefik.yaml up -d
```

Replace the example hostname, network, resolver and `websecure` entrypoint to match your Traefik. Only `/route` and `/status` are routed. The graph service has no host port. TLS certificates are managed by Traefik; keys stay on the server. Labels provide basic rate/body limits. This is a personal MVP endpoint with no app secrets/accounts: use your VPN/private ingress for private use; review stronger access controls and capacity before public distribution. Do not embed a shared server secret in the app. Confirm external TLS and smoke routes from the phone's network before calling deployment verified.

## Coverage and updates

Utrecht only is not worldwide routing. Outside the extract, routes fail or boundary paths may be incomplete. Use one contiguous Geofabrik extract that covers the full intended drive. To change it, stop this stack, preserve the old graph as a backup, use a fresh data directory, and set `OSM_URL` to another dated HTTPS extract before starting. Do not silently mix overlapping PBFs or serve partially rebuilt graphs. The scripted image reuses an existing tile archive by default; changing `OSM_URL` alone does not refresh an existing graph. For updates build a new graph separately, smoke test it, then switch volumes and restart; retain rollback data.

No elevation/transit/live-traffic import. Auto costing honors available OSM vehicle/access data; toll/highway settings are soft preferences, not guaranteed exclusions. OSM quality, legal rules and MapKit/OSM display alignment require field checks. Stop local services with `docker compose -f deploy/compose.yaml --profile local down` (preserves graph files).
