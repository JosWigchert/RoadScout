# NAS deployment automation

## Acceptance plan

Traffic mount fix acceptance: default staging/production Compose configuration must contain no bind mount sourced from the runner checkout and must use Go's built-in NDW defaults with traffic routing disabled. An explicitly configured absolute `TRAFFIC_CONFIG_HOST_FILE` must add a read-only host bind and set the in-container `TRAFFIC_CONFIG`. Both configurations must render correctly and deployment must fail before replacing the service if the override is invalid or unavailable on the Docker host. No NAS deployment is claimed without actually running one.

- Manual GitHub Actions dispatch selects staging or production, serializes each target and uses its GitHub environment.
- Build only the Go API on the Unraid runner; use existing Valhalla and Traefik networks without changing their containers.
- Keep target configuration and writable camera snapshots outside the checkout, with separate storage and Traefik names for each target.
- Validate configuration before replacing the API; wait for Docker health and Valhalla readiness, failing with diagnostics if either fails.
- Verify shell syntax, Compose rendering, workflow structure and simulated deployment success/failure. Actual NAS/public HTTPS acceptance is recorded separately.

## Setup

1. Register a repository-accessible GitHub Actions runner on the NAS with labels **self-hosted**, **unraid**. It needs Git, Python 3, Docker daemon access and Docker Compose v2 supporting `up --wait` and `--wait-timeout`. If your runner has additional labels such as `integral-motions`, it still matches; add a `roadscout` label to the workflow if you want to restrict this to a dedicated runner.
2. Create GitHub environments **staging** and **production**. Optionally set their variable `NAS_ENV_FILE` to an absolute NAS configuration path. Defaults are `/mnt/user/appdata/roadscout/staging.env` and `/mnt/user/appdata/roadscout/production.env`.
3. Copy `deploy/nas.env.example` to each of those NAS paths and edit it. Set different `ROUTING_HOST` and `CAMERA_DATA_HOST_DIR` values for each target. Both Docker networks must already exist; `Valhalla` must resolve on `VALHALLA_NETWORK`. The example uses your other site's `home` proxy network.
4. Provision each camera directory writable by UID/GID **10001**. For example, on the NAS:

   ```sh
   mkdir -p /mnt/user/appdata/roadscout/production/cameras
   chown 10001:10001 /mnt/user/appdata/roadscout/production/cameras
   ```

   Repeat for staging. Copy an existing `snapshot.json` if desired; otherwise the normal asynchronous import populates it. Do not point staging and production at the same directory.
5. Point each hostname at your existing Traefik HTTPS ingress and ensure its `websecure` entrypoint and `letsencrypt` resolver match the configuration.
   Traffic uses the API's built-in defaults: NDW ingestion enabled and **traffic-aware routing disabled**. No runner-checkout traffic file is mounted. To override these defaults, copy `deploy/traffic.config.example.json` to a persistent path on the **Docker host**, then set `TRAFFIC_CONFIG_HOST_FILE` to that absolute host path in `staging.env`. The deployment script automatically adds `compose.traffic-override.yaml`, mounting the file read-only at `/etc/roadscout/traffic.json`. It runs a temporary container with the Docker daemon to verify that the file exists and is readable by UID 10001 **before replacing the API**; a containerized runner need not see the host path itself. Remove `TRAFFIC_CONFIG_HOST_FILE` to return to the built-in defaults. Keep staging and production overrides separate. Set staging's `VALHALLA_BASE_URL` to the staging Valhalla service and keep its camera data directory and hostname distinct. Do not set `enableRouting` until the bridge/graph tests in `traffic-valhalla-handoff.md` are complete.
6. Push these files, open **Actions → Deploy on NAS → Run workflow**, choose the branch and target. The summary records the URL and commit only after successful health/readiness checks.

No GitHub secrets are required. NAS environment files are not committed. Additional backend settings (for example `OPEN_METEO_BASE_URL` and `WEATHER_CACHE_TTL`) can be added there; they are passed to the API container. Keep deployment-owned `LISTEN_ADDR`, `CAMERA_DATA_DIR`, `ROUTING_PROVIDER`, `DEPLOY_TARGET`, `RELEASE_ID` and `NAS_ENV_FILE` out of the file. Use `TRAFFIC_CONFIG_HOST_FILE` rather than setting the container's `TRAFFIC_CONFIG` directly.

## Operation

The workflow builds `backend/Dockerfile` locally and runs `deploy/compose.nas.yaml` with project name `roadscout-staging` or `roadscout-production`. No host port is published: Traefik reaches port 8080 on its Docker network. Router/service/middleware names are unique per target. Rate and request-body limits cover the existing route, camera and weather contracts (256000 bytes maximum).

Manual equivalent from the repository root:

```sh
sh scripts/deploy-nas.sh production
# Custom configuration path:
NAS_ENV_FILE=/mnt/user/appdata/roadscout/production.env sh scripts/deploy-nas.sh production
```

Deployments recreate one API instance per target and have a short interruption. There is no automatic rollback; on failure inspect the job's Compose status/logs, fix configuration or redeploy the last working commit. Persistent camera storage is retained. In-memory weather tokens/cache reset when the process restarts, so existing route weather may require recalculation. Images are tagged by commit and target and are not automatically pruned.

If migrating from the old `roadscout-api` Compose project, stop its `routing-api` service before the first production deployment to avoid duplicate public routers and concurrent snapshot writers. Do not stop Valhalla or Traefik.

After deployment, verify public `/healthz`, `/readyz`, `/v1/capabilities` and a real `POST /v1/routes` using `deploy/route-request.json`. Readiness checks Valhalla availability, not graph coverage or camera import completion. Use the production HTTPS endpoint in the app's server setting when testing with the current Debug build, whose default still points at the Mac.

### Traffic staging smoke check

After pushing a reviewed commit, manually dispatch **Deploy on NAS** with target **staging**. The workflow deploys the selected committed ref, not uncommitted local files. In the iPhone app set **Settings → RoadScout API** to the staging HTTPS base URL and enable **Live traffic**. Query a Dutch viewport and verify source freshness/attribution and incident markers. Matching is deliberately bounded and warms over successive refreshes, so congestion coverage may initially be sparse.

Inspect `/v1/capabilities`: `traffic.enabled` and `mapEnabled` should be true; `routingEnabled` should be false until the separate bridge is installed and verified. Traffic offers/ETA will not appear while routing is false. The existing staging API, Valhalla and camera data stay isolated from production only if the staging NAS environment and host directories point at their staging resources. No actual NAS deployment or HTTPS staging check was performed from this workstation.

If a deployment fails with `bind source path does not exist: /runner/_work/.../deploy/traffic.config.example.json`, it is running the older Compose configuration: the runner checkout path is not necessarily visible on the host Docker daemon. Deploy a commit containing the traffic mount fix. A saved `TRAFFIC_CONFIG_HOST_FILE` must be a valid absolute path on the Docker host; remove it if using the built-in defaults.
