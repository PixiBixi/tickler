import SwiftUI
import TicklerCore

/// "Is the action still needed?": pipeline, approvals, ticket state, straight from glab, jira and gh.
struct LiveStatusSection: View {
    @Environment(AppModel.self) private var model
    let reminder: Reminder

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
                ForEach(links, id: \.url) { link in
                    LiveCard(link: link, entry: model.liveStatus.entries[link.url])
                }
            }
            .onAppear { model.liveStatus.refresh(links) }
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let error = entry?.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            } else if let status = entry?.status {
                switch status {
                case let .mergeRequest(mr): mergeRequest(mr)
                case let .ticket(ticket): self.ticket(ticket)
                case let .pullRequest(pr): pullRequest(pr)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 8) {
            LinkBadge(kind: link.kind)
            Text(link.label).font(.system(size: 13, weight: .semibold))
            if let title = statusTitle {
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if entry?.loading == true, entry?.status != nil {
                ProgressView().controlSize(.mini)
            }
        }
    }

    private var statusTitle: String? {
        switch entry?.status {
        case let .mergeRequest(mr): mr.title
        case let .ticket(ticket): ticket.summary
        case let .pullRequest(pr): pr.title
        case nil: nil
        }
    }

    // MARK: Merge request

    private func mergeRequest(_ mr: MergeRequestStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                chip(stateText(mr), color: mr.state == "merged" ? .purple.opacity(0.8) : (mr.state == "opened" ? .secondary : .secondary))
                if let pipeline = mr.pipeline {
                    chip(String(localized: "pipeline \(pipeline.rawValue)"), color: color(for: pipeline))
                }
                chip(
                    String(localized: "approvals \(mr.approvalsGiven)/\(mr.approvalsRequired)"),
                    color: mr.approvalsGiven >= mr.approvalsRequired ? .green : .secondary
                )
                if mr.hasConflicts {
                    chip(String(localized: "conflicts"), color: Theme.overdue)
                }
                if !mr.discussionsResolved {
                    chip(String(localized: "open threads"), color: .orange)
                }
                if mr.userHasApproved {
                    chip(String(localized: "approved by you"), color: .green)
                }
            }
            HStack(spacing: 8) {
                if mr.canMergeNow || mr.canMergeWhenPipelinePasses {
                    Button { confirmMerge = true } label: {
                        Label(mr.canMergeNow ? "Merge…" : "Merge When Pipeline Passes…", systemImage: "arrow.triangle.merge")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                if mr.canApproveNow {
                    Button { confirmApproval = true } label: { Label("Approve…", systemImage: "checkmark.seal") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                Button("Open in GitLab") { openURL(mr.webURL) }
                    .buttonStyle(SecondaryButtonStyle())
                if let pipeline = mr.pipelineURL {
                    Button("Pipeline") { openURL(pipeline) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .confirmationDialog(Text("Merge \(link.label)?"), isPresented: $confirmMerge, titleVisibility: .visible) {
            Button(mr.canMergeNow ? "Merge" : "Merge When Pipeline Passes") { merge(whenPipelinePasses: !mr.canMergeNow) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("GitLab merges it in your name, with the merge request's own options (squash, source branch removal). \(mr.title)")
        }
        .confirmationDialog(Text("Approve \(link.label)?"), isPresented: $confirmApproval, titleVisibility: .visible) {
            Button("Approve") { approve() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The approval is sent to GitLab in your name and notifies the author. \(mr.title)")
        }
    }

    private func merge(whenPipelinePasses: Bool) {
        Task {
            switch await model.liveStatus.merge(link, whenPipelinePasses: whenPipelinePasses) {
            case .success:
                model
                    .showToast(whenPipelinePasses ? String(localized: "\(link.label) will merge when the pipeline passes") :
                        String(localized: "Merged \(link.label)"))
            case let .failure(error):
                model.showError(String(describing: error))
            }
        }
    }

    private func stateText(_ mr: MergeRequestStatus) -> String {
        if mr.draft {
            return String(localized: "draft")
        }
        switch mr.state {
        case "opened": return String(localized: "open")
        case "merged": return String(localized: "merged")
        case "closed": return String(localized: "closed")
        default: return mr.state
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

    // MARK: Ticket and pull request

    private func ticket(_ ticket: TicketStatus) -> some View {
        HStack(spacing: 6) {
            chip(ticket.status, color: ticket.category == .done ? .green : (ticket.category == .inProgress ? Theme.accent : .secondary))
            Text(ticket.assignee ?? String(localized: "Unassigned")).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button("Open") { openURL(link.url) }.buttonStyle(SecondaryButtonStyle())
        }
    }

    private func pullRequest(_ pr: PullRequestStatus) -> some View {
        HStack(spacing: 6) {
            chip(
                pr.draft ? String(localized: "draft") : pr.state.lowercased(),
                color: pr.state == "MERGED" ? .purple.opacity(0.8) : .secondary
            )
            if pr.checks.failed > 0 {
                chip(String(localized: "\(pr.checks.failed) checks failed"), color: Theme.overdue)
            } else if pr.checks.pending > 0 {
                chip(String(localized: "\(pr.checks.pending) checks running"), color: .orange)
            } else if pr.checks.passed > 0 {
                chip(String(localized: "checks passed"), color: .green)
            }
            if let decision = pr.reviewDecision {
                chip(decision.replacingOccurrences(of: "_", with: " ").lowercased(), color: decision == "APPROVED" ? .green : .secondary)
            }
            Spacer()
            Button("Open") { openURL(pr.url) }.buttonStyle(SecondaryButtonStyle())
        }
    }

    // MARK: Helpers

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
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
