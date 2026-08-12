# Changelog

## 0.2.1 — 2026-08-11

- Kept Needs attention rows visible until their configured GitHub label is removed or the pull request closes.
- Changed row clicks and the bulk action to mark notifications seen without locally dismissing label-authoritative state.
- Restored rows dismissed by 0.2.0 as seen rows during the upgrade.

## 0.2.0 — 2026-08-11

- Replaced direct-mention inbox authority with configurable GitHub labels on open PRs in one organization.
- Added one-row-per-PR aggregation, per-label seen/dismissed state, source label colors, and priority-colored menu-bar dots.
- Added authoritative removal and remove/reapply detection using direct PR labels and GitHub labeled-event IDs.
- Reused the existing 15-second refresh lane; approved and merged five-second signals remain unchanged.
- Added action-label freshness diagnostics and fail-closed preservation of the last verified action state.
- Removed the GitHub `notifications` scope from new OAuth authorizations while retaining dormant mention/loud code for possible future use.
- Fresh public installs remain unconfigured and contain no personal organization or label defaults.

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
