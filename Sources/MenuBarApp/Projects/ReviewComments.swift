import Foundation
import Observation

// Which version of a file a review comment points into. Added lines use the new file,
// removed lines use the old one, and unchanged lines can belong to a range in either.
enum ReviewSide: String, Codable, Sendable, Hashable {
    case new, old
}

// The line, or run of lines, a comment hangs from. A run is anchored at its first line
// and drawn below its last, the way a review on a pull request reads.
struct DiffAnchor: Hashable, Sendable {
    var side: ReviewSide
    var line: Int
    var lastLine: Int?

    init(side: ReviewSide, line: Int, lastLine: Int? = nil) {
        self.side = side
        self.line = line
        self.lastLine = lastLine.flatMap { $0 == line ? nil : $0 }
    }

    // Shift-clicking a second line stretches the run to it, whichever way it lies. A line
    // on the other side of the diff starts over, since a run cannot cross versions.
    func extended(to other: DiffAnchor) -> DiffAnchor {
        guard other.side == side else { return other }
        let all = [line, lastLine ?? line, other.line]
        return DiffAnchor(side: side, line: all.min()!, lastLine: all.max()!)
    }

    var label: String {
        let lines = lastLine.map { "Lines \(line)–\($0)" } ?? "Line \(line)"
        return side == .old ? lines + " (removed)" : lines
    }
}

// A note left on a line of a session's changes, waiting to be sent back to the agent.
// It names the line by number and keeps the text that was there, so a diff that moves
// under it can still find where it belongs.
struct ReviewComment: Identifiable, Codable, Equatable, Sendable {
    enum Author: Codable, Equatable, Sendable {
        case you
        // A second opinion: another agent read the changes and raised this.
        case agent(AgentKind)
    }

    // A reviewer's finding waits as pending until the person keeps it. Only kept
    // comments are ever sent, so nothing a reviewer says reaches the agent unread.
    enum Status: String, Codable, Sendable {
        case pending, kept
    }

    // A question asks for an answer, not a change, and the prompt says so.
    enum Kind: String, Codable, Sendable {
        case change, question
    }

    // How much a reviewer thinks a finding matters, in its own words.
    enum Severity: String, Codable, Sendable, CaseIterable {
        case must, should, look

        var label: String {
            switch self {
            case .must: "Must fix"
            case .should: "Should fix"
            case .look: "Worth a look"
            }
        }
    }

    // Another reviewer that raised the same lines, in its own words.
    struct Voice: Codable, Equatable, Sendable {
        var agent: AgentKind
        var body: String
    }

    var id = UUID()
    var root: String
    var path: String
    var side: ReviewSide
    var line: Int
    var lastLine: Int?
    var excerpt: String
    // A collapsed gap leaves holes in the quote. Offsets keep each quoted line at its
    // position in the range. Without offsets, the quoted lines are consecutive.
    var excerptOffsets: [Int]?
    var body: String
    var author: Author = .you
    var created = Date()
    var status: Status = .kept
    var kind: Kind = .change
    var severity: Severity?
    var also: [Voice] = []
    // Kept after the person rewrote it, so the card says the words are partly theirs.
    var edited = false
    // Its code left the diff and the person chose to keep it on the file as a whole.
    var onFile = false

    init(root: String, path: String, anchor: DiffAnchor, excerpt: String, body: String,
         author: Author = .you, excerptOffsets: [Int]? = nil, kind: Kind = .change,
         status: Status = .kept, severity: Severity? = nil) {
        self.root = root
        self.path = path
        side = anchor.side
        line = anchor.line
        lastLine = anchor.lastLine
        self.excerpt = excerpt
        self.excerptOffsets = excerptOffsets
        self.body = body
        self.author = author
        self.kind = kind
        self.status = status
        self.severity = severity
    }

