import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.trianglehead.branch")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.blue)
            VStack(spacing: 5) {
                Text("PR Throughput").font(.title2.bold())
                Text("A private, read-only view of shipping velocity and review cost.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            if let authorization = model.deviceAuthorization {
                VStack(spacing: 10) {
                    Text("Enter this code on GitHub").font(.headline)
                    Text(authorization.userCode).font(.system(.title, design: .monospaced).bold()).textSelection(.enabled)
                    Link("Open GitHub", destination: authorization.verificationURL)
                    Button("Cancel") { model.cancelSignIn() }.buttonStyle(.plain)
                }
                .padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("OAuth App client ID").font(.caption).foregroundStyle(.secondary)
                    TextField("Public client ID", text: $model.oauthClientID)
                        .textFieldStyle(.roundedBorder)
                    Text(model.hasBundledOAuthClientID
                         ? "This release includes a public client ID. You may replace it with one from your own Device Flow OAuth App."
                         : "Create a GitHub OAuth App, enable Device Flow, then paste its public client ID. No client secret is used.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Sign in with GitHub") { model.signIn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.connectionState == .authorizing)
            }

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(minHeight: 340)
    }
}
