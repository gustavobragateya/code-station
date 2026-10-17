import Foundation

// Another agent reads a session's changes and leaves review comments on them. It runs on
// its own, read-only, outside the session's conversation: what it finds lands in the
// review as comments the person can keep, edit or delete before any of it reaches the
// agent that wrote the code.
enum SecondOpinion {
    struct Failure: Error, Equatable {
        let message: String
    }

    // One file's changes as the reviewer is shown them. The label is how the prompt names
    // the file, which in a workspace has to say which project it is in.
    struct Patch: Equatable, Sendable {
        var root: String
        var path: String
        var label: String
        var text: String
        var deleted = false
    }

    // What the reviewer is asked to send back for each problem it finds.
    struct Finding: Decodable, Equatable {
        var file: String
        var line: Int
        var comment: String
    }

    // A prompt is passed on the command line, and a huge diff would not fit there or in a
    // reviewer's attention. Files past this budget are named without their patch.
    static let patchBudget = 120_000
    static let maxFindings = 8

    // MARK: - Gathering the changes

    static func patches(for repositories: [(root: String, name: String)]) async -> [Patch] {
        let spansProjects = repositories.count > 1
        var patches: [Patch] = []
        for repository in repositories {
            let snapshot = await GitInspector.snapshot(at: repository.root, lane: .interactive,
                                                       comparingToLastCommit: true)
            guard snapshot.state == .ready else { continue }
            for file in snapshot.files where !file.isBinary {
                guard case .success(let text) = await GitInspector.copyText(
                    for: file, root: snapshot.root, version: .patch), !text.isBlank else { continue }
                patches.append(Patch(root: snapshot.root, path: file.path,
                                     label: spansProjects ? repository.name + "/" + file.path : file.path,
                                     text: text, deleted: file.kind == .deleted))
            }
        }
        return patches
    }

    // MARK: - Asking

    static func prompt(for patches: [Patch]) -> String {
        var budget = patchBudget
        var shown: [String] = []
        var left: [String] = []
        for patch in patches {
            if patch.text.utf8.count <= budget {
                budget -= patch.text.utf8.count
                shown.append("File: \(patch.label)\n\(patch.text)")
            } else {
                left.append(patch.label)
            }
        }
        var text = """
        You are reviewing changes another coding agent made in this repository. Do not change any files or run commands that change anything. You may read files for context.

        Look for real problems: bugs, unhandled edge cases, security issues, broken behaviour, and anything the change clearly needs but is missing. Skip style preferences, naming opinions and praise. Report at most \(maxFindings) findings, the most important first. If nothing is worth raising, return an empty array.

        Reply with only a JSON array and no other text. Each item is:
        {"file": "<the path after File: below>", "line": <line number in the new version of the file>, "comment": "<one or two sentences addressed to the author>"}
        For a problem on a removed line, use the nearest line in the new version.

        The changes:
        """
        text += "\n\n" + shown.joined(separator: "\n\n")
        if !left.isEmpty {
            text += "\n\nThese files also changed but are too large to include. Read them if you need to: "
                + left.joined(separator: ", ")
        }
        return text
    }

    // Each CLI in its strictest read-only setting, so a reviewer that reaches for an edit
    // is stopped by the agent rather than by the prompt. None of them gets the MCP servers
    // the person has set up either: any one of those can write, and none is needed to read
    // a diff.
    static func arguments(for agent: AgentKind, prompt: String,
                          copilotServers: [String] = []) -> [String] {
        switch agent {
        case .claudeCode:
            ["-p", prompt, "--output-format", "json",
             "--permission-mode", "default",
             "--allowedTools", "Read,Grep,Glob",
             "--disallowedTools", "Edit,Write,MultiEdit,NotebookEdit,Bash",
             "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
        case .codex:
            ["exec", "--json", "--skip-git-repo-check",
             "--sandbox", "read-only",
             "-c", #"approval_policy="never""#,
             "-c", "mcp_servers={}",
             prompt]
        case .copilot:
            // Copilot remembers what was allowed in a folder from one run to the next, and
            // a denial outranks every allowance, so writes and the shell are denied outright.
            ["-p", prompt, "--output-format", "json",
             "--no-ask-user", "--disable-builtin-mcps", "--log-level", "none",
             "--deny-tool=shell", "--deny-tool=write"]
                + copilotServers.flatMap { ["--disable-mcp-server", $0, "--deny-tool=\($0)"] }
        }
    }

    // The servers in Copilot's own MCP configuration, which it loads on every run and has
    // no switch to leave out as a whole.
    static func copilotServers(in url: URL = FileManager.default.homeDirectoryForCurrentUser
                                .appendingPathComponent(".copilot/mcp-config.json")) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted()
    }

    static func review(_ patches: [Patch], agent: AgentKind, executable: String,
                       searchPath: String, directory: String) async -> Result<[ReviewComment], Failure> {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath
        let output: CommandRunner.Output
        do {
            output = try await CommandRunner.run(
                executable: executable,
                arguments: arguments(for: agent, prompt: prompt(for: patches),
                                     copilotServers: agent == .copilot ? copilotServers() : []),
                currentDirectory: URL(fileURLWithPath: directory),
                environment: environment,
                timeout: .seconds(420),
                outputByteLimit: 8_388_608)
        } catch let error as CommandRunner.RunError {
            return .failure(Failure(message: error == .timedOut
                ? "It took longer than seven minutes." : error.localizedDescription))
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
        guard output.succeeded else {
            SessionLog.note("\(agent.command) second opinion failed status=\(output.status) "
                            + String(output.errorOutput.suffix(400)))
            return .failure(Failure(message: "The \(agent.command) command stopped with status \(output.status)."))
        }
        let answer = answer(from: output.output, agent: agent)
        guard let findings = findings(in: answer) else {
            SessionLog.note("\(agent.command) second opinion was unreadable: " + String(answer.prefix(400)))
            return .failure(Failure(message: "Its answer was not a list of findings."))
        }
        return .success(comments(from: findings, patches: patches, agent: agent))
    }

    // MARK: - Reading the answer

    // The words the reviewer ended on. Claude answers with one result object; the others
    // stream events, and the findings are in what they said last.
    static func answer(from output: String, agent: AgentKind) -> String {
        switch agent {
        case .claudeCode:
            for line in output.split(separator: "\n").reversed() {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = object["result"] as? String else { continue }
                return result
            }
            return output
        case .codex, .copilot:
            let copilot = CopilotStream()
            var parts: [String] = []
            for line in output.split(separator: "\n") {
                let events = agent == .codex ? StreamEvent.parseCodex(String(line)) : copilot.parse(String(line))
                for case .text(let text) in events { parts.append(text) }
            }
            return parts.joined(separator: "\n")
        }
    }

    // The last JSON array of findings in the text. Models wrap their answer in a fence or
    // a sentence however firmly they are told not to, so the array is found rather than
    // expected to be the whole reply. Nil when there is none, which is not the same as an
    // empty array: that is a reviewer saying it found nothing.
    static func findings(in text: String) -> [Finding]? {
        var found: [Finding]?
        for candidate in jsonArrays(in: text) {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let decoded = try? JSONDecoder().decode([Finding].self, from: data) {
                found = decoded
            }
        }
        return found.map { Array($0.prefix(maxFindings)) }
    }

    // Every top-level bracketed run in the text, with brackets inside strings ignored.
    static func jsonArrays(in text: String) -> [String] {
        let characters = Array(text)
        var arrays: [String] = []
        var depth = 0
        var start: Int?
        var inString = false
        var escaped = false
        for (index, character) in characters.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"" where depth > 0:
                inString = true
            case "[":
                if depth == 0 { start = index }
                depth += 1
            case "]" where depth > 0:
                depth -= 1
                if depth == 0, let begin = start {
                    arrays.append(String(characters[begin...index]))
                    start = nil
                }
            default:
                break
            }
        }
        return arrays
    }

    // MARK: - Turning findings into comments

    static func comments(from findings: [Finding], patches: [Patch], agent: AgentKind) -> [ReviewComment] {
        findings.compactMap { finding in
            let body = finding.comment.trimmed
            guard !body.isEmpty, finding.line > 0,
                  let patch = patches.first(where: { $0.label == finding.file })
                    ?? patches.first(where: { $0.path == finding.file || finding.file.hasSuffix("/" + $0.path) })
            else { return nil }
            let side: ReviewSide = patch.deleted ? .old : .new
            let lines = side == .new ? newLines(in: patch.text) : oldLines(in: patch.text)
            let excerpt = lines[finding.line] ?? fileLine(finding.line, of: patch) ?? ""
            return ReviewComment(root: patch.root, path: patch.path,
                                 anchor: DiffAnchor(side: side, line: finding.line),
                                 excerpt: excerpt, body: body, author: .agent(agent))
        }
    }

    // The lines a patch shows of the new version, by their number there.
    static func newLines(in patch: String) -> [Int: String] { lines(in: patch, side: .new) }
    static func oldLines(in patch: String) -> [Int: String] { lines(in: patch, side: .old) }

    private static func lines(in patch: String, side: ReviewSide) -> [Int: String] {
        var result: [Int: String] = [:]
        var old = 0
        var new = 0
        var inHunk = false
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("@@") {
                let parts = line.split(separator: " ")
                guard parts.count >= 3 else { continue }
                old = Int(parts[1].dropFirst().split(separator: ",")[0]) ?? 0
                new = Int(parts[2].dropFirst().split(separator: ",")[0]) ?? 0
                inHunk = true
                continue
            }
            guard inHunk else { continue }
            if line.hasPrefix("+") {
                if side == .new { result[new] = String(line.dropFirst()) }
                new += 1
            } else if line.hasPrefix("-") {
                if side == .old { result[old] = String(line.dropFirst()) }
                old += 1
            } else if line.hasPrefix(" ") {
                result[side == .new ? new : old] = String(line.dropFirst())
                old += 1
                new += 1
            }
        }
        return result
    }

    // A reviewer can point at a line the diff does not show. The file on disk has it.
    private static func fileLine(_ number: Int, of patch: Patch) -> String? {
        guard !patch.deleted,
              let text = try? String(contentsOfFile: (patch.root as NSString).appendingPathComponent(patch.path),
                                     encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        return number <= lines.count ? lines[number - 1] : nil
    }
}
