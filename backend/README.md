# RoadScout routing API · Phase 2

Small standard-library Go service. No accounts, database, external packages, or per-GPS-update API. Routing provider selection is server-side; only Valhalla is implemented. The app consumes the normalized contract in `../docs/routing-api.yaml`.

## Local development

Go 1.23+ (verified toolchain recorded in `docs/testing.md`):

```sh
go test -race -timeout 30s ./...
go vet ./...
VALHALLA_BASE_URL=http://192.168.1.111:8002 LISTEN_ADDR=127.0.0.1:8080 go run .
```

The LAN upstream above is a development override only and requires Valhalla to publish that host port. On the NAS use `http://Valhalla:8002` on its shared Docker network. Default listener is `:8080`; `ROUTING_PROVIDER` is `valhalla`. No secret or TLS key is required in Go: Traefik handles public HTTPS. The iPhone accepts HTTPS API URLs only.

## Deploy on the NAS

From the repository root, set the name of the **existing user-defined Docker network** containing the Valhalla container/alias `Valhalla`:

```sh
export VALHALLA_NETWORK=your-existing-valhalla-network
export ROUTING_HOST=roadscout.joswigchert.nl
export TRAEFIK_NETWORK=proxy
export TRAEFIK_CERT_RESOLVER=letsencrypt
docker compose -f deploy/compose.api.yaml -f deploy/compose.api.traefik.yaml config
docker compose -f deploy/compose.api.yaml -f deploy/compose.api.traefik.yaml up -d --build
```

Use the hostname, TLS resolver and `websecure` entrypoint from your actual Traefik setup. Go joins both networks; if they are the same external network, use that name for both variables. Go publishes NAS port **8080**, leaving Valhalla on **8002**. No graph volume or Valhalla image is changed. The supplied Go-only Compose file works without the Traefik overlay for LAN smoke tests.

```sh
curl --fail http://192.168.1.111:8080/healthz
curl --fail http://192.168.1.111:8080/readyz
curl --fail http://192.168.1.111:8080/v1/capabilities
curl --fail http://192.168.1.111:8080/v1/routes \
  -H 'Content-Type: application/json' --data-binary @deploy/route-request.json
```

Repeat the route request via your public HTTPS hostname before configuring it in the app. `/healthz` checks Go; `/readyz` checks Valhalla status, **not** full graph coverage. Only a successful route confirms a particular area. Europe download/build must finish first. Record the actual container image digest, Valhalla version and OSM graph timestamp; `latest` is mutable. GIS-OPS's Docker repository is archived; do not infer modern optional fields solely from that tag.

## Behavior and limits

- Car/fastest; 2–10 stops; 0–2 additional routes; BCP-47-style instruction language.
- Toll/motorway/ferry preferences are neutral or soft avoid. Unsupported options are rejected. No Apple routing or fallback engine.
- HTTP request body 16 KiB; upstream body 8 MB; each geometry at most 100,000 points. Four concurrent graph requests; Traefik rate/body limits; upstream timeout 15 seconds. Cancellation follows client disconnects. Go's public route deadline is 16 seconds.
- No request coordinates or bodies are logged by Go. Review proxy access logging separately. Responses use no-store.
- Full 2D polyline6 with global indices, route-instance IDs, normalized written/verbal maneuvers, actual instruction language, signs/names when supplied, snapped waypoint endpoints, approximate timing anchors.
- Timing is scaled maneuver interpolation, not per-edge timing or a claim of live traffic. Unknown speed limits/lane data are not fabricated. Optional future annotations require adapter capability support.
- HTTPS is terminated by Traefik; internal HTTP is intentional. The binary runs non-root with a read-only container filesystem. Health endpoints are operational, not an authentication mechanism; this is an owner-operated MVP service.

Fixture tests use a synthetic native Valhalla response and the **same normalized JSON bundled in iOS** at `ios/RoadScout/Resources/route-response.json`. These are not recorded real-road routes. Other engines require new adapters and contract tests, not Swift changes for the core route format.