    // Reviews saved before findings could wait, or comments could be questions, still
    // load: anything they lack takes the value every comment had then.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        root = try values.decode(String.self, forKey: .root)
        path = try values.decode(String.self, forKey: .path)
        side = try values.decode(ReviewSide.self, forKey: .side)
        line = try values.decode(Int.self, forKey: .line)
        lastLine = try values.decodeIfPresent(Int.self, forKey: .lastLine)
        excerpt = try values.decode(String.self, forKey: .excerpt)
        excerptOffsets = try values.decodeIfPresent([Int].self, forKey: .excerptOffsets)
        body = try values.decode(String.self, forKey: .body)
        author = try values.decodeIfPresent(Author.self, forKey: .author) ?? .you
        created = try values.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        status = try values.decodeIfPresent(Status.self, forKey: .status) ?? .kept
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .change
        severity = try values.decodeIfPresent(Severity.self, forKey: .severity)
        also = try values.decodeIfPresent([Voice].self, forKey: .also) ?? []
        edited = try values.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        onFile = try values.decodeIfPresent(Bool.self, forKey: .onFile) ?? false
    }

    var anchor: DiffAnchor { DiffAnchor(side: side, line: line, lastLine: lastLine) }

    var isPending: Bool { status == .pending }

    var reviewer: AgentKind? {
        if case .agent(let agent) = author { return agent }
        return nil
    }

    // Every reviewer that raised these lines, the first one first.
    var reviewers: [AgentKind] { (reviewer.map { [$0] } ?? []) + also.map(\.agent) }

    var authorName: String {
        switch author {
        case .you: "You"
        case .agent: reviewers.map(\.title).joined(separator: " and ")
        }
    }

    var linesLabel: String { onFile ? "Whole file" : anchor.label }

    // What a screen reader hears for the card: what it is, who left it, and where.
    var spokenName: String {
        let what = isPending ? "Finding" : kind == .question ? "Question" : "Comment"
        return "\(what) from \(authorName) on \(linesLabel.lowercased())"
    }
}

// One changed or unchanged line of a diff with the number it carries in the version it
// belongs to. The gutter, the comment rows and the placement below all read from this,
// so a number on screen and a number in a comment always agree.
struct NumberedDiffLine: Equatable {
    var id: Int
    var side: ReviewSide
    var number: Int
    // The code without the diff's sign column.
    var code: String

    static func lines(_ lines: [DiffLine]) -> [NumberedDiffLine] {
        var numbered: [NumberedDiffLine] = []
        for row in DiffComparisonRow.align(lines) {
            if let left = row.left, left == row.right {
                if left.kind == .context, let number = row.oldNumber {
                    numbered.append(.init(id: left.id, side: .old, number: number, code: code(left)))
                }
                if left.kind == .context, let number = row.newNumber {
                    numbered.append(.init(id: left.id, side: .new, number: number, code: code(left)))
                }
                continue
            }
            if let left = row.left, left.kind == .deletion, let number = row.oldNumber {
                numbered.append(.init(id: left.id, side: .old, number: number, code: code(left)))
            }
            if let right = row.right, right.kind == .addition, let number = row.newNumber {
                numbered.append(.init(id: right.id, side: .new, number: number, code: code(right)))
            }
        }
        return numbered
    }

    static func excerpt(_ anchor: DiffAnchor, in diff: [DiffLine]) -> (text: String, offsets: [Int]) {
        let range = anchor.line...(anchor.lastLine ?? anchor.line)
        let selected = lines(diff).filter { $0.side == anchor.side && range.contains($0.number) }
        return (selected.map(\.code).joined(separator: "\n"), selected.map { $0.number - anchor.line })
    }

    private static func code(_ line: DiffLine) -> String { String(line.text.dropFirst()) }

    var anchor: DiffAnchor { DiffAnchor(side: side, line: number) }
}

// Where each of a file's comments sits in the diff open now. The agent may have moved
// the code since a comment was left, so a comment whose line no longer holds the text it
// was left on looks for that text nearby, and one that cannot find it at all is listed
// above the diff instead of being pinned to the wrong line.
struct ReviewPlacement: Equatable {
    // Keyed by the id of the diff line each group of comments is drawn below.
    var below: [Int: [ReviewComment]] = [:]
    var unplaced: [ReviewComment] = []

    // Kept on the file as a whole, by choice, after their code left the diff.
    var onFile: [ReviewComment] = []

    static func place(_ comments: [ReviewComment], in lines: [DiffLine]) -> ReviewPlacement {
        guard !comments.isEmpty else { return ReviewPlacement() }
        let numbered = NumberedDiffLine.lines(lines)
        var placement = ReviewPlacement()
        for comment in comments.sorted(by: { $0.created < $1.created }) {
            if comment.onFile {
                placement.onFile.append(comment)
            } else if let found = locate(comment.anchor, excerpt: comment.excerpt,
                                  excerptOffsets: comment.excerptOffsets, in: numbered) {
                placement.below[found.lastID, default: []].append(comment)
            } else {
                placement.unplaced.append(comment)
            }
        }
        return placement
    }

