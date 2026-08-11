# Privacy

PR Throughput is a local, read-only GitHub client.

## Data the app accesses

After you authorize the app, it reads GitHub account identity, accessible pull requests, assignments, timeline events, reviews, review requests, and current labels needed to calculate the displayed metrics and configured action states.

GitHub's OAuth `repo` scope is broad because GitHub does not offer a read-only OAuth scope for pull requests in private repositories. The app does not create, edit, merge, close, assign, review, or comment on GitHub content.

## Data stored on your Mac

- The OAuth access token is stored in macOS Keychain as a device-only item.
- Aggregate source facts, metric state, label-application IDs, and local seen/dismissed state are stored in the app's sandboxed Application Support container.
- Preferences are stored in the app's sandboxed preferences container.
- The app does not persist repository source code, diffs, comment bodies, or review bodies.

## Network access

The app communicates directly with `github.com` and `api.github.com`. It does not include analytics, advertising, crash-reporting, or a developer-operated backend.

## Distribution artifacts

Release archives contain only the compiled application and its resources. They do not contain a developer token, user token, GitHub account data, metrics cache, preferences, notifications, local paths, or build logs. A preconfigured GitHub OAuth client ID may be embedded; OAuth client IDs are public identifiers and are not credentials. No OAuth client secret is used.

## Removing local data

Use **Sign out** in the app to remove its OAuth token and cached snapshot. Removing the app afterward deletes the executable; macOS may retain sandbox preferences until its app container is removed by the user.
