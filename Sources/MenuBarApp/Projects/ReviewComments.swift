import Foundation
import Observation

// Which version of a file a review comment points into. Added and unchanged lines are
// numbered in the new file; a removed line only exists in the old one.
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

    var id = UUID()
    var root: String
    var path: String
    var side: ReviewSide
    var line: Int
    var lastLine: Int?
    var excerpt: String
    var body: String
    var author: Author = .you
    var created = Date()

    init(root: String, path: String, anchor: DiffAnchor, excerpt: String, body: String,
         author: Author = .you) {
        self.root = root
        self.path = path
        side = anchor.side
        line = anchor.line
        lastLine = anchor.lastLine
        self.excerpt = excerpt
        self.body = body
        self.author = author
    }

    var anchor: DiffAnchor { DiffAnchor(side: side, line: line, lastLine: lastLine) }

    var authorName: String {
        switch author {
        case .you: "You"
        case .agent(let agent): agent.title
        }
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

    static func place(_ comments: [ReviewComment], in lines: [DiffLine]) -> ReviewPlacement {
        guard !comments.isEmpty else { return ReviewPlacement() }
        let numbered = NumberedDiffLine.lines(lines)
        var placement = ReviewPlacement()
        for comment in comments.sorted(by: { $0.created < $1.created }) {
            if let found = locate(comment.anchor, excerpt: comment.excerpt, in: numbered) {
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
        func holds(_ start: Int) -> Bool {
            expected.enumerated().allSatisfy { offset, code in lines[start + offset]?.code.trimmed == code }
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
    static func feedback(_ comments: [ReviewComment], projectNames: [String: String] = [:]) -> String {
        let ordered = comments.sorted {
            ($0.root, $0.path, $0.side == .new ? 0 : 1, $0.line) < ($1.root, $1.path, $1.side == .new ? 0 : 1, $1.line)
        }
        // Named by the projects in the workspace rather than the ones the comments touch:
        // two projects can each have a src/App.swift, and the agent sees both.
        let spansProjects = projectNames.count > 1 || Set(comments.map(\.root)).count > 1
        var text = comments.count == 1
            ? "I reviewed your changes and left a comment. Please address it. "
                + "If you disagree, say why instead of changing the code."
            : "I reviewed your changes and left \(comments.count) comments. Please address each one. "
                + "If you disagree with a comment, say why instead of changing the code."
        for (index, comment) in ordered.enumerated() {
            var file = comment.path
            if spansProjects {
                let project = projectNames[comment.root] ?? (comment.root as NSString).lastPathComponent
                file = project + "/" + file
            }
            let lines = comment.lastLine.map { "lines \(comment.line)–\($0)" } ?? "line \(comment.line)"
            let place = comment.side == .old ? "removed \(lines) of the previous version" : lines
            var heading = "\(index + 1). \(file), \(place)"
            if case .agent(let agent) = comment.author { heading += " (raised in a \(agent.title) review)" }
            text += "\n\n" + heading
            // Several notes on the same lines quote them once, at the first.
            let previous = index > 0 ? ordered[index - 1] : nil
            let sameLines = previous.map {
                $0.root == comment.root && $0.path == comment.path && $0.anchor == comment.anchor
            } ?? false
            if sameLines {
                text += ", the same code as above"
            } else if !comment.excerpt.isBlank {
                text += "\n```\n" + comment.excerpt + "\n```"
            }
            text += "\n" + comment.body.trimmed
        }
        return text
    }
}

struct SecondOpinionRun: Equatable {
    var agent: AgentKind
    var started: Date
}

// Every session's unsent review. Comments are kept on disk until they are sent or
// cleared, so a review written before quitting is still there after.
@MainActor
@Observable
final class ReviewCommentStore {
    private var comments: [UUID: [ReviewComment]] = [:]
    // Second opinions under way. They outlive the Changes tab, which can be closed and
    // reopened while one runs.
    private(set) var runs: [UUID: SecondOpinionRun] = [:]
    // What the last second opinion came to, for the review strip to say once.
    var notes: [UUID: String] = [:]

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var saver: DebouncedSaver?

    init(url: URL? = AppPaths.supportFile("review-comments.json")) {
        self.url = url
        if let url, let stored = try? PersistentFile.loadJSON([UUID: [ReviewComment]].self, from: url) {
            comments = stored
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

    func add(_ comment: ReviewComment, to sessionID: UUID) {
        comments[sessionID, default: []].append(comment)
        notes[sessionID] = nil
        saver?.schedule()
    }

    func add(_ added: [ReviewComment], to sessionID: UUID) {
        guard !added.isEmpty else { return }
        comments[sessionID, default: []].append(contentsOf: added)
        saver?.schedule()
    }

    func update(_ id: UUID, body: String, in sessionID: UUID) {
        guard let index = comments[sessionID]?.firstIndex(where: { $0.id == id }) else { return }
        comments[sessionID]?[index].body = body
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
        if comments[sessionID]?.isEmpty == true {
            comments[sessionID] = nil
            notes[sessionID] = nil
        }
        saver?.schedule()
    }

    func clear(_ sessionID: UUID) {
        comments[sessionID] = nil
        notes[sessionID] = nil
        saver?.schedule()
    }

    // The session is gone, so is everything about its review.
    func remove(_ sessionID: UUID) {
        stopSecondOpinion(sessionID)
        clear(sessionID)
    }

    func flush() { saver?.flush() }

    // MARK: - Second opinion

    func isReviewing(_ sessionID: UUID) -> Bool { runs[sessionID] != nil }

    func startSecondOpinion(_ sessionID: UUID, agent: AgentKind, executable: String,
                            repositories: [(root: String, name: String)]) {
        guard runs[sessionID] == nil, let lead = repositories.first?.root else { return }
        runs[sessionID] = SecondOpinionRun(agent: agent, started: Date())
        notes[sessionID] = nil
        let searchPath = ProcessManager.searchPath
        tasks[sessionID] = Task { [weak self] in
            let patches = await SecondOpinion.patches(for: repositories)
            let outcome: Result<[ReviewComment], SecondOpinion.Failure>
            if patches.isEmpty {
                outcome = .failure(.init(message: "There are no changes to review."))
            } else {
                outcome = await SecondOpinion.review(patches, agent: agent, executable: executable,
                                                     searchPath: searchPath, directory: lead)
            }
            guard !Task.isCancelled, let self else { return }
            self.finishSecondOpinion(sessionID, agent: agent, outcome: outcome)
        }
    }

    func stopSecondOpinion(_ sessionID: UUID) {
        tasks[sessionID]?.cancel()
        tasks[sessionID] = nil
        runs[sessionID] = nil
    }

    private func finishSecondOpinion(_ sessionID: UUID, agent: AgentKind,
                                     outcome: Result<[ReviewComment], SecondOpinion.Failure>) {
        tasks[sessionID] = nil
        runs[sessionID] = nil
        switch outcome {
        case .success(let found):
            add(found, to: sessionID)
            notes[sessionID] = found.isEmpty
                ? "\(agent.title) found nothing worth raising."
                : "\(agent.title) left \(counted(found.count, "comment"))."
        case .failure(let failure):
            notes[sessionID] = "\(agent.title) could not finish the review. " + failure.message
        }
    }

    private func save() {
        guard let url else { return }
        do {
            if comments.isEmpty {
                try PersistentFile.removeIfPresent(url)
            } else {
                try PersistentFile.saveJSON(comments, to: url)
            }
        } catch {
            SessionLog.note("could not save review comments: \(error.localizedDescription)")
        }
    }
}
