import SwiftUI
import TicklerCore

/// "Is the action still needed?": pipeline, approvals, ticket state, straight from glab, jira and gh.
struct LiveStatusSection: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder
    @State private var showFinished = false

    var body: some View {
        let links = model.liveStatus.supported(model.links(of: reminder))
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Live Status").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if let age = oldestFetch(links) {
                        Text("updated \(Format.relative(age, now: model.now))").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Button { model.liveStatus.refresh(links, force: true) } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                }
                let finished = links.filter { LiveCard.isFinished(model.liveStatus.entries[$0.url]?.status) }
                VStack(spacing: 6) {
                    ForEach(sorted(links).filter { showFinished || !finished.contains($0) }, id: \.url) { link in
                        LiveCard(link: link, entry: model.liveStatus.entries[link.url])
                    }
                    // Merged MRs and done tickets are history: folded away unless asked for.
                    if !finished.isEmpty {
                        Button { withAnimation(.easeOut(duration: 0.15)) { showFinished.toggle() } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: showFinished ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                                Text(showFinished ? String(localized: "Hide finished") : String(localized: "\(finished.count) finished"))
                                Spacer()
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .onAppear { model.liveStatus.refresh(links) }
        }
    }

    /// Still-open items first: a merged MR or a closed ticket is history, not a to-do.
    private func sorted(_ links: [ReminderLink]) -> [ReminderLink] {
        links.enumerated().sorted { lhs, rhs in
            let left = LiveCard.isFinished(model.liveStatus.entries[lhs.element.url]?.status)
            let right = LiveCard.isFinished(model.liveStatus.entries[rhs.element.url]?.status)
            return left == right ? lhs.offset < rhs.offset : !left
        }.map(\.element)
    }

    private func oldestFetch(_ links: [ReminderLink]) -> Date? {
        links.compactMap { model.liveStatus.entries[$0.url]?.fetchedAt }.min()
    }
}

private struct LiveCard: View {
    @Environment(AppModel.self) private var model
    let link: ReminderLink
    let entry: LiveStatusStore.Entry?
    @State private var confirmApproval = false
    @State private var confirmMerge = false
    @State private var hovering = false

    static func isFinished(_ status: LiveStatus?) -> Bool {
        switch status {
        case let .mergeRequest(mr): mr.state != "opened"
        case let .ticket(ticket): ticket.category == .done
        case let .pullRequest(pr): pr.state != "OPEN"
        case nil: false
        }
    }

