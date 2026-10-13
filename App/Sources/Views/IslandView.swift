import SwiftUI
import TicklerCore

/// Renders an `IslandPlan`: title, countdown and "+N" badge on a black pill matching the notch.
struct IslandView: View {
    let reminder: Reminder
    let others: Int
    let topInset: CGFloat
    let rowHeight: CGFloat
    /// The first MR or PR link, opened by its logo button.
    let reviewLink: ReminderLink?
    let canResume: Bool
    let onAction: (IslandAction) -> Void

    var body: some View {
        // A tap gesture rather than a Button: the inner buttons win over it, nested Buttons do not.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            row(now: context.date)
        }
        .padding(.top, topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(.black))
        .contentShape(shape)
        .onTapGesture { onAction(.reveal) }
        .environment(\.colorScheme, .dark)
    }

    private var shape: UnevenRoundedRectangle {
        let top: CGFloat = topInset > 0 ? 0 : 12
        return UnevenRoundedRectangle(
            topLeadingRadius: top, bottomLeadingRadius: 12, bottomTrailingRadius: 12, topTrailingRadius: top
        )
    }

    private func row(now: Date) -> some View {
        let minutes = Int((reminder.dueAt.timeIntervalSince(now) / 60).rounded(.up))
        return HStack(spacing: 8) {
            Image(systemName: "alarm")
                .foregroundStyle(minutes > 0 ? Theme.accent : Theme.overdue)
            Text(verbatim: reminder.title)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            Text(minutes > 0 ? String(localized: "\(minutes) min") : String(localized: "now"))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if others > 0 {
                Text(verbatim: "+\(others)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.15)))
            }
            if let reviewLink {
                iconButton(Theme.logo(for: reviewLink.kind), help: Theme.tag(for: reviewLink.kind).text) {
                    onAction(.openLink(reviewLink))
                }
            }
            if canResume {
                iconButton(Image(systemName: "terminal"), help: String(localized: "Resume Session")) { onAction(.resume) }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(height: rowHeight)
    }

    private func iconButton(_ image: Image, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            image.renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

enum IslandAction {
    case reveal
    case openLink(ReminderLink)
    case resume
}