    // Where the lines that held `excerpt` are now, and the id of the last of them. The
    // lines a comment was left on win while every one of them still holds its code;
    // otherwise the nearest run that does. Code as plain as a lone brace turns up in many
    // places, so if it has moved and could be any of several, it is nowhere rather than
    // somewhere wrong. A comment that quotes nothing can only stay on its own number.
    static func locate(_ anchor: DiffAnchor, excerpt: String,
                       excerptOffsets: [Int]? = nil,
                       in numbered: [NumberedDiffLine]) -> (anchor: DiffAnchor, lastID: Int)? {
        var lines: [Int: NumberedDiffLine] = [:]
        for line in numbered where line.side == anchor.side { lines[line.number] = line }
        let span = (anchor.lastLine ?? anchor.line) - anchor.line
        func last(from start: Int, count: Int) -> NumberedDiffLine? {
            lines[start + span] ?? lines[start + count - 1]
        }
        guard !excerpt.isBlank else {
            return lines[anchor.line + span].map { (anchor, $0.id) }
        }
        let expected = excerpt.components(separatedBy: "\n").map(\.trimmed)
        let offsets = excerptOffsets ?? Array(expected.indices)
        guard offsets.count == expected.count else { return nil }
        func holds(_ start: Int) -> Bool {
            zip(offsets, expected).allSatisfy { offset, code in lines[start + offset]?.code.trimmed == code }
        }
        if holds(anchor.line), let end = last(from: anchor.line, count: expected.count) {
            return (anchor, end.id)
        }
        let starts = lines.keys.filter(holds).sorted { abs($0 - anchor.line) < abs($1 - anchor.line) }
        guard let best = starts.first else { return nil }
        let distinctive = expected.joined().filter { $0.isLetter || $0.isNumber }.count >= 4
        guard starts.count == 1 || distinctive,
              let end = last(from: best, count: expected.count) else { return nil }
        let moved = DiffAnchor(side: anchor.side, line: best, lastLine: anchor.lastLine.map { _ in best + span })
        return (moved, end.id)
    }
}

// The prompt a set of comments becomes. Each one names its file and lines and quotes
// the code, so the agent can act on it without having seen the diff the comments were
// written on.
enum ReviewPrompt {
    static func feedback(_ comments: [ReviewComment], projectNames: [String: String] = [:],
                         note: String = "") -> String {
        let ordered = ReviewOrder.sorted(comments)
        // Named by the projects in the workspace rather than the ones the comments touch:
        // two projects can each have a src/App.swift, and the agent sees both.
        let spansProjects = projectNames.count > 1 || Set(comments.map(\.root)).count > 1
        var text = comments.count == 1
            ? "I reviewed your changes and left a comment. Please address it. "
                + "If you disagree, say why instead of changing the code."
            : "I reviewed your changes and left \(comments.count) comments. Please address each one. "
                + "If you disagree with a comment, say why instead of changing the code."
        if comments.contains(where: { $0.kind == .question }) {
            text += " A comment marked as a question only needs an answer, not a code change."
        }
        for (index, comment) in ordered.enumerated() {
            var file = comment.path
            if spansProjects {
                let project = projectNames[comment.root] ?? (comment.root as NSString).lastPathComponent
                file = project + "/" + file
            }
            let lines = comment.lastLine.map { "lines \(comment.line)–\($0)" } ?? "line \(comment.line)"
            let place = comment.onFile ? "the whole file"
                : comment.side == .old ? "removed \(lines) of the previous version" : lines
            var heading = "\(index + 1). \(file), \(place)"
            if comment.kind == .question { heading += " (a question)" }
            if comment.reviewer != nil { heading += " (raised in a \(comment.authorName) review)" }
            text += "\n\n" + heading
            // Several notes on the same lines quote them once, at the first.
            let previous = index > 0 ? ordered[index - 1] : nil
            let sameLines = previous.map {
                $0.root == comment.root && $0.path == comment.path && $0.anchor == comment.anchor
                    && $0.onFile == comment.onFile
            } ?? false
            if sameLines {
                text += ", the same code as above"
            } else if !comment.excerpt.isBlank {
                text += "\n```\n" + comment.excerpt + "\n```"
            }
            text += "\n" + comment.body.trimmed
        }
        if !note.isBlank { text += "\n\nOne more thing: " + note.trimmed }
        return text
    }
}

