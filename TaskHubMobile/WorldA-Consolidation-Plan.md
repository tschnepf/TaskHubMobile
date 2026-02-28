# World A Consolidation Plan

This document describes the steps to consolidate the TaskHubMobile project around the “World A” architecture. It is intended to be executed step-by-step and fed back into the AI agent as discrete tasks. Each step has goals, concrete file-level changes, acceptance criteria, and notes.

## Goals
- Replace temporary World B shims with the full World A architecture.
- Establish a single source of truth for environment/services injection via `DefaultAppEnvironment`.
- Adopt the actor-based networking (`APIClient`) and `SyncEngine` for data and widgets.
- Enable OAuth sign-in, App Group persistence, and Keychain usage.
- Remove duplicate/legacy code paths (Bootstrap, SyncController, AppConfig shims).

## Current State (as of this plan)
- Active shims: `WorldBShims.swift` defines:
  - `@MainActor final class AppConfig { @Published var baseURL: URL? }`
  - `@MainActor final class SyncController { @Published var isSyncing: Bool; no-op methods }`
  - Empty `DefaultAppEnvironment` placeholder
- Full/real implementations exist in `ios-xcode-app-implementation-plan.full.md` (not compiled).
- Legacy real implementations exist but are disabled via `#if false`:
  - `AppConfig.swift` (persisted base URL)
  - `SyncController.swift` (legacy engine)
- UI files reference a mix of A/B worlds. Examples:
  - `SyncSettingsView` references `SyncController` fields that only exist in World A or the old disabled implementation.
  - `BootstrapView` references `AppConfig` (shim), while World A uses `APIClient` + `AppGroupCache` and `ServerBootstrapView`.
- Immediate errors in `SyncSettingsView`:
  - `KeychainService` missing (only defined in World A plan doc)
  - `SyncController` members missing in shim
  - Binding misuse (`$syncController`)

## Target Architecture (World A)
- `DefaultAppEnvironment`: central object holding services
- Services:
  - `APIClient` (actor)
  - `AuthStore` (@MainActor ObservableObject)
  - `SyncEngine` (actor)
  - `DeviceRegistry` (actor)
  - `WidgetCache`
  - `PreferencesStore` (@MainActor ObservableObject)
  - `ProjectCache`
  - `AppGroupCache`
  - `KeychainService`
- App entry: `TaskHubMobileApp` sets up `DefaultAppEnvironment` and injects environment objects
- Views: `RootView` decides between `ServerBootstrapView`, `LoginView`, and the main content

## Migration Strategy
- Introduce World A building blocks as compiled Swift files.
- Keep UI compiling during the transition by either:
  - Temporarily gating World A-only views with `#if` or simple placeholders, or
  - Extending shims to satisfy compilation until the real services are ready.
- Remove shims only after the World A components compile and are injected.

---

## Step-by-Step Plan

### Step 0: Centralize identifiers and update entitlements
- Create `AppIdentifiers.swift` with constants:

```swift
import Foundation

struct AppIdentifiers {
    static let appGroupID = "group.com.yourorg.taskhub"
    static let keychainAccessGroup = "com.yourorg.taskhub.sharedkeychain"
}
