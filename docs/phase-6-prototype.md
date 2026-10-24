# Early Scenic / More Corners prototype

Owner explicitly prioritized this experiment on 2026-10-24. Earlier-phase/device acceptance remains open; Phase 6 is not complete.

## Implementation plan (before implementation)

1. Preserve supplied maneuver street names/distances and replace numbered alternatives with factual corridor names (e.g. Via N237, Via A27 · A1), with correctly numbered fallbacks.
2. Keep the existing Valhalla instance and `auto` car costing. Opt-in Go `ENABLE_EXPERIMENTAL_ROUTING=1` enables prototype `scenic` / `more_corners` objectives. Normal Fastest requests retain their current behavior/load.
3. Generate at most six candidates: ordinary Fastest/alternates, plus motorway-deemphasized car routes/alternates. Do not impersonate motorcycle/pedestrian access or disable restrictions. Deduplicate geometry and enforce a 15/30/50% UI travel-time budget relative to the available fastest baseline.
4. Request Valhalla `trace_attributes` edge metadata for bounded candidates. The deployed 3.5.1 endpoint was probed successfully with shape, road class, surface, use, density and shape-index attributes; trace shape matched the original encoded geometry. No graph import/config/image mutation is needed.
5. Scenic prototype ranks eligible paved, low-road-density road share. This is a countryside proxy, **not verified beauty/scenery**. More Corners scores distance-resampled, physically plausible bends on eligible roads, excluding junction maneuvers/roundabouts, high-density streets, service/unpaved edges and U-turn-like geometry. Do not reward more instructions or geometric vertex counts.
6. Return machine-readable experiment metrics/method/status and clear fallback notes when metadata, detour budget or improvement is unavailable. Do not relabel an unchanged Fastest fallback as Scenic/More Corners. Expose prototype profiles/budget in Debug planning and preserve the requested objective in actual routing/rerouting.

## Acceptance checks

- Existing fastest adapter/contract tests remain valid; disabled experimental objectives are rejected and not advertised.
- Tests verify ordinary/experimental request validation, geometry deduplication, detour cap, meaningful-score improvement, missing metadata, no fake prototype fallback labels and no restriction-bypass costing.
- Synthetic paved rural curves score above straight geometry; junction grids, roundabouts, residential/service/unpaved roads and U-turn-like shapes do not gain spurious bend rewards. Resampling is independent of input vertex density.
- Swift tests verify optional metadata decoding, factual/unique route naming, fallback numbering, profile/budget propagation and prototype fallback UI state. Build Debug/Release.
- Live smoke tests compare Fastest/Scenic/More Corners through local Go → the same Valhalla service, recording returned metrics, baseline/detour and fallback status. Fixture tests and live requests do not establish road safety, scenery quality or device acceptance.

## Server-driven catalog (2026-10-24)

`/v1/capabilities` now advertises `routingOptions` (`id`, `title`, `experimental`, per-style `detourOptions`) plus aggregate `detourOptions`. The app builds its style picker and budget menu from this response instead of compiled enums/lists. Adding or renaming a style, changing budgets, or changing experimental status is a Go-only change. Settings → Route styles gates experimental styles; when off, only non-experimental options are shown. If capabilities cannot be loaded, the app uses Fastest only.

The client treats the catalog and `route.experiment` leniently: unknown objectives are usable, missing/extra fields are ignored, and experimental metadata can never fail an otherwise valid route.

## Limits

This only reranks a small candidate pool. It does not optimize every graph edge for curvature/scenery, guarantee scenic beauty, provide live traffic or generate loops. Genuine Phase 6 work still needs road-data/scoring calibration, representative objective comparisons, a richer candidate/custom-costing strategy and physical-route evaluation. No changes to NAS graph files or paid SDKs are introduced.

## Implemented scoring (prototype v1)