// The one order comments are read in everywhere: the review list, stepping from one to
// the next, the send checklist and the prompt. File by file, new lines before removed
// ones, top to bottom.
enum ReviewOrder {
    static func sorted(_ comments: [ReviewComment], roots: [String] = []) -> [ReviewComment] {
        func rank(_ root: String) -> Int { roots.firstIndex(of: root) ?? roots.count }
        return comments.sorted { a, b in
            if a.root != b.root { return (rank(a.root), a.root) < (rank(b.root), b.root) }
            if a.path != b.path { return a.path < b.path }
            let place = { (comment: ReviewComment) in
                (comment.onFile ? 0 : 1, comment.side == .new ? 0 : 1, comment.line)
            }
            if place(a) != place(b) { return place(a) < place(b) }
            return a.created < b.created
        }
    }

    // The comment after or before `current`, going round at either end. With nothing
    // focused yet, the first step lands on the first or the last.
    static func step(from current: UUID?, by step: Int, in ordered: [ReviewComment]) -> ReviewComment? {
        guard !ordered.isEmpty else { return nil }
        guard let current, let index = ordered.firstIndex(where: { $0.id == current }) else {
            return step > 0 ? ordered.first : ordered.last
        }
        return ordered[(index + step + ordered.count) % ordered.count]
    }
}

// A project a reviewer reads, by its folder and the name the workspace gives it.
struct ReviewRepository: Equatable, Sendable {
    var root: String
    var name: String
}

// What a second opinion was asked to do, kept with its run so Try again asks the same.
struct SecondOpinionRequest: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        case all
        case file(root: String, path: String)
        // Only what changed after the last review was sent, compared against the tree
        // recorded in each project at that moment.
        case sinceReview(trees: [String: String])

        var isSinceReview: Bool {
            if case .sinceReview = self { return true }
            return false
        }
    }

    var focus: [SecondOpinion.Focus] = SecondOpinion.Focus.standard
    var scope: Scope = .all
    var repositories: [ReviewRepository]
    var executable: String
}

// One reviewer's lane in the review bar: what it is reading, how long it has taken,
// and what it came to.
struct SecondOpinionRun: Equatable, Identifiable {
    enum State: Equatable {
        case running
        case finished(found: Int)
        case failed(String)
    }

    var agent: AgentKind
    var started: Date
    var ended: Date?
    var state: State = .running
    var activity = "Gathering the changes"
    var request: SecondOpinionRequest

    var id: AgentKind { agent }
    var isRunning: Bool { state == .running }
}

// A sent review, kept so Chat can show it as one card and say afterwards what came of
// each comment.
struct ReviewRound: Identifiable, Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case changed, answered, unchanged

        var label: String {
            switch self {
            case .changed: "Lines changed"
            case .answered: "Answered"
            case .unchanged: "Not changed"
            }
        }
    }

    var id = UUID()
    var sent = Date()
    // The exact words the agent was given, which is how the message in the conversation
    // is recognised as this review.
    var prompt: String
    var note: String
    var comments: [ReviewComment]
    // What each commented file held when the review went, by "root/path". A comment with
    // no lines of its own to look for is judged by whether its file moved at all.
    var fileDigests: [String: String] = [:]
    // The tree each project held when the review went, so a later reviewer can read only
    // what changed after it.
    var trees: [String: String] = [:]
    // Filled in once the turn that took the review ends.
    var outcomes: [UUID: Outcome]?
    // Comments put back in the review with Comment again.
    var returned: [UUID] = []

    var isSettled: Bool { outcomes != nil }

    // What came of one comment, judged from the file as it is now. A question was asked
    // to be answered, so it was. Otherwise the comment's code still on its own lines means
    // nothing touched it; code that moved or is gone means the lines were changed.
    static func outcome(for comment: ReviewComment, fileText: String?, digestAtSend: String?) -> Outcome {
        if comment.kind == .question { return .answered }
        guard let fileText else { return .changed }
        if comment.onFile || comment.side == .old || comment.excerpt.isBlank {
            return digest(fileText) == digestAtSend ? .unchanged : .changed
        }
        let numbered = fileText.components(separatedBy: "\n").enumerated().map {
            NumberedDiffLine(id: $0.offset, side: .new, number: $0.offset + 1, code: $0.element)
        }
        let found = ReviewPlacement.locate(comment.anchor, excerpt: comment.excerpt,
                                           excerptOffsets: comment.excerptOffsets, in: numbered)
        return found?.anchor == comment.anchor ? .unchanged : .changed
    }

    static func digest(_ text: String) -> String { String(StableHash.fnv1a(text), radix: 16) }

    static func fileKey(root: String, path: String) -> String { root + "/" + path }
}

