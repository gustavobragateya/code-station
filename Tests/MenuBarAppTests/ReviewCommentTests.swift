import AppKit
import Foundation
import Testing
@testable import MenuBarApp

// Comments left on a session's diff hang from numbered lines, follow the code when the
// agent moves it, and go back to the agent as one prompt that quotes what they are about.
@MainActor
struct ReviewCommentTests {

    private var lines: [DiffLine] {
        [DiffLine(id: 0, kind: .hunk, text: "@@ -10,4 +10,5 @@"),
         DiffLine(id: 1, kind: .context, text: " let items = load()"),
         DiffLine(id: 2, kind: .deletion, text: "-let first = items[0]"),
         DiffLine(id: 3, kind: .addition, text: "+let first = items.first!"),
         DiffLine(id: 4, kind: .addition, text: "+print(first)"),
         DiffLine(id: 5, kind: .context, text: " return first")]
    }

    private func comment(_ side: ReviewSide, _ line: Int, excerpt: String, body: String = "Fix this",
                         lastLine: Int? = nil) -> ReviewComment {
        ReviewComment(root: "/repo", path: "App.swift",
                      anchor: DiffAnchor(side: side, line: line, lastLine: lastLine),
                      excerpt: excerpt, body: body)
    }

    @Test func linesAreNumberedInTheVersionTheyBelongTo() {
        let numbered = NumberedDiffLine.lines(lines)
        #expect(numbered.map(\.side) == [.old, .new, .old, .new, .new, .old, .new])
        #expect(numbered.map(\.number) == [10, 10, 11, 11, 12, 12, 13])
        #expect(numbered[2].code == "let first = items[0]")
    }

    @Test func aCommentSitsUnderTheLineItWasLeftOn() {
        let placement = ReviewPlacement.place([comment(.new, 11, excerpt: "let first = items.first!")], in: lines)
        #expect(placement.below[3]?.count == 1)
        #expect(placement.unplaced.isEmpty)
    }

    @Test func aRemovedLineIsFoundOnTheOldSide() {
        let placement = ReviewPlacement.place([comment(.old, 11, excerpt: "let first = items[0]")], in: lines)
        #expect(placement.below[2]?.count == 1)
    }

    @Test func aCommentFollowsItsCodeWhenTheLinesMove() {
        // Left on line 11 before two lines were added above it.
        let placement = ReviewPlacement.place([comment(.new, 9, excerpt: "print(first)")], in: lines)
        #expect(placement.below[4]?.count == 1)
    }

    @Test func aCommentWhoseCodeIsGoneIsListedApart() {
        let placement = ReviewPlacement.place([comment(.new, 11, excerpt: "something else entirely")], in: lines)
        #expect(placement.below.isEmpty)
        #expect(placement.unplaced.count == 1)
    }

    @Test func aRangeIsDrawnUnderItsLastLine() {
        let range = comment(.new, 11, excerpt: "let first = items.first!\nprint(first)", lastLine: 12)
        let placement = ReviewPlacement.place([range], in: lines)
        #expect(placement.below[4]?.count == 1)
    }

    @Test func aRangeAcrossHiddenContextKeepsItsLineOffsets() throws {
        let lines = separatedChanges()
        let anchor = DiffAnchor(side: .new, line: 10, lastLine: 20)
        let quote = NumberedDiffLine.excerpt(anchor, in: lines)
        #expect(quote.text == "newFirst()\nnewLast()")
        #expect(quote.offsets == [0, 10])
        let note = ReviewComment(root: "/repo", path: "App.swift", anchor: anchor,
                                 excerpt: quote.text, body: "Keep these calls together.",
                                 excerptOffsets: quote.offsets)
        let reopened = try JSONDecoder().decode(ReviewComment.self, from: JSONEncoder().encode(note))
        let placement = ReviewPlacement.place([reopened], in: lines)
        #expect(placement.unplaced.isEmpty)
        #expect(placement.below[6]?.map(\.id) == [note.id])

        let moved = ReviewPlacement.locate(anchor, excerpt: quote.text, excerptOffsets: quote.offsets,
                                           in: NumberedDiffLine.lines(separatedChanges(start: 30)))
        #expect(moved?.anchor == DiffAnchor(side: .new, line: 30, lastLine: 40))

        var expanded = lines
        expanded.replaceSubrange(3...3, with: (11...19).map {
            DiffLine(id: 100 + $0, kind: .context, text: " context\($0)")
        })
        #expect(ReviewPlacement.place([note], in: expanded).below[6]?.count == 1)

        var changed = lines
        changed[6].text = "+differentLast()"
        #expect(ReviewPlacement.place([note], in: changed).unplaced.map(\.id) == [note.id])
    }

