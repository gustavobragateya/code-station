import SwiftUI

// The pieces a review is drawn with, shared by both diff layouts, the review list, the
// send dialog and the cards in Chat, so a comment looks the same wherever it turns up.

// Who left a comment: you, or the reviewer's mark on a quiet tile.
struct ReviewAvatar: View {
    // Nil for you.
    let agent: AgentKind?
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: agent?.symbol ?? "person.fill")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(agent == nil ? Theme.accent : Color.secondary)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3).fill(agent == nil ? Theme.userMessage : Theme.field))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3).stroke(Theme.border))
            .accessibilityHidden(true)
    }
}

// Every voice on a comment, overlapping, the way two reviewers on one finding read.
struct ReviewAvatars: View {
    let comment: ReviewComment
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: -size * 0.3) {
            if comment.reviewers.isEmpty {
                ReviewAvatar(agent: nil, size: size)
            } else {
                ForEach(comment.reviewers, id: \.self) { ReviewAvatar(agent: $0, size: size) }
            }
        }
    }
}

// How much a finding matters, said in words and a shape so it never rests on colour.
struct SeverityChip: View {
    let severity: ReviewComment.Severity

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(severity.label).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(fill))
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch severity {
        case .must: "exclamationmark.triangle.fill"
        case .should: "circle.fill"
        case .look: "eye"
        }
    }

    private var ink: Color {
        switch severity {
        case .must: Theme.warningText
        case .should: Theme.attentionText
        case .look: Color.secondary
        }
    }

    private var fill: Color {
        switch severity {
        case .must: Theme.warningBackground
        case .should: Theme.attention.opacity(0.14)
        case .look: Theme.field
        }
    }
}

struct QuestionTag: View {
    var body: some View {
        Text("Question")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.plan)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Theme.plan.opacity(0.12)))
            .fixedSize()
    }
}

// A key drawn as a cap, for the hints that teach the keyboard.
struct KeyCap: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
    }
}

// A comment's words, with the `code` spans reviewers write drawn as code.
struct ReviewText: View {
    let text: String
    var size: CGFloat = 12.5
    var lineLimit: Int?

