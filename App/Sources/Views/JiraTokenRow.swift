import SwiftUI

/// Jira API token for the ticket status: saved in Tickler's keychain entry, checked with `jira me`.
struct JiraTokenRow: View {
    @Environment(AppModel.self) private var model
    @State private var token = ""
    @State private var saved = JiraToken.isSet
    @State private var result: (ok: Bool, message: String)?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Jira API Token")
                Spacer()
                Label(saved ? "Saved in the keychain" : "Missing", systemImage: saved ? "checkmark.seal.fill" : "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(saved ? .green : .orange)
            }
            HStack(spacing: 8) {
                SecureField("Jira API Token", text: $token, prompt: Text(saved ? "Paste a new token to replace it" : "Paste your token"))
                    .labelsHidden()
                    .onSubmit(save)
                Button("Save", action: save).disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Test", action: test).disabled(!saved || testing)
                if saved {
                    Button("Remove", role: .destructive, action: remove)
                }
            }
            if let result {
                Text(verbatim: result.message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(result.ok ? .green : .orange)
                    .textSelection(.enabled)
            }
            Link(
                "Create a token at id.atlassian.com",
                destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!
            )
            .font(.system(size: 11.5))
        }
    }

    private func save() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try JiraToken.save(trimmed)
            token = ""
            saved = true
            model.liveStatus.forgetTickets()
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
        } catch {
            result = (false, error.localizedDescription)
        }
    }
}
