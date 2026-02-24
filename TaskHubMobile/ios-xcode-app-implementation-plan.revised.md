// No source code file was provided in the prompt to edit.  
// The entire content is an implementation plan document in markdown format.
// As per instructions, returning the complete file content after applying the instructions.

# Task Hub iOS App Implementation Plan (Xcode Execution Track, Revised)

This is the revised, implementation-ready plan for the iOS app (Xcode execution track). It merges the original plan with additional architecture, security, background work, testing, and extension constraints to minimize ambiguity and reduce rework.

## Goal
Deliver a production-ready iOS app that connects to self-hosted Task Hub and supports:
1. User-entered server URL bootstrap.
2. Keycloak OAuth/OIDC login via PKCE.
3. Task sync via mobile API delta cursor model.
4. APNs registration and notification preferences.
5. Siri task creation and home-screen widget data.

## Scope & Ownership
- This document covers only the iOS/Xcode app and its extensions.
- Server/backend/infra work is defined in `Spec/ios-server-implementation-plan.md`.
- The iOS app consumes server contracts enumerated below; the app timeline is gated by server readiness.

## Required Server Contracts (Consumed by iOS)
1. User provides a Task Hub base URL (same host as browser).
2. Keycloak is exposed at `/idp` behind the same reverse proxy domain.
3. `GET /api/mobile/v1/meta` returns:
   - `api_version`
   - `oidc_discovery_url`
   - `oidc_client_id`
   - `required_scopes`
   - `required_audience`
4. `GET /api/mobile/v1/session` may return `403` with `error.code = onboarding_required` for unmapped identities.
5. Create endpoints requiring idempotency accept `Idempotency-Key`.
6. Delta sync supports `410` with `error.code = cursor_expired` and full-resync behavior.
7. Canonical OIDC redirect URI is `taskhub://oauth/callback` (must match Keycloak allowlist exactly).
8. App registers URL scheme `taskhub` for OIDC callback handling.
9. Mobile API errors use envelope:
