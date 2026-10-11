import SwiftUI
import TicklerCore

/// Jira API token for the ticket status: saved in Tickler's keychain entry, checked with `jira me`.
struct JiraTokenRow: View {
    @Environment(AppModel.self) private var model
    var onChange: () -> Void = {}
    @State private var token = ""
    @State private var saved = false
    /// The keychain is read once in `.task`; until then the status is hidden so "No token saved" never flashes.
    @State private var loaded = false
    @State private var result: (ok: Bool, message: String)?
    @State private var testing = false
    /// A token already exported by a shell file, offered for import; never saved without a click.
    @State private var found: JiraTokenDiscovery.Found?
    /// A saved token hides the field until Replace is clicked.
    @State private var replacing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Jira API Token")
                Spacer()
                Label(
                    saved ? "Saved in the keychain" : "No token saved",
                    systemImage: saved ? "checkmark.seal.fill" : "exclamationmark.triangle"
                )
                .font(.system(size: 11.5))
                .foregroundStyle(saved ? .green : .orange)
                if saved, !replacing {
                    Button("Test", action: test).disabled(testing)
                    Button("Replace…") { replacing = true }
                    Button("Remove", role: .destructive, action: remove)
                }
            }
            if !saved, let found {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill").foregroundStyle(Theme.accent)
                    Text("Found a token in \(found.path)")
                    Spacer()
                    Button("Import Token") { save(found.token) }
                        .buttonStyle(PrimaryButtonStyle())
                }
                .font(.system(size: 12))
                .padding(8)
                .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if !saved || replacing {
                HStack(spacing: 8) {
                    SecureField(
                        "Jira API Token",
                        text: $token,
                        prompt: Text(saved ? "Paste a new token to replace it" : "Paste your token")
                    )
                    .labelsHidden()
                    .onSubmit { save(token) }
                    Button("Save") { save(token) }.disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                    if replacing {
                        Button("Cancel") {
                            replacing = false
                            token = ""
                        }
                    }
                }
                Link(
                    "Create a token at id.atlassian.com",
                    destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!
                )
                .font(.system(size: 11.5))
            }
            if let result {
                Text(verbatim: result.message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(result.ok ? .green : .orange)
                    .textSelection(.enabled)
            }
        }
        .opacity(loaded ? 1 : 0)
        .task {
            saved = JiraToken.isSet
            loaded = true
            if !saved {
                found = await Task.detached { JiraTokenDiscovery.find() }.value
            }
        }
    }

    private func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try JiraToken.save(trimmed)
            token = ""
            saved = true
            replacing = false
            model.liveStatus.forgetTickets()
            onChange()
            test()
        } catch {
            result = (false, error.localizedDescription)
        }
    }

    private func test() {
        testing = true
        Task {
            switch await model.liveStatus.testJira() {
            case let .success(login): result = (true, String(localized: "Connected as \(login)"))
            case let .failure(error): result = (false, String(describing: error))
            }
            testing = false
        }
    }

    private func remove() {
        do {
            try JiraToken.remove()
            saved = false
            result = nil
            model.liveStatus.forgetTickets()
            onChange()
        } catch {
            result = (false, error.localizedDescription)
        }
    }
}
