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
        case .tomorrow, .later, .waiting: Color.secondary.opacity(0.5)
        }
    }

    static func tag(for kind: LinkKind) -> (text: String, color: Color) {
        switch kind {
        case .gitlabMR: ("MR", Color(red: 0.99, green: 0.43, blue: 0.15))
        case .githubPR: ("PR", Color.primary)
        case .jira: ("Jira", Color(red: 0.3, green: 0.6, blue: 1.0))
        case .grafana: ("Grafana", Color(red: 0.96, green: 0.45, blue: 0.1))
        case .slack: ("Slack", Color(red: 0.18, green: 0.71, blue: 0.49))
        case .other: (String(localized: "Link"), Color.secondary)
        }
    }

    /// The service's logo (Simple Icons, CC0); Slack withdrew its icon from there, so it gets a plain "#".
    static func logo(for kind: LinkKind) -> Image {
        switch kind {
        case .gitlabMR: Image("Brand-gitlab")
        case .githubPR: Image("Brand-github")
        case .jira: Image("Brand-jira")
        case .grafana: Image("Brand-grafana")
        case .slack: Image(systemName: "number")
        case .other: Image(systemName: "link")
        }
    }
}

/// Logo plus a short kind ("MR", "PR") where the logo alone does not say what the link is.
struct LinkBadge: View {
    let kind: LinkKind

    var body: some View {
        let tag = Theme.tag(for: kind)
        HStack(spacing: 4) {
            Theme.logo(for: kind)
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
            if kind == .gitlabMR || kind == .githubPR {
                Text(tag.text).font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(tag.color)
        .frame(minWidth: 40, minHeight: 20)
        .padding(.horizontal, 4)
        .background(tag.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
        .help(tag.text)
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
