import SwiftUI
import TicklerCore

/// Installs the Claude Code skill of this version into ~/.claude/skills/tickler, the same file `tickler skill install` writes.
struct SkillInstallRow: View {
    var onChange: () -> Void = {}
    @State private var state = ClaudeSkill.State.notInstalled
    @State private var error: String?
    @State private var confirmReplace = false

    private var directory: URL {
        ClaudeSkill.directory(environment: ProcessInfo.processInfo.environment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(statusText, systemImage: statusIcon)
                    .foregroundStyle(state == .upToDate ? .green : (state == .differs ? .orange : .secondary))
                Spacer()
                switch state {
                case .notInstalled:
                    Button("Install Skill") { install(force: false) }.buttonStyle(PrimaryButtonStyle())
                case .differs:
                    Button("Replace…") { confirmReplace = true }.buttonStyle(SecondaryButtonStyle())
                case .upToDate:
                    EmptyView()
                }
            }
            Text(verbatim: ClaudeSkill.file(in: directory).path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let error {
                Text(verbatim: error).font(.system(size: 11.5)).foregroundStyle(.orange)
            }
        }
        .onAppear(perform: refresh)
        .confirmationDialog("Replace the installed skill?", isPresented: $confirmReplace) {
            Button("Replace", role: .destructive) { install(force: true) }
        } message: {
            Text("It differs from the skill of Tickler \(Tickler.version): it was edited, or comes from another version. Edits are lost.")
        }
    }

    private var statusText: LocalizedStringKey {
        switch state {
        case .notInstalled: "Not installed"
        case .upToDate: "Installed, up to date"
        case .differs: "Installed, differs from this version"
        }
    }

    private var statusIcon: String {
        switch state {
        case .notInstalled: "circle.dashed"
        case .upToDate: "checkmark.seal.fill"
        case .differs: "exclamationmark.triangle"
        }
    }

    private func refresh() {
        state = ClaudeSkill.state(in: directory)
    }

    private func install(force: Bool) {
        do {
            try ClaudeSkill.install(in: directory, force: force)
            error = nil
        } catch {
            self.error = String(describing: error)
        }
        refresh()
        onChange()
    }
}