    @Test func aRemovedRangeIncludesUnchangedLinesBetweenTheDeletions() {
        let lines = [
            DiffLine(id: 0, kind: .hunk, text: "@@ -10,3 +10,3 @@"),
            DiffLine(id: 1, kind: .deletion, text: "-oldFirst()"),
            DiffLine(id: 2, kind: .addition, text: "+newFirst()"),
            DiffLine(id: 3, kind: .context, text: " unchanged()"),
            DiffLine(id: 4, kind: .deletion, text: "-oldLast()"),
            DiffLine(id: 5, kind: .addition, text: "+newLast()")
        ]
        let anchor = DiffAnchor(side: .old, line: 10, lastLine: 12)
        let quote = NumberedDiffLine.excerpt(anchor, in: lines)
        #expect(quote.text == "oldFirst()\nunchanged()\noldLast()")
        #expect(quote.offsets == [0, 1, 2])
        let note = ReviewComment(root: "/repo", path: "App.swift", anchor: anchor,
                                 excerpt: quote.text, body: "Keep these calls.", excerptOffsets: quote.offsets)
        #expect(ReviewPlacement.place([note], in: lines).below[4]?.count == 1)
    }

    @Test func commentsSavedWithoutOffsetsStillLoadAndFollowTheirCode() throws {
        let note = comment(.new, 9, excerpt: "let first = items.first!\nprint(first)", lastLine: 10)
        let data = try JSONEncoder().encode(note)
        #expect(!String(decoding: data, as: UTF8.self).contains("excerptOffsets"))
        let reopened = try JSONDecoder().decode(ReviewComment.self, from: data)
        #expect(reopened.excerptOffsets == nil)
        #expect(ReviewPlacement.place([reopened], in: lines).below[4]?.count == 1)
    }

    private func separatedChanges(start: Int = 10) -> [DiffLine] {
        [DiffLine(id: 0, kind: .hunk, text: "@@ -\(start),1 +\(start),1 @@"),
         DiffLine(id: 1, kind: .deletion, text: "-oldFirst()"),
         DiffLine(id: 2, kind: .addition, text: "+newFirst()"),
         DiffLine(id: 3, kind: .gap, text: "", gap: DiffGap(
            revision: .workingTree, path: "App.swift", id: 0, start: start + 1, count: 9)),
         DiffLine(id: 4, kind: .hunk, text: "@@ -\(start + 10),1 +\(start + 10),1 @@"),
         DiffLine(id: 5, kind: .deletion, text: "-oldLast()"),
         DiffLine(id: 6, kind: .addition, text: "+newLast()")]
    }

    @Test func shiftClickStretchesARunEitherWay() {
        let start = DiffAnchor(side: .new, line: 12)
        #expect(start.extended(to: DiffAnchor(side: .new, line: 15)) == DiffAnchor(side: .new, line: 12, lastLine: 15))
        #expect(start.extended(to: DiffAnchor(side: .new, line: 9)) == DiffAnchor(side: .new, line: 9, lastLine: 12))
        // A run cannot cross from one version of the file to the other.
        #expect(start.extended(to: DiffAnchor(side: .old, line: 3)) == DiffAnchor(side: .old, line: 3))
        #expect(DiffAnchor(side: .new, line: 4, lastLine: 4).lastLine == nil)
    }

    @Test func anchorKeysRoundTrip() {
        let anchor = DiffAnchor(side: .old, line: 42)
        #expect(DiffComments.anchor(DiffComments.key(anchor)) == anchor)
        #expect(DiffComments.keys(DiffAnchor(side: .new, line: 3, lastLine: 5)) == ["new:3", "new:4", "new:5"])
    }

    @Test func thePromptQuotesEachCommentInFileOrder() throws {
        var second = comment(.new, 12, excerpt: "print(first)", body: "Remove the debug print.")
        second.author = .agent(.codex)
        let prompt = ReviewPrompt.feedback([
            second,
            comment(.new, 11, excerpt: "let first = items.first!", body: "This crashes on an empty list.")
        ])
        #expect(prompt.hasPrefix("I reviewed your changes and left 2 comments."))
        let first = try #require(prompt.range(of: "1. App.swift, line 11\n```\nlet first = items.first!\n```\nThis crashes on an empty list."))
        let later = try #require(prompt.range(of: "2. App.swift, line 12 (raised in a Codex review)"))
        #expect(first.lowerBound < later.lowerBound)
    }

