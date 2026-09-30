import SwiftUI
import TicklerCore

enum Theme {
    static let accent = Color.accentColor
    /// The design's three grounds, system colors so light mode follows.
    static let sidebarBackground = Color(nsColor: .underPageBackgroundColor)
    static let listBackground = Color(nsColor: .windowBackgroundColor)
    static let detailBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.125, green: 0.125, blue: 0.137, alpha: 1)
            : NSColor(srgbRed: 0.984, green: 0.984, blue: 0.988, alpha: 1)
    })
    static let overdue = Color(red: 1.0, green: 0.42, blue: 0.38)
    /// Dark text on the accent fill: white on it fails contrast.
    static let onAccent = Color(red: 0.11, green: 0.07, blue: 0.03)

    static func dot(for bucket: DueBucket, soon: Bool) -> Color {
        switch bucket {
        case .overdue: overdue
        case .today: soon ? accent : Color.secondary
        case .tomorrow, .later: Color.secondary.opacity(0.5)
        }
    }

    static func tag(for kind: LinkKind) -> (text: String, color: Color) {
        switch kind {
        case .gitlabMR: ("MR", Color(red: 1.0, green: 0.6, blue: 0.4))
        case .githubPR: ("PR", Color(red: 0.6, green: 0.75, blue: 1.0))
        case .jira: ("Jira", Color(red: 0.49, green: 0.71, blue: 1.0))
        case .grafana: ("Grafana", Color(red: 0.96, green: 0.72, blue: 0.3))
        case .slack: ("Slack", Color(red: 0.37, green: 0.84, blue: 0.71))
        case .other: (String(localized: "Link"), Color.secondary)
        }
    }
}

extension Reminder {
    /// Due within the next 30 minutes: shown in the accent color.
    func isSoon(now: Date) -> Bool {
        dueAt >= now && dueAt.timeIntervalSince(now) <= 30 * 60
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, primary: true)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, primary: false)
    }
}

/// The design's two buttons: accent fill with dark text, or an outlined one. Dimmed when disabled.
private struct StyledButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration
    let primary: Bool

    var body: some View {
        let label = configuration.label
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, primary ? 14 : 12)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        Group {
            if primary {
                label
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 8))
            } else {
                label
                    .font(.system(size: 13))
                    .background(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.0001), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.2)))
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

struct ToastOverlay: View {
    let toast: Toast?

    var body: some View {
        if let toast {
            HStack(spacing: 8) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? Theme.overdue : Color.green)
                Text(toast.message)
                    .font(.system(size: 13))
                    .lineLimit(3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}
