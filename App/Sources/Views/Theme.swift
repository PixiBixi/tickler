import SwiftUI
import TicklerCore

enum Theme {
    static let accent = Color.accentColor
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
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 13))
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.12)))
            .contentShape(Rectangle())
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