// Every session's review: the comments not yet sent, the reviewers at work, and the
// rounds already sent. Comments and rounds are kept on disk, so a review written before
// quitting is still there after.
@MainActor
@Observable
final class ReviewCommentStore {
    private var comments: [UUID: [ReviewComment]] = [:]
    // Second opinions, one lane per reviewer. They outlive the Changes tab, which can be
    // closed and reopened while one runs.
    private(set) var runs: [UUID: [SecondOpinionRun]] = [:]
    private var rounds: [UUID: [ReviewRound]] = [:]

    @ObservationIgnored private var tasks: [UUID: [AgentKind: Task<Void, Never>]] = [:]
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let roundsURL: URL?
    @ObservationIgnored private var saver: DebouncedSaver?
    // Reading files and asking git for trees is done off the main thread; tests swap in
    // their own so a round settles without touching the disk.
    @ObservationIgnored var readFile: @Sendable (String) -> String? = { path in
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    init(url: URL? = AppPaths.supportFile("review-comments.json")) {
        self.url = url
        roundsURL = url.map {
            $0.deletingPathExtension().appendingPathExtension("rounds").appendingPathExtension("json")
        }
        if let url, let stored = try? PersistentFile.loadJSON([UUID: [ReviewComment]].self, from: url) {
            comments = stored
        }
        if let roundsURL, let stored = try? PersistentFile.loadJSON([UUID: [ReviewRound]].self, from: roundsURL) {
            rounds = stored
        }
        saver = DebouncedSaver { [weak self] in self?.save() }
    }

    func comments(_ sessionID: UUID) -> [ReviewComment] { comments[sessionID] ?? [] }

    func comments(_ sessionID: UUID, root: String, path: String) -> [ReviewComment] {
        comments(sessionID).filter { $0.root == root && $0.path == path }
    }

    func count(_ sessionID: UUID, root: String, path: String) -> Int {
        comments(sessionID, root: root, path: path).count
    }

    func kept(_ sessionID: UUID) -> [ReviewComment] { comments(sessionID).filter { !$0.isPending } }

    func pending(_ sessionID: UUID) -> [ReviewComment] { comments(sessionID).filter(\.isPending) }

    func comment(_ id: UUID, in sessionID: UUID) -> ReviewComment? {
        comments[sessionID]?.first { $0.id == id }
    }

    func add(_ comment: ReviewComment, to sessionID: UUID) {
        comments[sessionID, default: []].append(comment)
        saver?.schedule()
    }

    func add(_ added: [ReviewComment], to sessionID: UUID) {
        guard !added.isEmpty else { return }
        comments[sessionID, default: []].append(contentsOf: added)
        saver?.schedule()
    }

    // Saving a finding the person rewrote keeps it: the words are now partly theirs.
    func update(_ id: UUID, body: String, kind: ReviewComment.Kind? = nil, in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        comments[sessionID]?[index].body = body
        if let kind { comments[sessionID]?[index].kind = kind }
        if comments[sessionID]?[index].isPending == true {
            comments[sessionID]?[index].status = .kept
            comments[sessionID]?[index].edited = true
        }
        saver?.schedule()
    }

    // Moves a comment whose code left the diff onto lines picked by hand, or keeps it on
    // the file as a whole.
    func move(_ id: UUID, to anchor: DiffAnchor, excerpt: String, offsets: [Int], in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        comments[sessionID]?[index].side = anchor.side
        comments[sessionID]?[index].line = anchor.line
        comments[sessionID]?[index].lastLine = anchor.lastLine
        comments[sessionID]?[index].excerpt = excerpt
        comments[sessionID]?[index].excerptOffsets = offsets
        comments[sessionID]?[index].onFile = false
        saver?.schedule()
    }

    func keepOnFile(_ id: UUID, in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        comments[sessionID]?[index].onFile = true
        saver?.schedule()
    }

    func remove(_ id: UUID, from sessionID: UUID) {
        comments[sessionID]?.removeAll { $0.id == id }
        if comments[sessionID]?.isEmpty == true { comments[sessionID] = nil }
        saver?.schedule()
    }

    // Takes away the comments that were just sent, and only those: one that arrived while
    // the preview was open was never part of the prompt, so it stays for the next one.
    func remove(_ ids: Set<UUID>, from sessionID: UUID) {
        comments[sessionID]?.removeAll { ids.contains($0.id) }
        if comments[sessionID]?.isEmpty == true { comments[sessionID] = nil }
        saver?.schedule()
    }

    func clear(_ sessionID: UUID) {
        comments[sessionID] = nil
        saver?.schedule()
    }

    // The session is gone, so is everything about its review.
    func remove(_ sessionID: UUID) {
        stopSecondOpinion(sessionID)
        runs[sessionID] = nil
        clear(sessionID)
        rounds[sessionID] = nil
        saver?.schedule()
    }

    func flush() { saver?.flush() }

    // MARK: - Sorting findings

    func keep(_ id: UUID, in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        comments[sessionID]?[index].status = .kept
        saver?.schedule()
    }

    func keepAll(_ sessionID: UUID) {
        guard let all = comments[sessionID] else { return }
        comments[sessionID] = all.map { var comment = $0; comment.status = .kept; return comment }
        saver?.schedule()
    }

    // Hands the finding back with where it was, so Undo can put it back in its place.
    @discardableResult
    func dismiss(_ id: UUID, from sessionID: UUID) -> (comment: ReviewComment, index: Int)? {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }),
              let comment = comments[sessionID]?.remove(at: index) else { return nil }
        if comments[sessionID]?.isEmpty == true { comments[sessionID] = nil }
        saver?.schedule()
        return (comment, index)
    }

    @discardableResult
    func dismissAllPending(_ sessionID: UUID) -> [ReviewComment] {
        let gone = pending(sessionID)
        comments[sessionID]?.removeAll(where: \.isPending)
        if comments[sessionID]?.isEmpty == true { comments[sessionID] = nil }
        saver?.schedule()
        return gone
    }

    func restore(_ comment: ReviewComment, at index: Int? = nil, to sessionID: UUID) {
        guard self.comment(comment.id, in: sessionID) == nil else { return }
        var list = comments[sessionID] ?? []
        list.insert(comment, at: min(index ?? list.count, list.count))
        comments[sessionID] = list
        saver?.schedule()
    }

    // A finding on lines another reviewer already raised joins that one as a second
    // voice, so the same problem is read, kept and sent once.
    @discardableResult
    func addFindings(_ found: [ReviewComment], from agent: AgentKind, to sessionID: UUID) -> Int {
        var added = 0
        for var finding in found {
            let twin = comments[sessionID]?.firstIndex { other in
                guard let reviewer = other.reviewer, reviewer != agent,
                      !other.reviewers.contains(agent) else { return false }
                return other.root == finding.root && other.path == finding.path
                    && other.anchor == finding.anchor
            }
            if let twin {
                comments[sessionID]?[twin].also.append(.init(agent: agent, body: finding.body))
                if let severity = finding.severity, let existing = comments[sessionID]?[twin].severity,
                   Self.rank(severity) < Self.rank(existing) {
                    comments[sessionID]?[twin].severity = severity
                }
            } else {
                finding.status = .pending
                comments[sessionID, default: []].append(finding)
                added += 1
            }
        }
        if !found.isEmpty { saver?.schedule() }
        return added
    }

    private static func rank(_ severity: ReviewComment.Severity) -> Int {
        ReviewComment.Severity.allCases.firstIndex(of: severity) ?? 0
    }

    // MARK: - Second opinion

    func runs(_ sessionID: UUID) -> [SecondOpinionRun] { runs[sessionID] ?? [] }

    func isReviewing(_ sessionID: UUID) -> Bool { runs(sessionID).contains(where: \.isRunning) }

    func isReviewing(_ sessionID: UUID, agent: AgentKind) -> Bool {
        runs(sessionID).contains { $0.agent == agent && $0.isRunning }
    }

    // Each reviewer gets a lane of its own and runs alongside the others. One already at
    // work is left to it.
    func startSecondOpinion(_ sessionID: UUID, agent: AgentKind, request: SecondOpinionRequest) {
        guard !isReviewing(sessionID, agent: agent), !request.repositories.isEmpty else { return }
        let run = SecondOpinionRun(agent: agent, started: Date(), request: request)
        var lanes = runs(sessionID).filter { $0.agent != agent }
        lanes.append(run)
        runs[sessionID] = lanes
        let searchPath = ProcessManager.searchPath
        tasks[sessionID, default: [:]][agent] = Task { [weak self] in
            var patches = await SecondOpinion.patches(for: request)
            if case .file(let root, let path) = request.scope {
                patches = patches.filter { $0.root == root && $0.path == path }
            }
            guard !Task.isCancelled else { return }
            self?.setActivity("Reading \(counted(patches.count, "changed file"))", agent: agent, in: sessionID)
            let outcome: Result<[ReviewComment], SecondOpinion.Failure>
            if patches.isEmpty {
                outcome = .failure(.init(message: request.scope.isSinceReview
                    ? "Nothing changed since the last review." : "There are no changes to review."))
            } else {
                outcome = await SecondOpinion.review(
                    patches, agent: agent, executable: request.executable, searchPath: searchPath,
                    repositories: request.repositories.map { (root: $0.root, name: $0.name) },
                    focus: request.focus, sinceReview: request.scope.isSinceReview,
                    activity: { [weak self] text in
                        Task { @MainActor in self?.setActivity(text, agent: agent, in: sessionID) }
                    })
            }
            guard !Task.isCancelled, let self else { return }
            self.finishSecondOpinion(sessionID, agent: agent, outcome: outcome)
        }
    }

    func retrySecondOpinion(_ sessionID: UUID, agent: AgentKind) {
        guard let run = runs(sessionID).first(where: { $0.agent == agent }), !run.isRunning else { return }
        startSecondOpinion(sessionID, agent: agent, request: run.request)
    }

    // Stopping a reviewer drops its lane: there is nothing it came to.
    func stopSecondOpinion(_ sessionID: UUID, agent: AgentKind) {
        tasks[sessionID]?[agent]?.cancel()
        tasks[sessionID]?[agent] = nil
        runs[sessionID]?.removeAll { $0.agent == agent }
        if runs[sessionID]?.isEmpty == true { runs[sessionID] = nil }
    }

    func stopSecondOpinion(_ sessionID: UUID) {
        for task in (tasks[sessionID] ?? [:]).values { task.cancel() }
        tasks[sessionID] = nil
        runs[sessionID]?.removeAll(where: \.isRunning)
        if runs[sessionID]?.isEmpty == true { runs[sessionID] = nil }
    }

    // A finished lane stays until the person puts it away.
    func dismissLane(_ sessionID: UUID, agent: AgentKind) {
        guard runs(sessionID).first(where: { $0.agent == agent })?.isRunning == false else { return }
        runs[sessionID]?.removeAll { $0.agent == agent }
        if runs[sessionID]?.isEmpty == true { runs[sessionID] = nil }
    }

    private func setActivity(_ text: String, agent: AgentKind, in sessionID: UUID) {
        guard let index = runs[sessionID]?.firstIndex(where: { $0.agent == agent && $0.isRunning }) else { return }
        runs[sessionID]?[index].activity = text
    }

    // Called by the run when it ends; tests call it directly with what a reviewer said.
    func finishSecondOpinion(_ sessionID: UUID, agent: AgentKind,
                             outcome: Result<[ReviewComment], SecondOpinion.Failure>) {
        tasks[sessionID]?[agent] = nil
        if case .success(let found) = outcome { addFindings(found, from: agent, to: sessionID) }
        guard let index = runs[sessionID]?.firstIndex(where: { $0.agent == agent }) else { return }
        runs[sessionID]?[index].ended = Date()
        switch outcome {
        case .success(let found): runs[sessionID]?[index].state = .finished(found: found.count)
        case .failure(let failure): runs[sessionID]?[index].state = .failed(failure.message)
        }
    }

    // MARK: - Rounds

    func rounds(_ sessionID: UUID) -> [ReviewRound] { rounds[sessionID] ?? [] }

    func round(prompt: String, in sessionID: UUID) -> ReviewRound? {
        let text = prompt.trimmed
        return rounds(sessionID).last { $0.prompt == text }
    }

    // The trees the latest round recorded, for a reviewer asked to read only what
    // changed after it. Nil until a review has gone and its trees are in.
    func latestTrees(_ sessionID: UUID) -> [String: String]? {
        guard let trees = rounds(sessionID).last?.trees, !trees.isEmpty else { return nil }
        return trees
    }

    // Records a review as it is sent and takes its comments out of the one being written.
    // What each file and project held is read in the background and filled in after.
    @discardableResult
    func recordRound(_ sent: [ReviewComment], prompt: String, note: String,
                     roots: [String], in sessionID: UUID) -> ReviewRound {
        let round = ReviewRound(prompt: prompt.trimmed, note: note.trimmed, comments: ReviewOrder.sorted(sent, roots: roots))
        rounds[sessionID, default: []].append(round)
        remove(Set(sent.map(\.id)), from: sessionID)
        saver?.schedule()
        let read = readFile
        let files = Set(sent.map { ReviewRound.fileKey(root: $0.root, path: $0.path) })
        Task { [weak self] in
            let digests = await Task.detached(priority: .utility) {
                var digests: [String: String] = [:]
                for file in files { digests[file] = read(file).map(ReviewRound.digest) }
                return digests
            }.value
            var trees: [String: String] = [:]
            for root in roots {
                if let tree = await TreeSnapshots.shared.record(at: root) { trees[root] = tree }
            }
            self?.fillRound(round.id, digests: digests, trees: trees, in: sessionID)
        }
        return round
    }

    private func fillRound(_ id: UUID, digests: [String: String], trees: [String: String], in sessionID: UUID) {
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        rounds[sessionID]?[index].fileDigests.merge(digests) { old, _ in old }
        rounds[sessionID]?[index].trees.merge(trees) { old, _ in old }
        saver?.schedule()
    }

    // The turn that took a review has ended: each of its comments is checked against the
    // files as they are now. A turn that ran something else first leaves it waiting.
    func turnEnded(_ sessionID: UUID, prompt: String) async {
        guard let round = round(prompt: prompt, in: sessionID), !round.isSettled else { return }
        let read = readFile
        let comments = round.comments
        let digests = round.fileDigests
        let outcomes = await Task.detached(priority: .utility) {
            var outcomes: [UUID: ReviewRound.Outcome] = [:]
            for comment in comments {
                let key = ReviewRound.fileKey(root: comment.root, path: comment.path)
                outcomes[comment.id] = ReviewRound.outcome(for: comment, fileText: read(key),
                                                           digestAtSend: digests[key])
            }
            return outcomes
        }.value
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.id == round.id }) else { return }
        rounds[sessionID]?[index].outcomes = outcomes
        saver?.schedule()
    }

    // Comment again: the comment goes back in the review, kept, to be sent next round.
    func commentAgain(_ commentID: UUID, round roundID: UUID, in sessionID: UUID) {
        guard let index = rounds[sessionID]?.firstIndex(where: { $0.id == roundID }),
              let sent = rounds[sessionID]?[index].comments.first(where: { $0.id == commentID }),
              rounds[sessionID]?[index].returned.contains(commentID) == false else { return }
        var again = sent
        again.id = UUID()
        again.status = .kept
        again.created = Date()
        add(again, to: sessionID)
        rounds[sessionID]?[index].returned.append(commentID)
        saver?.schedule()
    }

    private func save() {
        do {
            if let url {
                if comments.isEmpty { try PersistentFile.removeIfPresent(url) }
                else { try PersistentFile.saveJSON(comments, to: url) }
            }
            if let roundsURL {
                if rounds.isEmpty { try PersistentFile.removeIfPresent(roundsURL) }
                else { try PersistentFile.saveJSON(rounds, to: roundsURL) }
            }
        } catch {
            SessionLog.note("could not save review comments: \(error.localizedDescription)")
        }
    }
}