    var body: some View {
        let finished = Self.isFinished(entry?.status)
        VStack(alignment: .leading, spacing: 8) {
            header
            if !finished {
                details
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, finished ? 8 : 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(hovering ? 0.07 : 0.04), in: RoundedRectangle(cornerRadius: 9))
        .opacity(finished ? 0.65 : 1)
        .onHover { hovering = $0 }
        .modifier(MergeDialogs(link: link, status: entry?.status, confirmApproval: $confirmApproval, confirmMerge: $confirmMerge))
    }

    /// Logo, name, title and state on one line; the whole line opens the item.
    private var header: some View {
        HStack(spacing: 8) {
            Theme.logo(for: link.kind)
                .resizable().scaledToFit().frame(width: 14, height: 14)
                .foregroundStyle(Theme.tag(for: link.kind).color)
            Text(link.label).font(.system(size: 13, weight: .semibold)).lineLimit(1).layoutPriority(1)
            if let title = statusTitle {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if entry?.loading == true {
                ProgressView().controlSize(.mini)
            }
            if let state = stateLabel {
                Text(state.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(state.color)
            }
            Button { openURL(webURL) } label: {
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Open")
        }
    }

    @ViewBuilder
    private var details: some View {
        if let error = entry?.error {
            Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange).lineLimit(2)
        } else if let status = entry?.status {
            switch status {
            case let .mergeRequest(mr): mergeRequest(mr)
            case let .ticket(ticket): self.ticket(ticket)
            case let .pullRequest(pr): pullRequest(pr)
            }
        }
    }

    // MARK: Merge request

    private func mergeRequest(_ mr: MergeRequestStatus) -> some View {
        FlowLayout(spacing: 14, lineSpacing: 8) {
            if let pipeline = mr.pipeline {
                Button { mr.pipelineURL.map(openURL) } label: {
                    fact(icon(for: pipeline), String(localized: "Pipeline"), color(for: pipeline))
                }
                .buttonStyle(.plain)
                .help(pipeline.rawValue)
            }
            fact(
                "person.2",
                "\(mr.approvalsGiven)/\(mr.approvalsRequired)",
                mr.approvalsGiven >= mr.approvalsRequired ? .green : .secondary
            )
            .help(mr.approvedBy.isEmpty ? String(localized: "No approval yet") : mr.approvedBy.joined(separator: ", "))
            if !mr.discussionsResolved {
                fact("bubble.left.and.exclamationmark.bubble.right", String(localized: "Open threads"), .orange)
            }
            if mr.hasConflicts {
                fact("exclamationmark.triangle", String(localized: "Conflicts"), Theme.overdue)
            }
            if mr.canMergeNow || mr.canMergeWhenPipelinePasses {
                Button { confirmMerge = true } label: {
                    Label(mr.canMergeNow ? "Merge…" : "Merge When Pipeline Passes…", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(PrimaryButtonStyle())
                .controlSize(.small)
            } else if mr.canApproveNow {
                Button { confirmApproval = true } label: { Label("Approve…", systemImage: "checkmark.seal") }
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.small)
            }
        }
    }

    // MARK: Ticket and pull request

    private func ticket(_ ticket: TicketStatus) -> some View {
        HStack(spacing: 14) {
            fact("person", ticket.assignee ?? String(localized: "Unassigned"), .secondary)
            Spacer(minLength: 0)
        }
    }

    private func pullRequest(_ pr: PullRequestStatus) -> some View {
        HStack(spacing: 14) {
            if pr.checks.failed > 0 {
                fact("xmark.circle.fill", String(localized: "\(pr.checks.failed) checks failed"), Theme.overdue)
            } else if pr.checks.pending > 0 {
                fact("clock", String(localized: "\(pr.checks.pending) checks running"), .orange)
            } else if pr.checks.passed > 0 {
                fact("checkmark.circle.fill", String(localized: "checks passed"), .green)
            }
            if let decision = pr.reviewDecision {
                fact(
                    "person.2",
                    decision.replacingOccurrences(of: "_", with: " ").lowercased(),
                    decision == "APPROVED" ? .green : .secondary
                )
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Helpers

    private var statusTitle: String? {
        switch entry?.status {
        case let .mergeRequest(mr): mr.title
        case let .ticket(ticket): ticket.summary
        case let .pullRequest(pr): pr.title
        case nil: nil
        }
    }

    private var stateLabel: (text: String, color: Color)? {
        switch entry?.status {
        case let .mergeRequest(mr):
            if mr.draft {
                return (String(localized: "draft"), .secondary)
            }
            switch mr.state {
            case "opened": return (String(localized: "open"), .secondary)
            case "merged": return (String(localized: "merged"), Color(red: 0.7, green: 0.55, blue: 1.0))
            default: return (String(localized: "closed"), .secondary)
            }
        case let .ticket(ticket):
            return (ticket.status, ticket.category == .done ? .green : (ticket.category == .inProgress ? Theme.accent : .secondary))
        case let .pullRequest(pr):
            return (
                pr.draft ? String(localized: "draft") : pr.state.lowercased(),
                pr.state == "MERGED" ? Color(red: 0.7, green: 0.55, blue: 1.0) : .secondary
            )
        case nil:
            return nil
        }
    }

    private var webURL: String {
        if case let .mergeRequest(mr) = entry?.status {
            return mr.webURL
        }
        if case let .pullRequest(pr) = entry?.status {
            return pr.url
        }
        return link.url
    }

    private func fact(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(color)
    }

    private func icon(for pipeline: PipelineState) -> String {
        switch pipeline {
        case .success: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .running, .pending, .created: "clock"
        case .canceled, .skipped, .manual, .other: "minus.circle"
        }
    }

    private func color(for pipeline: PipelineState) -> Color {
        switch pipeline {
        case .success: .green
        case .failed: Theme.overdue
        case .running, .pending, .created: .orange
        case .canceled, .skipped, .manual, .other: .secondary
        }
    }

    private func openURL(_ string: String) {
        if let url = URL(string: string), url.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Approve and merge confirmations: both act on GitLab in the user's name.
private struct MergeDialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    let link: ReminderLink
    let status: LiveStatus?
    @Binding var confirmApproval: Bool
    @Binding var confirmMerge: Bool

    func body(content: Content) -> some View {
        let mr: MergeRequestStatus? = if case let .mergeRequest(value) = status {
            value
        } else {
            nil
        }
        content
            .confirmationDialog(Text("Merge \(link.label)?"), isPresented: $confirmMerge, titleVisibility: .visible) {
                Button(mr?.canMergeNow == true ? "Merge" : "Merge When Pipeline Passes") {
                    merge(whenPipelinePasses: mr?.canMergeNow != true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("GitLab merges it in your name, with the merge request's own options (squash, source branch removal).")
                    + Text(verbatim: " \(mr?.title ?? "")")
            }
            .confirmationDialog(Text("Approve \(link.label)?"), isPresented: $confirmApproval, titleVisibility: .visible) {
                Button("Approve") { approve() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The approval is sent to GitLab in your name and notifies the author. \(mr?.title ?? "")")
            }
    }

    private func approve() {
        Task {
            switch await model.liveStatus.approve(link) {
            case .success: model.showToast(String(localized: "Approved \(link.label)"))
            case let .failure(error): model.showError(String(describing: error))
            }
        }
    }

    private func merge(whenPipelinePasses: Bool) {
        Task {
            switch await model.liveStatus.merge(link, whenPipelinePasses: whenPipelinePasses) {
            case .success:
                model.showToast(
                    whenPipelinePasses ? String(localized: "\(link.label) will merge when the pipeline passes") :
                        String(localized: "Merged \(link.label)")
                )
            case let .failure(error):
                model.showError(String(describing: error))
            }
        }
    }
}
