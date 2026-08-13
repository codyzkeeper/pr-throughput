# PR Throughput

PR Throughput is a lightweight macOS menu-bar app for tracking your pull-request shipping velocity and review cost across GitHub.com.

It is a universal app for Apple silicon and Intel Macs running macOS 14 or later.

## Install

1. Download the latest `PR-Throughput.dmg` from [GitHub Releases](https://github.com/codyzkeeper/pr-throughput/releases/latest).
2. Open the disk image and drag **PR Throughput** to **Applications**.
3. Launch the app, enter the public client ID of a GitHub OAuth App if the build is not preconfigured, and sign in through GitHub Device Flow.

The initial public build is ad-hoc signed because this project does not yet have a Developer ID Application certificate. On first launch, macOS may require you to Control-click the app and choose **Open**. A future Developer ID build can remove that limitation after signing and Apple notarization.

## What it shows

- Open, non-draft PRs currently assigned to the authenticated account
- A reconciled authored-PR backlog ledger for rolling 48-hour, 7-day, and 30-day windows
- Window-scoped handoff, merge, approval, and changes-requested events with explicit acceptance numerators and denominators
- Window merge count and median merge time, plus current authored-backlog size and median age
- A small new-versus-merged activity chart
- A local **Needs attention** inbox driven by configurable labels on open pull requests in one GitHub organization

The app does not mutate GitHub data. It stores the OAuth token in your local Keychain and does not persist source code, diffs, comments, or review bodies. No account data, token, metrics cache, preferences, or notifications are included in release artifacts. See [PRIVACY.md](PRIVACY.md) for the complete data-handling summary.

Configure an organization and up to three ordered action labels in Settings. GitHub's current labels are authoritative: adding a configured label creates a quiet banner, feed row, and colored menu-bar dot; removing it or closing the PR removes that state. Multiple labels consolidate into one PR row. Seeing the row, opening it, or opening its macOS notification clears the dot while leaving the row visible; only GitHub label removal or PR closure removes it.

## Configure GitHub authentication

1. In GitHub, open **Settings → Developer settings → OAuth Apps → New OAuth App**.
2. Give the app any name and homepage URL you prefer.
3. Enable **Device Flow** after creating the OAuth App.
4. Build and launch PR Throughput.
5. Paste the OAuth App's public client ID into the onboarding field and choose **Sign in with GitHub**.

No client secret is used. New authorizations request `repo read:user`; GitHub's `repo` scope is broad because GitHub does not provide read-only OAuth access to private repository pull requests. The app does not request the GitHub `notifications` scope. Organizations may require an administrator to approve the OAuth App.

## Build

Building from source requires Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen). Install XcodeGen with `brew install xcodegen` if needed.

```sh
xcodegen generate
xcodebuild test -project PRThroughput.xcodeproj -scheme PRThroughput -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO
```

Open `PRThroughput.xcodeproj` in Xcode for normal local development and signing.

To create a local universal release bundle in `outputs/PRThroughput.app`:

```sh
Scripts/build_release.sh
```

Set `GITHUB_CLIENT_ID` in the environment or copy `Config/Local.xcconfig.example` to the ignored `Config/Local.xcconfig` file if you want to preconfigure the public OAuth client ID in a release build. The client ID is public configuration; never add a client secret.

The script applies an ad-hoc signature. For warning-free distribution, sign the archive with a Developer ID Application certificate and notarize it with Apple.

## Live end-to-end validation

The optional E2E executable uses the production read-only GitHub client and synchronization pipeline, performs a cold 30-day backfill followed by a cached refresh, and prints only aggregate counts:

```sh
xcodegen generate
xcodebuild build -project PRThroughput.xcodeproj -scheme PRThroughputLiveE2E -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/LiveE2E CODE_SIGNING_ALLOWED=NO
security find-generic-password -w -a oauth-token -s app.prthroughput.PRThroughput.github | build/LiveE2E/Build/Products/Debug/PRThroughputLiveE2E
```

The token is consumed through standard input and is never printed, persisted, or included in process arguments.

To validate action labels too, set `PR_THROUGHPUT_ACTION_ORGANIZATION` and up to three
`PR_THROUGHPUT_ACTION_LABEL_1`, `_2`, and `_3` environment variables. The harness checks
the same direct-label authority, colors, safe PR URLs, configuration revision, and
reconciliation invariants used by the app; it still performs no GitHub writes.
For a focused low-cost check, pass `--action-only` and provide comma-separated GraphQL
PR node IDs in `PR_THROUGHPUT_ACTION_CANDIDATE_IDS`; this is useful when deliberately
testing around GitHub search-index lag without repeating the 30-day metrics crawl.

To capture the canonical KPI snapshot used by the menu-bar UI or another local automation:

```sh
Scripts/capture_canonical_metrics.sh build/canonical-metrics.json
```

Set `PR_THROUGHPUT_EXPECTED_LOGIN` when an unattended consumer must fail closed unless the token belongs to one particular GitHub login.

`PRThroughput/Domain/WindowMetrics.swift` owns the rolling backlog ledger, review activity, and window KPIs. `PRThroughput/Domain/MetricContract.swift` publishes that model through canonical contract v4; downstream consumers should use the export rather than recreating formulas. Every range is anchored to the same verified full-sync `asOf`, with an exact window start, source digest, transition IDs, and numerator/denominator facts.

Every accepted snapshot passes source and metric reconciliation before it can replace the last trusted totals. The checks reject duplicate or orphaned facts, handoffs that cannot be reproduced from the GitHub timeline, contradictory PR terminal state, broken shipping/review partitions, and rates that do not match their displayed numerators and denominators. The menu shows “Reconciled” for a snapshot that passed these checks; the canonical exporter independently repeats the arithmetic checks at its JSON boundary.

The capture is unattended-safe: build, Keychain, and GitHub synchronization steps have process-group deadlines; failures leave the prior output untouched and remove temporary build/output files.

For repeatable visual regression checks without reading Keychain or contacting GitHub, build and run the `PRThroughputUIQA` scheme. It hosts the production dashboard and Settings views with deterministic fixture data.

## Metric definitions

- A PR enters active authored work when it first opens as non-draft or is first marked ready for review. Draft and closed PRs are outside the active backlog.
- Open at start is the active authored backlog immediately before the selected window. New and re-entered transitions add work; merge, close, and draft transitions remove work; the result must equal open now.
- All event counts use the exact selected rolling window and one verified full-sync closing timestamp.
- A handoff requires the authenticated user to be unassigned, a named person to be assigned, and that person to be requested for review within a five-minute span.
- Handoff activity counts cycles, so repeated handoffs of one PR count separately. Withdrawn cycles do not count.
- Each completed review cycle counts separately, including repeated reviews of the same PR. A later GitHub review dismissal does not erase the original review event from the historical KPI.
- Median age now is elapsed time since first eligibility among active authored PRs at the closing boundary.
- Median merge is first-eligibility-to-merge duration for PRs merged in the selected window.
- Acceptance is approval review events divided by approval plus changes-requested events in the selected window.
- Awaiting now is closing-boundary state. Pending and withdrawn handoffs are excluded from acceptance; withdrawn cycles remain internal history only.
- Team and bot review requests do not count.
