# Live traffic · NDW first, extensible European providers

## Owner-approved scope / acceptance before implementation · 2026-10-28

Full navigation plus map overlays. NDW Netherlands first, provider/region configuration extensible to other NAP datasets. NAPCORE is a discovery directory, not a common live API. Prefer available NDW DATEX II v3; legacy AVG v2.3 feeds retire 2027-02-09. Public NDW defaults to CC0 unless a dataset specifies otherwise.

Acceptance:
- Normalized, source-qualified incidents and flow with publication/observation/validity times; road/direction matching before route costs. Unknown coverage is not free flow, point speeds do not color whole roads, zero observed speed is not closure.
- Configurable providers, endpoints, countries, source priority, freshness and server-only credential references. iPhone uses a stable Go contract without country-specific parsing.
- Bounded gzip/XML fetch/parse, complete-snapshot reconciliation, versioned measurement-site joins, conditional requests, last-good retention and expiry. Unchanged long-lived events remain valid when present in a fresh publication.
- Traffic failure cannot fail base routing readiness or loaded guidance. Enable live costs only after native bridge deployment/graph identity/freshness is verified. No post-hoc delay calculation is advertised as engine-aware routing.
- The native Valhalla bridge must pass controlled ETA/path/opposite-direction/stale/graph-rebuild tests before being enabled. Current NAS Valhalla reports 3.5.1; SSH access is unavailable. Owner will ask another agent to prepare the bridge; see `traffic-valhalla-handoff.md`.
- Current traffic is visible on the map and route cards. Completed route remains gray. Selected-route ETA refresh preserves tracker progress; provider outage/partial coverage is explicit.
- Faster-route check normally every 5 min, ETA/traffic every minute, earlier for material delay/relevant closure/major decisions with cooldown. Propose only >=120 s AND >=5% saving and adequate divergence lead time. Yes/No with visible 15 s Yes countdown; timeout accepts, No suppresses same corridor 10 min. Revalidate from fresh GPS before switching; cancel when hidden/backgrounded, stale, route changes or divergence passes.
- Test parser variants, schedules/expiry, matching ambiguity/direction, provider isolation, native bridge gating, route timing, request limits, offer countdown/cancellation/rejection and stale request generations. Verify Go race/vet, Swift tests/builds and live bounded NDW samples; physical-device/road acceptance remains separate.

## Deployment boundary

Go owns ingestion, matching and normalized traffic API. Native live-speed writes are delegated to a private, version-matched bridge running beside the existing Valhalla graph. No graph import or public Valhalla exposure is required. Until the bridge is deployed and verified, map/incident data may be served but routing/traffic ETA capability must report unavailable rather than silently promise live costs.

## Staging implementation status · 2026-10-29

NDW v3 ingestion, bounded directional matching, Go traffic endpoints and Swift map/UI are implemented for staging. The included `deploy/traffic.config.example.json` enables NDW overlays and explicitly disables native traffic routing. Other countries have a provider interface but no adapters. The staging Valhalla/updater integration is a separate pending gate: no live route/ETA or automatic offer claim is made until the separate agent's controlled proof succeeds.

Verified locally: Go race suite/vet; full Debug simulator suite (183 passed methods, 4 opt-in skips; 215 passed parameterized executions); Release arm64 simulator build after final changes; NAS Compose config rendering. An isolated local API pointed at the reachable LAN Valhalla returned three routes with traffic context tokens and weather tokens, all with routing mode `unavailable`. A separate live NDW viewport query returned 151 incident/closure records; matching warms progressively. Synthetic map/offer preview was visually inspected. No actual staging deployment, public HTTPS, iPhone or road test performed.