    var body: some View {
        Text(Self.attributed(text))
            .scaledText(size)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: lineLimit == nil)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - Cards

// A comment as a card under its lines: who left it, which lines, whether it asks for a
// change or an answer, and what it says. A finding still waiting to be sorted wears a
// dashed amber edge and carries its Keep, Edit and keep and Dismiss buttons; anything
// already in the review offers edit and delete on hover.
struct ReviewCommentCard: View {
    let comment: ReviewComment
    var focused = false
    var showsLines = true
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    var onKeep: () -> Void = {}
    var onDismiss: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ReviewText(text: comment.body)
            ForEach(Array(comment.also.enumerated()), id: \.offset) { _, voice in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ReviewAvatar(agent: voice.agent, size: 16)
                        Text(voice.agent.title).font(.system(size: 11, weight: .semibold))
                        Text("raised the same lines").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ReviewText(text: voice.body, size: 12)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 2) }
            }
            if comment.isPending { triage }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(comment.isPending ? Theme.attention.opacity(0.06) : Theme.card))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(comment.isPending ? Theme.attention.opacity(0.7) : Theme.border,
                              style: StrokeStyle(lineWidth: 1, dash: comment.isPending ? [4, 3] : []))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10).stroke(focused ? Theme.accent : .clear, lineWidth: 2)
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(comment.spokenName)
    }

    private var header: some View {
        HStack(spacing: 7) {
            ReviewAvatars(comment: comment)
            Text(comment.authorName).scaledText(12, .semibold).lineLimit(1)
            if comment.kind == .question { QuestionTag() }
            if comment.reviewer != nil, let severity = comment.severity { SeverityChip(severity: severity) }
            if showsLines {
                Text(comment.linesLabel).scaledMono(10.5).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if comment.reviewer != nil, !comment.isPending {
                Text(comment.edited ? "Edited and kept by you" : "Kept by you")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if !comment.isPending {
                HStack(spacing: 4) {
                    GlyphButton(icon: "pencil", side: 22, action: onEdit)
                        .appTooltip("Edit")
                        .accessibilityLabel("Edit comment")
                    GlyphButton(icon: "trash", side: 22, tint: Theme.deletion, action: onDelete)
                        .appTooltip("Delete")
                        .accessibilityLabel("Delete comment")
                }
                .opacity(hovering || focused ? 1 : 0)
            }
        }
    }

    private var triage: some View {
        HStack(spacing: 10) {
            ActionButton(title: "Keep", tone: .green, height: 26, size: 11.5, icon: "checkmark", action: onKeep)
            ActionButton(title: "Edit and keep", tone: .outlined, height: 26, size: 11.5, action: onEdit)
            InlineLink(title: "Dismiss", size: 11.5, tint: Color.secondary, action: onDismiss)
            Spacer(minLength: 0)
            if focused {
                HStack(spacing: 4) {
                    KeyCap(key: "K"); Text("keep")
                    KeyCap(key: "E"); Text("edit")
                    KeyCap(key: "D"); Text("dismiss")
                }
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            } else {
                Text("Not in your review until you keep it")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

// Where a comment is written, opened right under the lines it is about.
struct ReviewComposer: View {
    @Binding var text: String
    @Binding var kind: ReviewComment.Kind
    let title: String
    let linesLabel: String
    let agentTitle: String
    let action: String
    // Shown only for a new comment, where shift-click still stretches the lines.
    var stretches = true
    var onDelete: (() -> Void)?
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ReviewAvatar(agent: nil)
                Text(title).scaledText(12, .semibold).lineLimit(1)
                Text(linesLabel).scaledMono(10.5).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    ChoicePill(title: "Change this", selected: kind == .change) { kind = .change; focused = true }
                    ChoicePill(title: "Ask a question", selected: kind == .question) { kind = .question; focused = true }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Kind of comment")
            }
            TextField(kind == .question
                      ? "What should \(agentTitle) explain? It answers without changing the code."
                      : "What should \(agentTitle) change here?",
                      text: $text, axis: .vertical)
                .lineLimit(2...8)
                .appTextField()
                .focused($focused)
                .onSubmit(save)
                .onExitCommand(perform: onCancel)
                .accessibilityLabel("Comment")
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    KeyCap(key: "↩"); Text(onDelete == nil && stretches ? "add" : "save")
                    Text("·"); KeyCap(key: "esc"); Text("cancel")
                    if stretches { Text("· shift-click a number to cover more lines").lineLimit(1) }
                }
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                if let onDelete {
                    InlineLink(title: "Delete", tint: Theme.deletion, action: onDelete)
                }
                InlineLink(title: "Cancel", tint: Color.secondary, action: onCancel)
                ActionButton(title: action, tone: .green, height: 28, size: 12,
                             keyboardShortcut: KeyboardShortcut(.return, modifiers: .command), action: save)
                    .disabled(text.isBlank)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.55)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onAppear { focused = true }
    }

    private func save() {
        guard !text.isBlank else { return }
        onSave()
    }
}

// MARK: - Review bar

// One reviewer's lane: what it is reading and for how long while it works, and what it
// came to once it stops.
struct ReviewLane: View {
    let run: SecondOpinionRun
    let stop: () -> Void
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            switch run.state {
            case .running:
                ProgressView().controlSize(.mini)
                Text(run.agent.title).font(.system(size: 12, weight: .semibold))
                Text(run.activity).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 170, alignment: .leading)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.clock(from: run.started, to: context.date)).font(.mono(11)).foregroundStyle(.tertiary)
                }
                GlyphButton(icon: "stop.fill", side: 20, action: stop)
                    .appTooltip("Stop")
                    .accessibilityLabel("Stop \(run.agent.title)")
            case .finished(let found):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.dotOn)
                Text(run.agent.title).font(.system(size: 12, weight: .semibold))
                Text((found > 0 ? counted(found, "finding") : "Nothing worth raising")
                     + " · " + Self.clock(from: run.started, to: run.ended ?? Date()))
                    .foregroundStyle(.secondary).lineLimit(1)
                GlyphButton(icon: "xmark", side: 20, action: dismiss).accessibilityLabel("Hide")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warningText)
                Text("\(run.agent.title) could not finish").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.warningText).lineLimit(1)
                Text(message).foregroundStyle(Theme.warningText.opacity(0.8)).lineLimit(1)
                    .frame(maxWidth: 160, alignment: .leading)
                    .appTooltip(message)
                InlineLink(title: "Try again", tint: Theme.warningText, action: retry)
                GlyphButton(icon: "xmark", side: 20, action: dismiss).accessibilityLabel("Hide")
            }
        }
        .font(.system(size: 11.5))
        .padding(.leading, 8).padding(.trailing, 4)
        .frame(height: 30)
        .surface(fill, cornerRadius: 8, border: border)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
    }

    private var fill: Color {
        switch run.state {
        case .running: Theme.field
        case .finished: Theme.dotOn.opacity(0.08)
        case .failed: Theme.warningBackground
        }
    }

    private var border: Color {
        switch run.state {
        case .failed: Theme.warningText.opacity(0.3)
        default: Theme.border
        }
    }

    private var spoken: String {
        switch run.state {
        case .running: "\(run.agent.title) is reviewing. \(run.activity)"
        case .finished(let found): "\(run.agent.title) finished with \(counted(found, "finding"))"
        case .failed(let message): "\(run.agent.title) could not finish. \(message)"
        }
    }

    static func clock(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

// What the second opinion is asked to read.
enum SecondOpinionScopeChoice: Hashable {
    case all, file, sinceReview
}

// The second opinion picker, a card floating over the review bar. It holds several
// choices at once, which a menu cannot.
struct SecondOpinionPicker: View {
    let sessionAgent: AgentKind
    let installed: [AgentKind]
    let running: Set<AgentKind>
    @Binding var reviewers: Set<AgentKind>
    @Binding var focus: Set<SecondOpinion.Focus>
    @Binding var scope: SecondOpinionScopeChoice
    let fileCount: Int
    let fileName: String?
    let canReadSince: Bool
    let ask: () -> Void
    let cancel: () -> Void

    private var chosen: [AgentKind] { order.filter { reviewers.contains($0) && !running.contains($0) } }

    // The session's own agent comes last: a fresh run of it has none of the conversation
    // that wrote the code, which is most of what makes a review useful.
    private var order: [AgentKind] {
        AgentKind.allCases.filter { $0 != sessionAgent && installed.contains($0) }
            + (installed.contains(sessionAgent) ? [sessionAgent] : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ask for a second opinion").font(.serif(16, .semibold))
                Text("Another agent reads these changes on its own and leaves findings. You decide which ones reach \(sessionAgent.title).")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            section("Reviewers") {
                if order.isEmpty {
                    Text("No agent CLI is installed to ask.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(order, id: \.self) { agent in
                    let busy = running.contains(agent)
                    Toggle(isOn: Binding(get: { reviewers.contains(agent) && !busy },
                                         set: { on in if on { reviewers.insert(agent) } else { reviewers.remove(agent) } })) {
                        HStack(spacing: 8) {
                            ReviewAvatar(agent: agent, size: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.title).font(.system(size: 12.5, weight: .semibold))
                                Text(agent == sessionAgent ? "A fresh run, without this conversation" : agent.vendor)
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if busy {
                                Text("Reviewing now").font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.top, -3)
                    }
                    .toggleStyle(.appCheckbox)
                    .disabled(busy)
                }
            }
            section("Look for") {
                FlowRow(spacing: 6) {
                    ForEach(SecondOpinion.Focus.allCases, id: \.self) { item in
                        ChoicePill(title: item.title, selected: focus.contains(item)) {
                            if !focus.insert(item).inserted { focus.remove(item) }
                        }
                        .accessibilityAddTraits(focus.contains(item) ? .isSelected : [])
                    }
                }
            }
            section("Changes to read") {
                HStack(spacing: 4) {
                    ChoicePill(title: "All \(counted(fileCount, "file"))", selected: scope == .all) { scope = .all }
                    if let fileName {
                        ChoicePill(title: fileName, selected: scope == .file) { scope = .file }
                    }
                    ChoicePill(title: "Since last review", selected: scope == .sinceReview, enabled: canReadSince) {
                        scope = .sinceReview
                    }
                    .appTooltip(canReadSince ? "Only what changed after the last review was sent"
                                : "Once you have sent a review, a reviewer can read only what changed after it")
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.shield").foregroundStyle(Theme.accent)
                Text("Reviewers can read files but not change them, and run without your MCP servers. They see the diff, not this conversation.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            HStack(spacing: 12) {
                Text("Usually 2 to 5 minutes").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                InlineLink(title: "Cancel", tint: Color.secondary, action: cancel)
                ActionButton(title: chosen.isEmpty ? "Pick a reviewer"
                             : "Ask " + chosen.map(\.title).joined(separator: " and "),
                             tone: .green, height: 30, size: 12, action: ask)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
        .floatingCard(cornerRadius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ask for a second opinion")
        .onExitCommand(perform: cancel)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
            content()
        }
    }
}

// MARK: - Sending

// The send dialog's body: a checklist by file, a note for the round, and on request the
// exact words the agent will read. Anything unticked stays in the review.
struct SendReviewSheet: View {
    let agentTitle: String
    let comments: [ReviewComment]
    let pendingCount: Int
    let busy: Bool
    let fileName: (ReviewComment) -> String
    let prompt: ([ReviewComment], String) -> String
    let lookFirst: () -> Void
    let send: ([ReviewComment], String) -> Void

    @Environment(DialogPresenter.self) private var dialogs
    @State private var picked: Set<UUID>
    @State private var note = ""
    @State private var showsPrompt = false
    // The checklist is as tall as what it lists, up to a cap, rather than always the cap.
    @State private var listHeight: CGFloat = 120

    init(agentTitle: String, comments: [ReviewComment], pendingCount: Int, busy: Bool,
         fileName: @escaping (ReviewComment) -> String,
         prompt: @escaping ([ReviewComment], String) -> String,
         lookFirst: @escaping () -> Void, send: @escaping ([ReviewComment], String) -> Void) {
        self.agentTitle = agentTitle
        self.comments = comments
        self.pendingCount = pendingCount
        self.busy = busy
        self.fileName = fileName
        self.prompt = prompt
        self.lookFirst = lookFirst
        self.send = send
        _picked = State(initialValue: Set(comments.map(\.id)))
    }

    private var chosen: [ReviewComment] { comments.filter { picked.contains($0.id) } }

    private var groups: [(file: String, comments: [ReviewComment])] {
        var result: [(file: String, comments: [ReviewComment])] = []
        for comment in comments {
            let key = ReviewRound.fileKey(root: comment.root, path: comment.path)
            if let index = result.firstIndex(where: { $0.file == key }) {
                result[index].comments.append(comment)
            } else {
                result.append((key, [comment]))
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pendingCount > 0 {
                callout(icon: "exclamationmark.triangle.fill", tint: Theme.attentionText, fill: Theme.attention.opacity(0.12),
                        bold: "\(counted(pendingCount, "finding")) still to look at.",
                        text: (pendingCount == 1 ? "It is" : "They are") + " not part of this review and will wait here.") {
                    InlineLink(title: "Look first", tint: Theme.attentionText) {
                        dialogs.dismiss()
                        lookFirst()
                    }
                }
            }
            if busy {
                callout(icon: "clock", tint: Theme.plan, fill: Theme.plan.opacity(0.1),
                        bold: "\(agentTitle) is in the middle of a turn.",
                        text: "Your review goes in as soon as it ends, so nothing it is doing now is interrupted.") {
                    EmptyView()
                }
            }
            HStack(spacing: 4) {
                ChoicePill(title: "Comments \(chosen.count)", selected: !showsPrompt) { showsPrompt = false }
                ChoicePill(title: "What \(agentTitle) reads", selected: showsPrompt) { showsPrompt = true }
                Spacer(minLength: 0)
                if !showsPrompt {
                    InlineLink(title: picked.count == comments.count ? "Untick all" : "Tick all", tint: Color.secondary) {
                        picked = picked.count == comments.count ? [] : Set(comments.map(\.id))
                    }
                }
            }
            ScrollView {
                if showsPrompt {
                    Text(chosen.isEmpty ? "Tick at least one comment to send." : prompt(chosen, note))
                        .font(.mono(11))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups, id: \.file) { group in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(fileName(group.comments[0])).font(.system(size: 12, weight: .semibold))
                                    Text(counted(group.comments.count, "comment"))
                                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                                ForEach(group.comments) { comment in row(comment) }
                            }
                        }
                    }
                    .padding(12)
                    .onGeometryChange(for: CGFloat.self, of: \.size.height) { listHeight = $0 }
                }
            }
            .frame(height: min(300, listHeight))
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            VStack(alignment: .leading, spacing: 6) {
                Text("Anything else for this round?").font(.system(size: 12, weight: .semibold))
                TextField("For example: run the tests when you are done", text: $note, axis: .vertical)
                    .lineLimit(1...4)
                    .appTextField()
            }
            HStack(spacing: 14) {
                Text("Sent comments leave the review. You can follow them up in Chat.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { dialogs.dismiss() } label: {
                    Text("Cancel").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                ActionButton(title: "\(busy ? "Queue" : "Send") \(counted(chosen.count, "comment"))",
                             tone: .green, height: 32, size: 12.5, icon: "paperplane.fill",
                             keyboardShortcut: .defaultAction) {
                    let list = chosen
                    let words = note
                    dialogs.dismiss()
                    send(list, words)
                }
                .disabled(chosen.isEmpty)
            }
            .padding(.top, 4)
        }
    }

    private func row(_ comment: ReviewComment) -> some View {
        Toggle(isOn: Binding(get: { picked.contains(comment.id) },
                             set: { on in if on { picked.insert(comment.id) } else { picked.remove(comment.id) } })) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    ReviewAvatars(comment: comment, size: 16)
                    Text(comment.authorName).font(.system(size: 11.5, weight: .semibold))
                    Text(comment.linesLabel).font(.mono(10.5)).foregroundStyle(.secondary)
                    if comment.kind == .question { QuestionTag() }
                    if let severity = comment.severity { SeverityChip(severity: severity) }
                }
                ReviewText(text: comment.body, size: 12, lineLimit: 3)
            }
            .padding(.top, -2)
        }
        .toggleStyle(.appCheckbox)
        .accessibilityLabel(comment.spokenName + ". " + comment.body)
    }

    private func callout<Action: View>(icon: String, tint: Color, fill: Color, bold: String, text: String,
                                       @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            (Text(bold).fontWeight(.semibold) + Text(" " + text))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            action()
        }
        .foregroundStyle(tint)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(fill))
    }
}

// MARK: - Toast

// A short word about what just happened, with the one thing worth doing next. It is read
// out as well, since it goes away on its own.
struct ReviewToast: Identifiable {
    let id = UUID()
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
}

struct ReviewToastView: View {
    let toast: ReviewToast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(toast.text).font(.system(size: 12.5)).foregroundStyle(.primary).lineLimit(2)
            if let title = toast.actionTitle, let action = toast.action {
                InlineLink(title: title) {
                    dismiss()
                    action()
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .floatingCard(cornerRadius: 10)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - In Chat

// A sent review as it sits in the conversation: one card listing what went, instead of
// the long prompt the agent read.
struct ReviewRoundCard: View {
    let round: ReviewRound
    let fileName: (ReviewComment) -> String
    let openInChanges: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ReviewAvatar(agent: nil, size: 22)
                Text("Your review").font(.serif(14, .semibold))
                let raised = round.comments.count { $0.reviewer != nil }
                Text(counted(round.comments.count, "comment") + (raised > 0 ? " · \(raised) raised by reviewers" : ""))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                InlineLink(title: "Open in Changes", size: 11.5, action: openInChanges)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(round.comments.enumerated()), id: \.element.id) { index, comment in
                    HStack(spacing: 8) {
                        Text("\(index + 1).").font(.mono(10.5)).foregroundStyle(.tertiary)
                        Text(ReviewFollowUpCard.place(comment, fileName: fileName))
                            .font(.mono(10.5)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        ReviewAvatars(comment: comment, size: 16)
                        if comment.kind == .question { QuestionTag() }
                        ReviewText(text: comment.body, size: 12, lineLimit: 1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !round.note.isBlank {
                (Text("Also: ").foregroundStyle(.secondary) + Text(round.note))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.userMessage))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.userMessageRing))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your review, \(counted(round.comments.count, "comment"))")
    }
}

// What came of a sent review, comment by comment, once the turn that took it ends.
struct ReviewFollowUpCard: View {
    let round: ReviewRound
    let agentTitle: String
    let working: Bool
    let checker: AgentKind?
    let fileName: (ReviewComment) -> String
    let showChange: (ReviewComment) -> Void
    let readAnswer: () -> Void
    let commentAgain: (ReviewComment) -> Void
    let reviewWhatChanged: () -> Void
    let checkFixes: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                if round.isSettled {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 18)).foregroundStyle(Theme.dotOn)
                } else {
                    ProgressView().controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(round.isSettled ? "\(agentTitle) worked through your review"
                         : "\(agentTitle) is working through your review")
                        .font(.serif(14, .semibold))
                    Text(round.isSettled ? "Each comment checked against the files when the turn ended"
                         : working ? "Each comment is checked once the turn ends" : "Waiting for the turn to end")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                tally
            }
            VStack(spacing: 0) {
                ForEach(round.comments) { comment in
                    row(comment)
                    if comment.id != round.comments.last?.id {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            HStack(spacing: 10) {
                ActionButton(title: "Review what changed", tone: .green, height: 30, size: 12,
                             icon: "plusminus", action: reviewWhatChanged)
                if let checker {
                    ActionButton(title: "Ask \(checker.title) to check the fixes", tone: .outlined, height: 30,
                                 size: 12, icon: "person.2", action: checkFixes)
                        .disabled(round.trees.isEmpty)
                }
                Spacer(minLength: 0)
                Text("The check reads only what changed since you sent the review")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!round.isSettled)
        }
        .padding(14)
        .cardSurface(cornerRadius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(round.isSettled ? "\(agentTitle) worked through your review"
                            : "\(agentTitle) is working through your review")
    }

    private var tally: some View {
        HStack(spacing: 6) {
            ForEach([ReviewRound.Outcome.changed, .answered, .unchanged], id: \.self) { outcome in
                let count = round.outcomes?.values.count { $0 == outcome } ?? 0
                if count > 0 { status(outcome, label: "\(count) " + short(outcome)) }
            }
            if !round.isSettled {
                Text("\(round.comments.count) waiting").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private func short(_ outcome: ReviewRound.Outcome) -> String {
        switch outcome {
        case .changed: "changed"
        case .answered: "answered"
        case .unchanged: "not changed"
        }
    }

    private func row(_ comment: ReviewComment) -> some View {
        let outcome = round.outcomes?[comment.id]
        return HStack(spacing: 10) {
            if let outcome {
                status(outcome, label: outcome.label).frame(width: 118, alignment: .leading)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 9, weight: .semibold))
                    Text("Waiting")
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 2) {
                ReviewText(text: comment.body, size: 12, lineLimit: 1)
                Text(Self.place(comment, fileName: fileName)).font(.mono(10.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            switch outcome {
            case .changed:
                InlineLink(title: "Show change", size: 11.5) { showChange(comment) }
            case .answered:
                InlineLink(title: "Read answer", size: 11.5, action: readAnswer)
            case .unchanged:
                InlineLink(title: "Read why", size: 11.5, tint: Color.secondary, action: readAnswer)
                if round.returned.contains(comment.id) {
                    Text("Back in your review").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    ActionButton(title: "Comment again", tone: .outlined, height: 24, size: 11) { commentAgain(comment) }
                }
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel((outcome?.label ?? "Waiting") + ". " + comment.body)
    }

    private func status(_ outcome: ReviewRound.Outcome, label: String) -> some View {
        let (icon, ink, fill): (String, Color, Color) = switch outcome {
        case .changed: ("checkmark", Theme.dotOnText, Theme.dotOn.opacity(0.14))
        case .answered: ("questionmark.bubble", Theme.plan, Theme.plan.opacity(0.12))
        case .unchanged: ("text.bubble", Theme.attentionText, Theme.attention.opacity(0.14))
        }
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(label).lineLimit(1).fixedSize()
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(ink)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(fill))
    }

    static func place(_ comment: ReviewComment, fileName: (ReviewComment) -> String) -> String {
        let lines = comment.onFile ? "" : ":" + (comment.lastLine.map { "\(comment.line)–\($0)" } ?? "\(comment.line)")
        return fileName(comment) + lines
    }
}
