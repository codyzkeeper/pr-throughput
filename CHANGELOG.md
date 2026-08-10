# Changelog

## 0.1.1 — 2026-08-10

- Fixed a configured release opening with GitHub sign-in disabled when an earlier build had saved a blank OAuth client-ID preference.
- Added regression coverage for bundled configuration, blank saved values, and explicit user overrides.
- Clarified in-app OAuth guidance when a release already includes a public client ID.

## 0.1.0 — 2026-08-10

Initial public release.

- Universal macOS menu-bar app for Apple silicon and Intel Macs.
- Rolling 48-hour, 7-day, and 30-day pull-request activity views.
- Merge completion, median open age, and review acceptance KPIs.
- Reconciled handoff and review-cycle metrics derived from GitHub timelines.
- Tag-only Needs attention inbox for verified direct mentions.
- Read-only GitHub Device Flow authentication with the token stored in Keychain.
- No bundled user data, metrics cache, preferences, notifications, or credentials.

This release is ad-hoc signed and not notarized. On first launch, macOS may require Control-clicking the app and choosing **Open**.
