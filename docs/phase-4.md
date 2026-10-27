# Phase 4 · Roof Down weather (planning only)

## Owner decisions (locked before implementation)

- No WeatherKit. Weather comes through the Go API.
- Open-Meteo first (CC BY 4.0, no key, 15-minute precipitation in NL). KNMI 5-minute radar nowcast is added later when a server-side key is available; when both cover a sample, use the worse (higher) probability/intensity.
- Planning only: no driving weather badge and no weather audio. No free-drive weather.
- `/v1/routes` returns a weather token per route. The app asks for weather for a route token at a departure time.
- Every route card gets weather automatically when routes arrive. Selected route only shows rain on the map.
- Departure time is now.
- Route/weather cache: 15 minutes. Expired token → “Weather expired — recalculate”.
- Three states: **Roof Down**, **Rain Risk**, **Forecast Unavailable**.
- Rain floor: probability ≥30% and intensity ≥0.1 mm/h. Show probability, mm/h and the worst time/place.
- Sampling: target 2 km / 5 min, max 400 samples, covering the whole route (long routes get wider spacing, never truncated).
- Minimal attribution: “Weather data by Open-Meteo.com” (plus KNMI when added).

## Wire contract

### Route response additions

Each route in `/v1/routes` gains:

```json
"weatherToken": "opaque",
"weatherExpiresAt": "2026-10-24T12:15:00Z"
```

### `POST /v1/weather`

Request:

```json
{ "routeToken": "opaque", "departureAt": "2026-10-24T12:00:00Z" }
```

200 response:

```json
{
  "routeToken": "opaque",
  "generatedAt": "2026-10-24T12:00:05Z",
  "departureAt": "2026-10-24T12:00:00Z",
  "expiresAt": "2026-10-24T12:15:00Z",
  "provider": {
    "id": "open-meteo",
    "name": "Open-Meteo",
    "license": "CC BY 4.0",
    "attribution": "Weather data by Open-Meteo.com",
    "coverage": "Worldwide; 15-minute precipitation in the Netherlands/Central Europe"
  },
  "recommendation": "roof_down|rain_risk|unavailable",
  "summary": {
    "maxProbabilityPercent": 70,
    "maxIntensityMmPerHour": 0.8,
    "worstAt": "2026-10-24T14:20:00Z",
    "worstCoordinate": { "latitude": 52.1, "longitude": 5.3 },
    "sampleCount": 40,
    "rainRiskSampleCount": 5
  },
  "segments": [
    {
      "startMeters": 12000,
      "endMeters": 16000,
      "startAt": "2026-10-24T14:10:00Z",
      "endAt": "2026-10-24T14:30:00Z",
      "probabilityPercent": 70,
      "intensityMmPerHour": 0.8,
      "geometry": { "encoding": "polyline6", "data": "..." }
    }
  ],
  "warnings": [{ "code": "string", "message": "string" }]
}
```

- 400 invalid request.
- 410 `weather_token_expired` when the token is unknown/expired.
- 503 `weather_unavailable` when the provider is unavailable.
- `summary` omitted when unavailable.
- `segments` empty when no rain risk.

### Capabilities additions

```json
"weather": {
  "provider": "open-meteo",
  "coverage": "Worldwide; 15-minute precipitation in the Netherlands/Central Europe",
  "license": "CC BY 4.0",
  "attribution": "Weather data by Open-Meteo.com",
  "routeTokenTTLSeconds": 900,
  "cacheTTLSeconds": 900,
  "sampling": { "distanceMeters": 2000, "intervalSeconds": 300, "maxSamples": 400 },
  "rainRisk": { "probabilityPercent": 30, "intensityMmPerHour": 0.1 }
}
```

## Sampling and recommendation

