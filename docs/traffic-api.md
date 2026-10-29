# Traffic API v1

All requests go through the configured RoadScout API. NDW/DATEX XML and native graph IDs stay server-side. Wire coordinates are named WGS84 latitude/longitude; geometries are 2D polyline6. Traffic availability is independent of routing `/readyz`.

## Provider configuration

`TRAFFIC_CONFIG` points to JSON matching `deploy/traffic.config.example.json`. With no path, NDW map ingestion is enabled with the same defaults and native routing disabled. Provider factories are registered in `trafficAdapters`; another compatible source needs configuration, another profile/transport needs one Go adapter implementing `Configuration`/`Fetch`. Multiple providers may cover one country. Unknown enabled adapters fail configuration validation rather than pretending to work. Credentials are referenced by server environment name, not embedded in app/config values.

Current NDW adapter uses v3 events and travel-time site/measurement feeds, including available FCD-derived corridor observations. It does not extrapolate point-detector speeds onto road lengths or claim full Dutch road coverage. Recurring schedules without an interpreter, unsupported geometry and mismatched site versions are omitted. Full-road `roadClosed` reports require certainty/approved-or-implemented status plus matching; ambiguous carriageway/lane restrictions remain map information.

## `POST /v1/traffic`

```json
{"bbox":{"south":51.9,"west":5.0,"north":52.2,"east":5.4},"token":"optional route traffic token"}
```

Optional legacy/fallback `route:{encoding:"polyline6",data:"...",corridorMeters:150}` is accepted instead of a token. Tokens reference server-held route geometry without resending it. Results are the viewport/corridor union, bounded at 1,500 features, 2 MB encoded geometry and a 2-second geometry-query budget; `truncated` marks incomplete scope. Direct geometry inherits camera query limits (10,000 vertices/1,000 km); stored contexts support normal route-contract size.

200: `{generatedAt,sources:[{id,countries,attribution,updatedAt?,flowUpdatedAt?,stale,message?,featureCount,matchedCount}],features:[...],routingEnabled,truncated}`.

Features: `{id,sourceId,kind,title,geometry:{encoding,dimensions,pointCount,data},observedAt,expiresAt,validFrom?,validUntil?,speedKph?,travelSeconds?,normalSeconds?,congestion?,matched,directionKnown,closed,routeStartMeters?,routeEndMeters?}`.

Kinds currently `flow`, `incident`, `congestion`, `roadworks`, `closure`. Congestion is `normal|slow|heavy`, relative to the provider's normally expected travel time (>=1.2 slow, >=1.5 heavy), not posted limits or a promise of free flow. Unmatched flow is not colored. Only graph-ID/geometry/direction-compatible route portions get route offsets. Events may use approximate reported locations. Consumers must honor expiry; an old event version can remain valid in a fresh publication.

400 invalid input; 410 unknown/expired context; 415 media type. No-data/provider outage returns 200 with status/empty or still-fresh features, never invented free-flow roads.

## `/v1/routes` additions

Each route optionally includes:

```json
{"traffic":{"mode":"unavailable|live_partial","token":"opaque","coveragePercent":0,"snapshotId":"optional","expiresAt":"optional UTC timestamp","corridorKey":"optional","leadMeters":2000}}
```

`live_partial` means a native live-traffic calculation against a verified/fresh bridge; individual route coverage can still be zero. Tokens are bounded (512 contexts), memory-only, 30-minute sliding expiry during active refresh, separate from 15-minute weather tokens. Contexts expire across backend restarts; loaded navigation survives, but traffic may require recalculation to acquire a new context.

## `POST /v1/traffic/route`

```json
{"token":"opaque","position":{"latitude":52.09,"longitude":5.12},"heading":0,"speedMps":10,"at":"2026-10-28T18:00:00Z","traveledMeters":1000,"checkAlternatives":true}
```

Progress is shape arclength. Request position age must be <=10 seconds; projection must remain within 75 m / 100 m progress agreement. Limit 4 KB, two refreshes concurrently, 15-second engine deadline. Background active-navigation refresh can update ETA without offers.

200 unavailable: `{generatedAt,routingEnabled:false}`. Native ready: add `{remainingSeconds,expiresAt,alternatives?:<normal RouteResponse>}`. Selected path ETA comes from `trace_route` edge-walk, not a new shortest-path result. Alternatives preserve original preferences/objective/budget, save >=120 s AND >=5%, and have >=60 seconds lead at `max(5,current speed)` before divergence. Corridor keys use native directed edges past divergence; acceptance recalculates from fresh GPS and must preserve the offered corridor. No candidate is an ordinary outcome.

400 invalid input; 409 off-route/inconsistent progress; 410 expired token; 415 media; 429 concurrency limit. Native failure returns a degraded 200; it does not stop the loaded route.

## Native deployment gate

See `traffic-valhalla-handoff.md`. Set `enableRouting:true` and a private bridge URL only after the other agent's controlled proof. Go checks engine 3.5.1, graph manifest, engine graph timestamp, acknowledged snapshot/expiry and health age. It explicitly excludes current speeds and ignores live closures when the gate is false. Expired observations are omitted from the next native replacement, stopped traffic is encoded positive (>=2 km/h), and explicit matched full-road closures use the bridge's closure flag. Graph changes invalidate all cached match IDs. The bridge must independently expire writes, including when Go fails.

Go source refresh normally runs every 60 seconds after the previous fetch/match work. Geometric matching is limited (50 attempts/10 s per cycle by default), caches negative results 15 minutes and prioritizes closures, recently queried map areas and heavy traffic. Initial coverage warms progressively; mappings are currently memory-only. Fresh overlapping edge observations win; exact timestamp ties use higher configured priority. Provider/source failures remain visible rather than becoming zero delay.
