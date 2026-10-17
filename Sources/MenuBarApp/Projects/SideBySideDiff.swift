import AppKit
import SwiftUI

struct DiffComparisonRow: Identifiable {
    let id: Int
    var left: DiffLine?
    var right: DiffLine?
    var oldNumber: Int?
    var newNumber: Int?

    static func align(_ lines: [DiffLine]) -> [Self] {
        var rows: [Self] = []
        var old = 1
        var new = 1
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.kind == .deletion || line.kind == .addition {
                var removed: [DiffLine] = []
                var added: [DiffLine] = []
                while index < lines.count && (lines[index].kind == .deletion || lines[index].kind == .addition) {
                    if lines[index].kind == .deletion { removed.append(lines[index]) }
                    else { added.append(lines[index]) }
                    index += 1
                }
                for offset in 0..<max(removed.count, added.count) {
                    let left = offset < removed.count ? removed[offset] : nil
                    let right = offset < added.count ? added[offset] : nil
                    rows.append(Self(id: rows.count, left: left, right: right,
                                     oldNumber: left == nil ? nil : old, newNumber: right == nil ? nil : new))
                    if left != nil { old += 1 }
                    if right != nil { new += 1 }
                }
                continue
            }
            if line.kind == .hunk {
                let parts = line.text.split(separator: " ")
                if parts.count >= 3 {
                    old = Int(parts[1].dropFirst().split(separator: ",")[0]) ?? old
                    new = Int(parts[2].dropFirst().split(separator: ",")[0]) ?? new
                }
            }
            if line.kind == .gap, let gap = line.gap {
                old += gap.count ?? 0
                new = gap.start + (gap.count ?? 0)
            }
            let numbered = line.kind == .context
            rows.append(Self(id: rows.count, left: line, right: line,
                             oldNumber: numbered ? old : nil, newNumber: numbered ? new : nil))
            if numbered { old += 1; new += 1 }
            index += 1
        }
        return rows
    }
}

struct SideBySideDiff: View {
    let lines: [DiffLine]
    let expand: (String, DiffExpandDirection) -> Void
    // Review comments, already placed under their lines. A diff with nowhere to send
    // comments leaves the line handler out, and its numbers are plain text.
    var comments = ReviewPlacement()
    var picked: Set<String> = []
    var onLine: ((DiffAnchor, Bool) -> Void)?
    var onComment: ((ReviewComment) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 0) {
                    ForEach(DiffComparisonRow.align(lines)) { row in
                        if let gap = row.left?.gap {
                            HStack {
                                ForEach([DiffExpandDirection.up, .all, .down], id: \.self) { direction in
                                    Button("Show context \(direction.rawValue)") { expand(gap.key, direction) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .font(.system(size: 11)).padding(8)
                        } else if row.left?.kind == .hunk || row.left?.kind == .meta || row.left?.kind == .section {
                            Text(row.left?.text ?? "").font(.mono(11))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                .background(Theme.field)
                        } else {
                            HStack(alignment: .top, spacing: 0) {
                                cell(row.left, number: row.oldNumber,
                                     anchor: anchor(row.left, side: .old, number: row.oldNumber))
                                cell(row.right, number: row.newNumber,
                                     anchor: anchor(row.right, side: .new, number: row.newNumber))
                            }
                            ForEach(rowComments(row)) { comment in
                                ReviewCommentCard(comment: comment) { onComment?(comment) }
                                    .padding(.leading, 54).padding(.trailing, 12).padding(.vertical, 4)
                            }
                        }
                    }
                }
                .frame(width: max(760, geometry.size.width))
            }
        }
    }

    // A context line is numbered on both sides but commented on in the new version, so
    // its left number is not a place to start one.
    private func anchor(_ line: DiffLine?, side: ReviewSide, number: Int?) -> DiffAnchor? {
        guard onLine != nil, let line, let number else { return nil }
        switch line.kind {
        case .addition where side == .new, .context where side == .new: return DiffAnchor(side: .new, line: number)
        case .deletion where side == .old: return DiffAnchor(side: .old, line: number)
        default: return nil
        }
    }

    private func rowComments(_ row: DiffComparisonRow) -> [ReviewComment] {
        var ids = [row.left?.id, row.right?.id].compactMap { $0 }
        if ids.count == 2 && ids[0] == ids[1] { ids.removeLast() }
        return ids.flatMap { comments.below[$0] ?? [] }
    }

    @ViewBuilder private func number(_ number: Int?, anchor: DiffAnchor?) -> some View {
        let label = Text(number.map(String.init) ?? "").foregroundStyle(.secondary)
            .frame(width: 36, alignment: .trailing)
        if let anchor, let onLine {
            Button {
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                onLine(anchor, shift)
            } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverFill(cornerRadius: 4)
            .appTooltip("Comment on this line. Shift-click to comment on a range.")
            .accessibilityLabel("Comment on \(anchor.label.lowercased())")
        } else {
            label
        }
    }

    private func cell(_ line: DiffLine?, number: Int?, anchor: DiffAnchor? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            self.number(number, anchor: anchor)
            Text(line.map { String($0.text.prefix(1)) } ?? "").frame(width: 10)
            Text(line.map { String($0.text.dropFirst()) } ?? " ")
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.mono(12)).padding(.vertical, 3).padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if line == nil {
                Canvas { context, size in
                    var stripes = Path()
                    for x in stride(from: -size.height, to: size.width, by: 8) {
                        stripes.move(to: CGPoint(x: x, y: 0))
                        stripes.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    }
                    context.stroke(stripes, with: .color(Theme.border), lineWidth: 3)
                }.background(Theme.field).clipped()
            }
        }
        .background(line?.kind == .addition ? Theme.addition.opacity(0.12) :
                    line?.kind == .deletion ? Theme.deletion.opacity(0.12) : line == nil ? Theme.field : .clear)
        .background(anchor.map { !picked.isDisjoint(with: DiffComments.keys($0)) } == true
                    ? Theme.accent.opacity(0.16) : .clear)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
        .accessibilityLabel(line == nil ? "No corresponding line" : line!.text)
    }
}

// A review comment drawn as a card: who left it and what it says. Pressing it opens the
// comment to edit or delete.
struct ReviewCommentCard: View {
    let comment: ReviewComment
    var detail: String?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: comment.author == .you ? "text.bubble" : "person.2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(comment.authorName).font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        if let detail {
                            Text(detail).font(.mono(10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Text(comment.body)
                        .font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3).padding(.vertical, 6)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 8)
        .appTooltip("Edit or delete this comment")
        .accessibilityLabel("Comment from \(comment.authorName): \(comment.body)")
    }
}