- Store route geometry, duration and timing anchors with the token.
- Spacing = max(2 km, 5 min × average speed, route length ÷ 400), always include start/end, cap 400.
- ETA per sample from route timing anchors when available, otherwise linear distance interpolation.
- Fetch Open-Meteo in batches (≤50 coordinates per request). Use 15-minute precipitation intensity and hourly probability, aligned to sample ETA; document the resolution difference.
- A sample is rain risk when probability ≥30% and intensity ≥0.1 mm/h.
- Any rain-risk sample → `rain_risk`; otherwise `roof_down`; missing/stale data → `unavailable`.
- Summary uses the worst sample (max intensity, then max probability).
- Merge contiguous rain-risk samples into segments with route start/end meters, times, probability, intensity and sliced polyline6 geometry.

## Go behavior

- In-memory route-token store (15 min, bounded) and weather cache (15 min, bounded). No user/trip logging.
- Provider abstraction: Open-Meteo now; KNMI adapter later; worst-of-both merge when both exist.
- Weather failures never affect routing readiness or route calculation.
- Config: `OPEN_METEO_BASE_URL`, `WEATHER_CACHE_TTL` (default 15m); KNMI key later.
- OpenAPI and backend README updated.

## iOS behavior

- Decode `weatherToken`/`weatherExpiresAt` on routes.
- `WeatherClient` calls the single `/v1/weather` endpoint; maps 410 to expired and 503 to unavailable.
- `WeatherModel` requests weather automatically for every route card when routes arrive (departure now), caches in memory, and exposes loading/loaded/expired/unavailable states.
- Route cards show: `Rain Risk · 70% · 0.8 mm/h around 14:20`, `Roof Down · dry along route`, `Weather unavailable`, or `Weather expired — recalculate`.
- Selected route map shows rain segments (blue dashed) and a rain icon at the worst point; alternatives show card summaries only.
- Settings show minimal attribution and a Roof Down weather toggle.
- No driving weather UI or audio.

## Acceptance checks

- Deterministic fixtures: storm before vs after the passing time, dry route, missing/stale provider, timezone handling, cache expiry, batching, worst-of-both merge.
- Dry route → Roof Down; any sample above floor → Rain Risk with worst detail; no data → Unavailable.
- Route cards show probability, mm/h and worst time/place; selected route map shows rain segments/icons.
- Token/weather cache expires after 15 minutes; expired token shows the recalculate message.
- No route geometry resent for weather refreshes; Go batches coordinates.
- Routing remains ready and unaffected by weather failures.
- Go race tests/vet, iOS Debug/Release builds, simulator inspection. No physical-device/road claims.

## Implementation order

1. Go route tokens, Open-Meteo provider, sampling, merge/cache, `/v1/weather`, tests.
2. iOS weather models/client/model, route token decoding, tests.
3. Route-card weather line, selected-route map overlay, settings.
4. Live Open-Meteo check, simulator inspection, docs updates.

## Verification · 2026-10-25

- Implemented Go and iOS core, per-alternative planning summaries, selected-route dashed rain geometry/cloud, toggle and attribution. Roof Down wording is “low forecast rain risk”, not a promise of dryness. Cards show retrieval time and the 15-minute/hourly resolution difference.
- Any missing sample produces `unavailable`, superseding the initial majority-missing implementation. Open-Meteo timestamps end the preceding accumulation/probability interval; deterministic boundary tests verify this alignment.
- Go race tests/vet passed; full Debug simulator build/tests passed (123 methods, 119 passed, 4 opt-in skips; 149 passed parameterized executions). Release simulator build passed.
- Restarted hosted LAN Go with camera snapshot/experimental settings preserved. Live routing returned three alternatives; all weather requests returned Rain Risk, 100% and max 4 mm/h with 5/6/7 samples. Readiness remained 200.
- Inspected live-routing/weather planning screenshot using a synthetic Utrecht origin: card risk/intensity/time and selected-route rain overlay present. No device/road tests claimed. KNMI and manual real-world acceptance remain pending.
- A later live launch also verified the Roof Down card with retrieval time/resolution and no rain overlay when the forecast changed to low risk.