- Eligible segments: paved/paved-smooth/paved-rough, `use=road`, primary/secondary/tertiary/unclassified and graph road density 0–8. Motorway/trunk/residential/service/parking/footway segments do not receive countryside/bend credit. Candidates with over 100 m of unpaved geometry cannot be promoted.
- Curves are evaluated after uniform 20 m resampling, using 40 m look-behind/ahead headings. Qualifying angle changes are 12–105 degrees, grouped into continuous bends with at least 80 m separation. Turn/merge/fork/ramp maneuvers have 60 m exclusion buffers; roundabouts exclude their supplied span plus buffers. Tight direction reversals are excluded geometrically. These are estimated **qualifying** bends, not every bend a driver might perceive.
- Scenic needs over two percentage points more eligible-country-road share than the fastest available baseline. Corners needs a greater bend count and over 0.05 more qualifying bends/km. Both require at least 500 m of eligible geometry and compliance with the travel-time cap. Ties prefer less travel time.
- Baseline means the least estimated travel time among the ordinary Fastest candidates, which can differ from Valhalla's first cost-recommended route. Requests are still `auto` car routing. Normal Fastest requests bypass all experimental metadata/scoring work.
- The chosen preview/alternative is retained at driving entry if fresh GPS matches its start within 50 m. Otherwise recalculation uses physical GPS while retaining the selected effective objective and budget; custom planning origins always recalculate.

## Verification · 2026-10-24

- `go test -race -timeout 30s ./...` and `go vet ./...` passed. Tests cover straight/curved/resampled geometry, junction/roundabout/U-turn and unsuitable-road exclusions, different Scenic/Corners rankings, detour limits, geometry deduplication, missing metadata, opt-in capabilities, and trace shape/costing validation.
- Debug build/full tests including both live LAN opt-ins: **69 methods / 92 executed cases passed**, no failures/skips. Release build/full tests with testability enabled: **67 methods / 90 executed cases passed**, no failures/skips. Prototype profiles remain hidden in Release UI. New Swift checks cover wire metadata/budget, road-corridor labels and correct fallback numbering, request propagation and selected-alternative handoff.
- Real Fastest/Scenic/More Corners responses matched the updated OpenAPI schemas. The local Go server is running with `ENABLE_EXPERIMENTAL_ROUTING=1`, backed by the same NAS Valhalla 3.5.1 instance.
- A Debug `--live-corners-preview` screenshot was inspected: actual LAN route geometry, prototype/profile and detour controls, supplied Via N237 corridor label, estimated bend/countryside/time metrics and Drive. Its starting fix is synthetic, not physical-device GPS.

### Live comparisons, 30% budget unless noted

| Journey | Fastest available baseline | Prototype result | Observation |
| --- | --- | --- | --- |
| Utrecht → Amersfoort | 23.9 min, 0 qualifying bends | 30.1 min, 7 bends, 67.3% eligible country roads | Both objectives selected the same candidate; +25.7% estimated time |
| Utrecht → Amersfoort, 15% cap | 23.9 min | 25.6 min, 2 bends, 64.3% eligible roads | Tighter budget picked a different candidate; +7.1% time |
| Sittard → Vaals | 31.2 min, 1 bend, 25.9% eligible roads | 39.7 min, 17 bends, 78.8% eligible roads | Both objectives selected the same candidate; +27.5% time. Ordinary first cost-recommended route was 32.6 min |
| Maastricht → Vaals | 28.6 min, 1 qualifying bend, 81.0% eligible roads | Fastest retained | No better verified candidate in the pool within budget |
| Valkenburg → Epen | 18.4 min, 34 qualifying bends, 99.6% eligible roads | Fastest retained | Baseline already scored highly; no fabricated improvement |

No physical driving, independent scenery assessment, full graph-optimal winding-route comparison or global road-quality claim is made. These examples establish candidate behavior, not Phase 6 completion.

Sources: [Valhalla route/costing API](https://valhalla.github.io/valhalla/api/route/api-reference/), [map matching/trace attributes](https://valhalla.github.io/valhalla/api/map-matching/api-reference/), and direct `route`/`trace_attributes` probes against the owner's reported 3.5.1 service.
