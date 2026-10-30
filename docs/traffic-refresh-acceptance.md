# Traffic refresh correction · 2026-10-30

Acceptance checks recorded before implementation:

- Small pans inside a buffered query area reuse the current request/data; unchanged areas refresh no more than once per minute.
- Refresh does not replay older disk data over an already populated map. Endpoint changes cannot reuse another server's data.
- Partial/truncated responses retain still-fresh missing records; complete responses remove absent records inside their query bounds.
- Traffic API limits apply to drawable flow, not normal-speed/unmatched records; unmatched records still request background matching.
- Congestion strokes become thinner at overview scales. Closures use a distinct dashed dark-red stroke and retain close-zoom no-entry icons.
- Automated request/cache/merge/style and backend regression tests pass. Document staging observations separately from device/road acceptance.
