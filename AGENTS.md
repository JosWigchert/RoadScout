# RoadScout

Read `RoadScout_Requirements_OpenCode.md` before changing product behavior. Its section 2 is binding. Implement phases in order, document acceptance checks before each phase, and update README, milestones and testing notes after verification.

- Swift / SwiftUI, iPhone first, minimum iOS 18.
- MapKit is for display and place search only. All future routing uses self-hosted Valhalla. Never introduce MKDirections.
- Keep location, navigation, cameras and weather independently testable. Inject dependencies; keep computation out of views.
- No paid SDKs, analytics or accounts. Owner approved a small Go routing API in Phase 2; see docs/phase-2.md.
- Never claim physical-device, road, or CarPlay tests unless actually performed.
- Build/test command is in README.md. Do not commit signing credentials, generated build outputs or user-specific Xcode settings.