    @Test func notesOnTheSameLinesQuoteThemOnce() {
        let prompt = ReviewPrompt.feedback([
            comment(.new, 12, excerpt: "print(first)", body: "One"),
            comment(.new, 12, excerpt: "print(first)", body: "Two")
        ])
        #expect(prompt.components(separatedBy: "print(first)").count == 2)
        #expect(prompt.contains("2. App.swift, line 12, the same code as above\nTwo"))
    }

    @Test func thePromptNamesTheProjectOnlyInAWorkspace() {
        let app = comment(.new, 11, excerpt: "x", body: "One")
        var api = comment(.old, 3, excerpt: "y", body: "Two", lastLine: 4)
        api.root = "/api"
        let prompt = ReviewPrompt.feedback([app, api], projectNames: ["/repo": "web", "/api": "server"])
        #expect(prompt.contains("web/App.swift, line 11"))
        #expect(prompt.contains("server/App.swift, removed lines 3–4 of the previous version"))
        #expect(!ReviewPrompt.feedback([app]).contains("web/"))
        #expect(ReviewPrompt.feedback([app]).hasPrefix("I reviewed your changes and left a comment. Please address it."))
    }

    @Test func theStoreKeepsCommentsAcrossLaunches() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("review-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = UUID()
        let store = ReviewCommentStore(url: url)
        store.add(comment(.new, 11, excerpt: "x"), to: session)
        store.flush()

        let reopened = ReviewCommentStore(url: url)
        #expect(reopened.comments(session).count == 1)
        #expect(reopened.count(session, root: "/repo", path: "App.swift") == 1)
        reopened.clear(session)
        reopened.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aRangeMatchesOnEveryLineNotJustItsLast() {
        // Left on a block that ended in a brace; the block is gone, and a brace elsewhere
        // must not take the comment.
        let braces: [DiffLine] = [
            DiffLine(id: 0, kind: .hunk, text: "@@ -1,3 +1,3 @@"),
            DiffLine(id: 1, kind: .context, text: " if ready {"),
            DiffLine(id: 2, kind: .context, text: "     start()"),
            DiffLine(id: 3, kind: .context, text: " }")]
        let gone = comment(.new, 7, excerpt: "guard let items else {\n    return\n}", lastLine: 9)
        #expect(ReviewPlacement.place([gone], in: braces).unplaced.count == 1)
    }

    @Test func plainCodeThatMovedToOneOfSeveralPlacesIsNotGuessed() {
        let braces: [DiffLine] = [
            DiffLine(id: 0, kind: .hunk, text: "@@ -1,4 +1,4 @@"),
            DiffLine(id: 1, kind: .context, text: " }"),
            DiffLine(id: 2, kind: .context, text: " start()"),
            DiffLine(id: 3, kind: .context, text: " }")]
        // On its own line it still holds, whatever it says.
        #expect(ReviewPlacement.place([comment(.new, 1, excerpt: "}")], in: braces).below[1]?.count == 1)
        // Moved, a lone brace could be either one.
        #expect(ReviewPlacement.place([comment(.new, 9, excerpt: "}")], in: braces).unplaced.count == 1)
    }

    @Test func aRunFollowsItsCodeAndKeepsItsLength() {
        let moved = ReviewPlacement.locate(DiffAnchor(side: .new, line: 9, lastLine: 10),
                                           excerpt: "let first = items.first!\nprint(first)",
                                           in: NumberedDiffLine.lines(lines))
        #expect(moved?.anchor == DiffAnchor(side: .new, line: 11, lastLine: 12))
        #expect(moved?.lastID == 4)
    }

    @Test func sendingTakesOnlyTheCommentsThatWereSent() {
        let store = ReviewCommentStore(url: nil)
        let session = UUID()
        let sent = comment(.new, 11, excerpt: "x")
        let arrivedLater = comment(.new, 12, excerpt: "y")
        store.add(sent, to: session)
        store.add(arrivedLater, to: session)
        store.remove([sent.id], from: session)
        #expect(store.comments(session).map(\.id) == [arrivedLater.id])
    }

    @Test func aWorkspaceNamesTheProjectEvenWhenOnlyOneHasComments() {
        var api = comment(.new, 3, excerpt: "y", body: "Two")
        api.root = "/api"
        let prompt = ReviewPrompt.feedback([api], projectNames: ["/repo": "web", "/api": "server"])
        #expect(prompt.contains("server/App.swift, line 3"))
    }

    // MARK: - Drawing

    @Test func numbersCarryTheirLineAndCommentsGetRowsOfTheirOwn() {
        let note = comment(.new, 11, excerpt: "let first = items.first!", body: "Guard the empty case.")
        let comments = DiffComments(ReviewPlacement.place([note], in: lines))
        let text = DiffText.attributed(lines, numbered: true, comments: comments)
        #expect(text.string.contains("Guard the empty case."))

        var keys: Set<String> = []
        var commentIDs: Set<String> = []
        text.enumerateAttribute(.diffLineAnchor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let key = value as? String { keys.insert(key) }
        }
        text.enumerateAttribute(.diffComment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let id = value as? String { commentIDs.insert(id) }
        }
        #expect(keys == ["new:10", "old:11", "new:11", "new:12", "new:13"])
        #expect(commentIDs == [note.id.uuidString])
    }

    @Test func aDiffWithNowhereToSendCommentsHasNoAnchors() {
        let text = DiffText.attributed(lines, numbered: true)
        var found = false
        text.enumerateAttribute(.diffLineAnchor, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { found = true }
        }
        #expect(!found)
    }

    @Test func notesWrapOnSpaces() {
        #expect(DiffText.wrapped("one two three", width: 7) == ["one two", "three"])
        #expect(DiffText.wrapped("abcdefghij", width: 4) == ["abcd", "efgh", "ij"])
        #expect(DiffText.wrapped("first\nsecond", width: 40) == ["first", "second"])
    }
}

// Another agent's review comes back as text that should be a JSON array of findings,
// which are turned into comments on the lines they name.
struct SecondOpinionTests {

