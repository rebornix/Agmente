# Contributing to Agmente

Thanks for your interest in contributing. This document covers the basics for building, testing, and submitting changes.

## Prerequisites
- Xcode (latest stable recommended)
- macOS (for iOS builds)

## Repository layout
- `Agmente/` – iOS app source
- `ACPClient/` – Swift package used by the app
- `AppServerClient/` – Codex app-server client support

## Swift package dependency
`ACPClient/Package.swift` references `../../acp-swift-sdk` as a local package dependency.

Options:
- Clone `acp-swift-sdk` alongside this repo (same parent directory), or
- Update the dependency path to your local checkout.

## Build (iOS)
1. Open `Agmente.xcodeproj` in Xcode.
2. Select a simulator or device.
3. Build and run.

CLI build example:
```bash
xcodebuild -project Agmente.xcodeproj -scheme Agmente -destination 'platform=iOS Simulator,name=iPhone 15'
```

## Tests
App tests:
```bash
xcodebuild -project Agmente.xcodeproj \
  -scheme Agmente \
  -destination "platform=iOS Simulator,id=<SIMULATOR_UDID>" \
  test
```

ACPClient package tests:
```bash
swift test --package-path ACPClient
```

If you add UI or integration tests, mention any new steps in your PR description.

## Pull requests
- Keep changes focused and scoped.
- Include a clear description of the behavior change.
- Add or update tests when appropriate.
- Update docs when you change user-facing behavior.

## Reporting issues
Use GitHub issues for bugs and feature requests. Please include:
- OS and device info
- Steps to reproduce
- Expected vs actual behavior
- Screenshots or logs when applicable
