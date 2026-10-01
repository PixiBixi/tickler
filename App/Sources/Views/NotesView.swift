import SwiftUI
import TicklerCore

/// Notes as rendered Markdown; a click switches to the raw text. The Markdown stays the source Claude reads and writes.
struct NotesView: View {
    @Binding var text: String
    @Binding var isEditing: Bool
    var focused: FocusState<Bool>.Binding
    let minHeight: CGFloat
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Notes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if isEditing {
                    Text(verbatim: "**gras**  *italique*  `code`  # titre  - liste  [lien](url)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Button("Done") { finish() }
                        .buttonStyle(SecondaryButtonStyle())
                        .controlSize(.small)
                } else {
                    Button { start() } label: { Label("Edit", systemImage: "pencil") }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
            Group {
                if isEditing {
                    TextEditor(text: $text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .focused(focused)
                        .onExitCommand { finish() }
                } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Add notes, commands or links…")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .onTapGesture { start() }
                } else {
                    MarkdownView(markdown: text)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { start() }
                }
            }
            .frame(minHeight: minHeight, alignment: .topLeading)
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isEditing ? Theme.accent.opacity(0.6) : .clear))
        }
    }

    private func start() {
        isEditing = true
        focused.wrappedValue = true
    }

    private func finish() {
        isEditing = false
        focused.wrappedValue = false
        onCommit()
    }
}

/// Block Markdown drawn natively: headings, lists, quotes and code fences; inline syntax through AttributedString.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(MarkdownNotes.blocks(from: markdown).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .tint(Theme.accent)
    }

    @ViewBuilder
    private func view(for block: MarkdownNotes.Block) -> some View {
        switch block {
        case let .heading(level, text):
            inline(text).font(.system(size: level == 1 ? 17 : (level == 2 ? 15 : 13.5), weight: .semibold))
                .padding(.top, 4)
        case let .bullet(text, depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(Color.secondary).frame(width: 4.5, height: 4.5).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * 16 + 2)
        case let .numbered(marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker).foregroundStyle(.secondary).monospacedDigit()
                inline(text)
            }
        case let .code(code):
            Text(verbatim: code)
                .font(.system(size: 12, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        case let .quote(text):
            inline(text).foregroundStyle(.secondary).italic().padding(.leading, 10)
        case let .paragraph(text):
            inline(text)
        case .spacer:
            Color.clear.frame(height: 4)
        }
    }

    private func inline(_ text: String) -> Text {
        let source = MarkdownNotes.autolink(text)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(text)
        return Text(attributed).font(.system(size: 13))
    }
}