    private let patch = SecondOpinion.Patch(root: "/repo", path: "Sources/App.swift", label: "Sources/App.swift",
                                            text: """
    diff --git a/Sources/App.swift b/Sources/App.swift
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -10,3 +10,4 @@
     let items = load()
    -let first = items[0]
    +let first = items.first!
    +print(first)
     return first
    """)

    @Test func findingsAreReadOutOfAWrappedAnswer() {
        let answer = """
        Here is what I found:
        ```json
        [{"file": "Sources/App.swift", "line": 11, "comment": "Crashes when [items] is empty."}]
        ```
        """
        let findings = SecondOpinion.findings(in: answer)
        #expect(findings == [SecondOpinion.Finding(file: "Sources/App.swift", line: 11,
                                                   comment: "Crashes when [items] is empty.")])
    }

    @Test func anEmptyArrayMeansNothingFoundButProseMeansUnreadable() {
        #expect(SecondOpinion.findings(in: "[]") == [])
        #expect(SecondOpinion.findings(in: "Looks good to me!") == nil)
        #expect(SecondOpinion.findings(in: "see [1] and [2]") == nil)
    }

    @Test func bracketsInsideStringsDoNotSplitTheArray() {
        let arrays = SecondOpinion.jsonArrays(in: #"x [{"comment": "a ] b"}] y [1]"#)
        #expect(arrays == [#"[{"comment": "a ] b"}]"#, "[1]"])
    }

    @Test func aPatchKnowsTheCodeOnEachNumberedLine() {
        let new = SecondOpinion.newLines(in: patch.text)
        #expect(new[10] == "let items = load()")
        #expect(new[11] == "let first = items.first!")
        #expect(new[13] == "return first")
        #expect(SecondOpinion.oldLines(in: patch.text)[11] == "let first = items[0]")
    }

    @Test func findingsBecomeCommentsByTheReviewer() {
        let findings = [
            SecondOpinion.Finding(file: "Sources/App.swift", line: 11, comment: " Crashes on empty. "),
            SecondOpinion.Finding(file: "Other.swift", line: 1, comment: "Not in the diff"),
            SecondOpinion.Finding(file: "Sources/App.swift", line: 12, comment: "")
        ]
        let comments = SecondOpinion.comments(from: findings, patches: [patch], agent: .codex)
        #expect(comments.count == 1)
        #expect(comments[0].body == "Crashes on empty.")
        #expect(comments[0].excerpt == "let first = items.first!")
        #expect(comments[0].author == .agent(.codex))
        #expect(comments[0].anchor == DiffAnchor(side: .new, line: 11))
    }

    @Test func thePromptIncludesEveryPatchThatFits() {
        let prompt = SecondOpinion.prompt(for: [patch])
        #expect(prompt.contains("File: Sources/App.swift\nPath: /repo/Sources/App.swift\ndiff --git"))
        #expect(prompt.contains("Reply with only a JSON array"))
    }

    @Test func eachReviewerRunsReadOnly() {
        let claude = SecondOpinion.arguments(for: .claudeCode, prompt: "p")
        #expect(claude.contains("--disallowedTools"))
        let codex = SecondOpinion.arguments(for: .codex, prompt: "p")
        #expect(codex.contains("read-only"))
        #expect(codex.last == "p")
    }

    @Test func noReviewerGetsThePersonsMCPServersOrWriteAccess() throws {
        let codex = SecondOpinion.arguments(for: .codex, prompt: "p", codexServers: [
            DisabledMCPServer(name: "files", transport: .stdio),
            DisabledMCPServer(name: "remote", transport: .streamableHTTP)
        ])
        #expect(codex.contains(#"mcp_servers={"files"={enabled=false,command="/usr/bin/false"},"remote"={enabled=false,url="https://disabled.invalid"}}"#))
        let copilot = SecondOpinion.arguments(for: .copilot, prompt: "p", copilotServers: ["files"])
        #expect(copilot.contains("--deny-tool=shell"))
        #expect(copilot.contains("--deny-tool=write"))
        #expect(copilot.contains("--deny-tool=files"))
        let disabled = try #require(copilot.firstIndex(of: "--disable-mcp-server"))
        #expect(copilot[disabled + 1] == "files")
    }

    @Test func copilotsServersAreReadFromItsOwnConfiguration() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"mcpServers": {"files": {}, "browser": {}}}"#.utf8).write(to: url)
        #expect(SecondOpinion.copilotServers(in: url) == ["browser", "files"])
        #expect(SecondOpinion.copilotServers(in: url.appendingPathExtension("missing")).isEmpty)
    }

    @Test func claudesAnswerIsItsResultField() {
        let output = #"{"type":"result","subtype":"success","result":"[]","is_error":false}"#
        #expect(SecondOpinion.answer(from: output, agent: .claudeCode) == "[]")
    }

    @Test func workspaceRootsAndOmittedFilesHaveTheirActualPaths() {
        var attached = patch
        attached.root = "/worktrees/api-123"
        attached.label = "API/Sources/App.swift"
        attached.text = String(repeating: "x", count: SecondOpinion.patchBudget + 1)
        let prompt = SecondOpinion.prompt(for: [patch, attached], repositories: [
            (root: "/repo", name: "App"),
            (root: "/worktrees/api-123", name: "API"),
            (root: "/elsewhere/shared-456", name: "Shared")
        ])
        #expect(prompt.contains("- API: /worktrees/api-123"))
        #expect(prompt.contains("- Shared: /elsewhere/shared-456"))
        #expect(prompt.contains("File: API/Sources/App.swift\nPath: /worktrees/api-123/Sources/App.swift"))
        #expect(!prompt.contains(attached.text))
    }

    @Test(arguments: [AgentKind.claudeCode, .copilot, .codex])
    func attachedProjectsCanBeReadWithoutEnablingWrites(_ agent: AgentKind) {
        let roots = ["/worktrees/attached project", "/elsewhere/shared"]
        let arguments = SecondOpinion.arguments(for: agent, prompt: "p", addDirectories: roots)
        if agent == .codex {
            #expect(arguments.contains("read-only"))
            #expect(!arguments.contains("--add-dir"))
        } else if agent == .claudeCode {
            let start = arguments.firstIndex(of: "--add-dir")
            #expect(start != nil)
            #expect(start.map { Array(arguments.dropFirst($0 + 1)) } == roots)
            #expect(arguments.contains("--disallowedTools"))
        } else {
            let granted = arguments.indices.filter { arguments[$0] == "--add-dir" }.map { arguments[$0 + 1] }
            #expect(granted == roots)
            #expect(arguments.contains("--deny-tool=write"))
        }
    }
}
