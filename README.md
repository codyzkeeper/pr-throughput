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
- Opened, handoff, merge, approval, and changes-requested events in rolling 48-hour, 7-day, and 30-day windows
- Opening-cohort merge completion, median open age, acceptance, and median time to merge
- A small opened-versus-merged activity chart
- A local, tag-only inbox for unread GitHub notifications that can be verified as a direct `@username` mention

The app does not mutate GitHub data. It stores the OAuth token in your local Keychain and does not persist source code, diffs, comments, or review bodies. No account data, token, metrics cache, preferences, or notifications are included in release artifacts. See [PRIVACY.md](PRIVACY.md) for the complete data-handling summary.

The menu-bar red dot appears only for a verified direct mention that has not yet appeared in the inbox. Seeing the row clears the dot while leaving the row available; opening or clearing the row dismisses it. Assignments, review requests, team mentions, and review decisions never enter this inbox.

## Configure GitHub authentication

1. In GitHub, open **Settings → Developer settings → OAuth Apps → New OAuth App**.
2. Give the app any name and homepage URL you prefer.
3. Enable **Device Flow** after creating the OAuth App.
4. Build and launch PR Throughput.
5. Paste the OAuth App's public client ID into the onboarding field and choose **Sign in with GitHub**.

No client secret is used. GitHub's OAuth `repo` scope is broad because GitHub does not provide read-only OAuth access to private repository pull requests. Organizations may require an administrator to approve the OAuth App.

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

To capture the canonical KPI snapshot used by the menu-bar UI or another local automation:

```sh
Scripts/capture_canonical_metrics.sh build/canonical-metrics.json
```

Set `PR_THROUGHPUT_EXPECTED_LOGIN` when an unattended consumer must fail closed unless the token belongs to one particular GitHub login.

`PRThroughput/Domain/WindowActivityMetrics.swift` owns event-window counts and `PRThroughput/Domain/CohortMetrics.swift` owns opening-cohort KPIs. `PRThroughput/Domain/MetricContract.swift` wraps both in a versioned interchange schema; downstream consumers should use that exported JSON rather than recreating the formulas. The snapshot contains 48-hour, 7-day, and 30-day ranges, with 7 days identified as the primary range, plus an input digest and exact `asOf` timestamp. A formula or schema change must also advance the metric-contract version so incompatible snapshots are not silently compared.

Every accepted snapshot passes source and metric reconciliation before it can replace the last trusted totals. The checks reject duplicate or orphaned facts, handoffs that cannot be reproduced from the GitHub timeline, contradictory PR terminal state, broken shipping/review partitions, and rates that do not match their displayed numerators and denominators. The menu shows “Reconciled” for a snapshot that passed these checks; the canonical exporter independently repeats the arithmetic checks at its JSON boundary.

The capture is unattended-safe: build, Keychain, and GitHub synchronization steps have process-group deadlines; failures leave the prior output untouched and remove temporary build/output files.

For repeatable visual regression checks without reading Keychain or contacting GitHub, build and run the `PRThroughputUIQA` scheme. It hosts the production dashboard and Settings views with deterministic fixture data.

## Metric definitions

- A PR enters a cohort when first opened as non-draft or first marked ready for review.
- Raw activity counts describe events occurring during the selected window, regardless of when the affected PR entered its opening cohort. They are independent counts and do not form a partition.
- A handoff requires the authenticated user to be unassigned, a named person to be assigned, and that person to be requested for review within a five-minute span.
- Handoff activity counts cycles, so repeated handoffs of one PR count separately. Withdrawn cycles do not count.
- Each completed review cycle counts separately, including repeated reviews of the same PR. A later GitHub review dismissal does not erase the original review event from the historical KPI.
- Merge completion is merged PRs divided by all non-draft PRs in the selected opening cohort.
- Median age is the median elapsed time since cohort eligibility among PRs that are still open.
- Acceptance is approvals divided by decided reviews.
- Acceptance and rework use completed reviews as their denominator. Pending and withdrawn handoffs are excluded; withdrawn cycles remain internal history only.
- Team and bot review requests do not count.
