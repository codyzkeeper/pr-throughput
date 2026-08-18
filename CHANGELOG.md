# Changelog

## 0.3.2 — 2026-08-17

- Added a fourth configurable action-label rule for merge-ready pull requests.
- Kept label colors authoritative per pull request so repository-level GitHub color changes appear without redelivering seen notifications.
- Added larger explicit open buttons to action rows and an Open all action for launching every listed PR in the default browser.
- Migrated existing three-rule configurations without adding organization- or user-specific defaults to public builds.
- Fixed quoted-label search syntax so newly labeled PRs are discovered beyond the bounded fast-refresh fallback set.
- Retry startup after temporary locked/dark-wake Keychain failures instead of remaining disconnected until relaunch.

## 0.3.1 — 2026-08-13

- Clarified that the closing backlog is authored open work, distinct from the assigned-to-you menu-bar total.
- Added handoff cycles to the activity chart using the same selected-window and non-withdrawn definition as the Handoffs metric.

## 0.3.0 — 2026-08-12

- Replaced opening-cohort metrics with one exact rolling-window backlog ledger.
- Added open-at-start, new, re-entered, merged, closed, drafted, open-now, and net-change values.
- Made review acceptance use only approval and changes-requested events in the selected window, with its numerator and denominator visible.
- Added reopen events and complete paginated discovery of old authored PRs that remain open.
- Anchored every dashboard metric to one verified full-sync timestamp and advanced the canonical metric contract to v4.
- Invalidated pre-v0.3 timeline caches so the new ledger cannot be marked reconciled without authoritative reopen history.
- Preserved GitHub timeline order when lifecycle events share a timestamp, including fast suffix refreshes.
- Replaced provisional first-sync zeroes with an explicit verification state in both the popover and menu bar.
- Hardened canonical decoding against duplicate facts, unbalanced ledgers, and invalid median availability.

## 0.2.2 — 2026-08-11

- Prevented a slower general refresh from overwriting newer GitHub action-label state or seen state from the 15-second notification refresh lane.
- Added reconciliation gates immediately before every refreshed snapshot is saved and displayed.
- Made opening a macOS notification mark that PR's notification seen while keeping its label-authoritative feed row visible.
- Clarified VoiceOver guidance for action-label rows.

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
