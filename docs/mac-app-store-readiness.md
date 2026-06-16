# Portal Mac App Store Readiness Audit

Date: 2026-05-30

## Current verdict

The current `PortalMac` app is not ready for Mac App Store submission.

It has multiple hard blockers:

1. It depends on Accessibility event capture and event injection to control the Mac.
2. It toggles the `awdl0` interface using `sudo`, `osascript`, and a sudoers install flow.
3. It is packaged today as a SwiftPM executable wrapped by a shell script, not as an App Store archive target with sandbox entitlements and release metadata.
4. It uses local network access but doesn't yet have an App Store-ready bundle configuration and review-facing permission messaging.

## Hard blockers

### 1. Accessibility control model

The app uses:

- `AXIsProcessTrusted`
- `CGEvent.tapCreate`
- `CGWarpMouseCursorPosition`
- Quartz event posting and input forwarding

This is core product behavior, not an optional helper path. For a Mac App Store build, this area is high risk and should be treated as a likely rejection vector unless the product is redesigned into a compliant form factor.

### 2. System administration flow

The app currently runs or installs:

- `/usr/bin/sudo`
- `/usr/bin/osascript`
- `/sbin/ifconfig awdl0 up|down`
- `/etc/sudoers.d/portal-awdl`

This flow is not appropriate for a sandboxed App Store app. It requires privileged system changes and external command execution patterns that should be removed from the App Store variant.

### 3. Packaging model

The current Mac app is built by:

- `swift build`
- wrapping the executable into `dist/Portal.app`
- injecting an `Info.plist` from `script/build_and_run.sh`

This is fine for local iteration, but not for App Store distribution. A dedicated release target is needed with:

- bundle metadata
- entitlements
- proper signing setup
- archive/export flow

### 4. Product split is required

The current app combines:

- local network discovery
- remote installer sharing
- low-level input capture
- low-level input injection
- system network tuning

For App Store submission, the app should be split conceptually into:

- `Portal Store`: onboarding, pairing, discovery, status, product shell
- `Portal Direct`: advanced low-level control features that likely cannot ship in the store variant unchanged

## Medium-priority gaps

### Privacy strings and bundle review data

The App Store variant should define and review:

- `NSLocalNetworkUsageDescription`
- final bundle identifier
- app category
- version/build strategy
- export compliance answers
- review notes that explain LAN pairing behavior

### Sandboxed architecture review

A store build needs a dedicated entitlement review:

- App Sandbox enabled
- outbound/inbound networking only if truly required
- no privileged filesystem or system-administration assumptions
- no temporary exception entitlements unless there is a strong documented case

### Accessibility polish

Separate from the macOS Accessibility permission used for control, the UI itself still needs a standard product accessibility pass:

- VoiceOver labels
- keyboard navigation
- contrast and focus states
- review of custom controls

## Recommended delivery plan

### Phase 1: Create the App Store variant boundary

Goal: separate what can ship from what cannot.

Required work:

1. Define a `Portal Store` feature set.
2. Remove AWDL control from that variant.
3. Remove sudoers installation from that variant.
4. Remove direct Mac control or move it behind a non-store distribution strategy.

### Phase 2: Create a real release target

Goal: move from SwiftPM wrapper app to store-ready bundle structure.

Required work:

1. Create an Xcode macOS app target or equivalent archive-capable release project.
2. Add a checked-in entitlements file.
3. Add final App Store metadata and privacy strings.
4. Add release signing configuration.

### Phase 3: Review submission surface

Goal: make review understandable.

Required work:

1. First-run onboarding for local network and required permissions.
2. Clear explanation of what runs on Mac and what runs on Windows.
3. No developer-facing terminology in the user flow.
4. App Review notes describing LAN discovery, installer sharing, and any permissions requested.

## Immediate next step

The next engineering move should be:

1. Decide the exact Mac App Store scope for the Mac app.
2. Implement a dedicated App Store build mode that removes:
   - AWDL toggling
   - sudo/osascript flows
   - any feature that depends on unsupported low-level system control

Without that scope split, polishing UI or signing alone will not make this app App Store-ready.
