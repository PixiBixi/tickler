import SwiftUI
import TicklerCore

/// The Claude Code SessionStart hook, the same entry `tickler hook install` writes.
struct HookInstallRow: View {
    @State private var state = ClaudeHook.State.notInstalled
    @State private var error: String?

    private var settings: URL {
        ClaudeHook.settingsFile(environment: ProcessInfo.processInfo.environment)
    }

    /// The app has no shell PATH: look where the cask and `make install` put the CLI.
    private var command: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ClaudeHook.ticklerPath(environment: ["PATH": "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin"])
            .map(ClaudeHook.command(ticklerPath:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(statusText, systemImage: state == .upToDate ? "checkmark.seal.fill" : "circle.dashed")
                    .foregroundStyle(state == .upToDate ? .green : (state == .notInstalled ? .secondary : .orange))
                Spacer()
                if state != .upToDate {
                    Button(state == .notInstalled ? "Install Hook" : "Update Hook", action: install)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(command == nil)
                }
            }
            Text("Claude hears about this repository's reminders when a session starts.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Text(verbatim: settings.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if command == nil {
                Text("Install the tickler command first.").font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            if let error {
                Text(verbatim: error).font(.system(size: 11.5)).foregroundStyle(.orange)
            }
        }
        .onAppear(perform: refresh)
    }

    private var statusText: LocalizedStringKey {
        switch state {
        case .notInstalled: "Not installed"
        case .outdated: "Installed, with another path"
        case .upToDate: "Installed"
        }
    }

    private func refresh() {
        state = ClaudeHook.state(settings: settings, command: command ?? "")
    }

    private func install() {
        guard let command else { return }
        do {
            try ClaudeHook.install(settings: settings, command: command)
            error = nil
        } catch {
            self.error = String(describing: error)
        }
        refresh()
    }
}
