import AppKit
import SwiftUI

// The diff itself, drawn by AppKit. SwiftUI's selectable Text only covers what is
// laid out on screen, so Select All in a tall diff would copy the visible lines and
// drop the rest. An NSTextView owns the whole document, which makes Cmd+A, copy,
// and drag selection behave like they do in an editor.
struct DiffTextView: NSViewRepresentable {
    // Where the pane looks once the text has changed.
    enum Scroll {
        // A diff that was just opened starts at the top.
        case top
        // The same diff showing more of itself, below what is on screen: the rows
        // already up there keep their place.
        case hold
        // The same diff showing more of itself, above what is on screen: the view moves
        // down by as much as the document grew, so the pressed row stays under the
        // pointer and the new lines fill in above it.
        case follow
    }

    let text: NSAttributedString
    var scroll: Scroll = .top
    // The gap row a press landed on, named by DiffGap.key, and the end of it to open.
    var onExpand: ((String, DiffExpandDirection) -> Void)?
    // Grow to the height of the whole diff instead of scrolling it, for a diff that sits
    // in a page with others and scrolls along with that page.
    var fitsContent = false
    // A press on a line number, named by DiffAnchor key, and whether shift was held to
    // stretch the comment being written over to it. Nil where the diff takes no comments.
    var onLine: ((String, Bool) -> Void)?
    // A press on a review comment drawn in the diff, named by its id.
    var onComment: ((String) -> Void)?
    // The lines the comment being written is about, drawn picked out.
    var picked: Set<String> = []

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // The text system is built by hand so the view starts on TextKit 1:
        // drawBackground below walks the layout manager, and asking a TextKit 2
        // view for one mid-life throws its layout away.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = DiffDocumentView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 6)
        // Lines keep their length and the pane scrolls sideways instead of wrapping.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = []

        let scrollView = DiffScrollView()
        scrollView.passesVerticalScroll = fitsContent
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = !fitsContent
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? DiffDocumentView else { return }
        textView.onExpand = onExpand
        textView.onLine = onLine
        textView.onComment = onComment
        if textView.picked != picked {
            textView.picked = picked
            textView.needsDisplay = true
        }
        // The string is built once per loaded diff, so identity is enough to tell the
        // same document from a newly opened file.
        guard context.coordinator.shown !== text else { return }
        context.coordinator.shown = text
        let heightBefore = textView.frame.height
        let origin = scrollView.contentView.bounds.origin
        textView.textStorage?.setAttributedString(text)
        textView.sizeToFit()
        // The text system only repaints where glyphs changed, but a row's band starts in
        // the margin left of them, so rows that moved would keep stale margins.
        textView.needsDisplay = true
        switch scroll {
        case .top:
            scrollView.contentView.scroll(to: .zero)
        case .hold:
            scrollView.contentView.scroll(to: origin)
        case .follow:
            let grew = textView.frame.height - heightBefore
            scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: max(0, origin.y + grew)))
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView,
                      context: Context) -> CGSize? {
        guard fitsContent, let textView = scrollView.documentView else { return nil }
        return CGSize(width: proposal.width ?? textView.frame.width, height: textView.frame.height)
    }

    final class Coordinator {
        var shown: NSAttributedString?
    }
}

// A diff that fits its content still scrolls sideways on its own, but a vertical swipe
// over it belongs to the page around it.
private final class DiffScrollView: NSScrollView {
    var passesVerticalScroll = false

    override func scrollWheel(with event: NSEvent) {
        if passesVerticalScroll && abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

// NSTextView paints the background colour attribute behind the glyphs only. A diff row
// wants its band to run the full width of the pane, so the colour travels in a custom
// attribute and is painted here across the whole line fragment.
private final class DiffDocumentView: NSTextView {
    var onExpand: ((String, DiffExpandDirection) -> Void)?
    var onLine: ((String, Bool) -> Void)?
    var onComment: ((String) -> Void)?
    var picked: Set<String> = []
    // The gap row under the pointer, which is drawn a shade stronger so it reads as
    // something to press.
    private var hovered: String?
    // The line number or comment under the pointer, in a diff that takes comments.
    private var hoveredRow: DiffRowHit?
    private var hoverTracking: NSTrackingArea?

    // Grow with the text, but never sit narrower than the pane, so the bands reach the
    // right edge even when every line is short.
    override func setFrameSize(_ newSize: NSSize) {
        let clipWidth = enclosingScrollView?.contentSize.width ?? 0
        super.setFrameSize(NSSize(width: max(newSize.width, clipWidth), height: newSize.height))
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification,
                                                  object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(paneResized),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    // sizeToFit measures from the layout again, so a shrunk pane also lets go of any
    // width the text never needed.
    @objc private func paneResized() { sizeToFit() }

    // MARK: - Opening a gap

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseDown(with event: NSEvent) {
        // A held modifier means the click is about the selection, not the row. Shift is
        // the one exception on a line number, where it stretches a comment over lines.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = flags.isEmpty
        if plain, let onExpand, let target = target(at: event), let direction = target.direction {
            onExpand(target.key, direction)
            return
        }
        if plain || flags == .shift, let row = row(at: event) {
            switch row.kind {
            case .line:
                if let onLine { onLine(row.key, flags == .shift); return }
            case .comment:
                if plain, let onComment { onComment(row.key); return }
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let target = target(at: event)
        let row = row(at: event)
        if target?.direction != nil || row != nil { NSCursor.pointingHand.set() }
        guard target?.key != hovered || row != hoveredRow else { return }
        hovered = target?.key
        hoveredRow = row
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard hovered != nil || hoveredRow != nil else { return }
        hovered = nil
        hoveredRow = nil
        needsDisplay = true
    }

    override func cursorUpdate(with event: NSEvent) {
        if target(at: event)?.direction != nil || row(at: event) != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    private func row(at event: NSEvent) -> DiffRowHit? {
        guard onLine != nil || onComment != nil,
              let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        return DiffRowHit.at(NSPoint(x: point.x - origin.x, y: point.y - origin.y),
                             layoutManager: layoutManager, container: textContainer,
                             storage: storage)
    }

    private func target(at event: NSEvent) -> DiffGapHit? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        return DiffGapHit.at(NSPoint(x: point.x - origin.x, y: point.y - origin.y),
                             layoutManager: layoutManager, container: textContainer,
                             storage: storage)
    }

    // A hovered row sits a shade stronger than its usual band. Mixing towards the text
    // colour works in either appearance: it darkens on a light pane and lightens on a
    // dark one.
    private func hoverFill(_ band: NSColor) -> NSColor {
        guard let base = band.usingColorSpace(.sRGB),
              let ink = NSColor.labelColor.usingColorSpace(.sRGB),
              let mixed = base.blended(withFraction: 0.12, of: ink) else { return band }
        return mixed
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return }
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y),
                                              in: textContainer)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
            let index = layoutManager.characterIndexForGlyph(at: lineGlyphs.location)
            guard index < storage.length,
                  let band = storage.attribute(.diffRowBackground, at: index,
                                               effectiveRange: nil) as? NSColor else { return }
            let isHovered = self.hovered != nil
                && storage.attribute(.diffGap, at: index, effectiveRange: nil) as? String == self.hovered
            let comment = storage.attribute(.diffComment, at: index, effectiveRange: nil) as? String
            let commentHovered = comment != nil && self.hoveredRow == DiffRowHit(kind: .comment, key: comment!)
            (isHovered || commentHovered ? self.hoverFill(band) : band).setFill()
            NSRect(x: 0, y: fragment.minY + origin.y,
                   width: self.bounds.width, height: fragment.height).fill()
            if comment != nil {
                // The rule down the left edge ties a comment's rows into one card.
                Theme.accentNSColor.setFill()
                NSRect(x: 0, y: fragment.minY + origin.y, width: 3, height: fragment.height).fill()
            }
        }
        drawLineMarks(in: rect, layoutManager: layoutManager, container: textContainer, storage: storage)
    }

    // The lines a comment is being written about wear the accent across the row, and the
    // number under the pointer turns into a plus so it reads as the place to start one.
    private func drawLineMarks(in rect: NSRect, layoutManager: NSLayoutManager,
                               container: NSTextContainer, storage: NSTextStorage) {
        guard onLine != nil, !picked.isEmpty || hoveredRow?.kind == .line else { return }
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y),
                                              in: container)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
            let index = layoutManager.characterIndexForGlyph(at: lineGlyphs.location)
            var numberRange = NSRange()
            guard index < storage.length,
                  let key = storage.attribute(.diffLineAnchor, at: index,
                                              effectiveRange: &numberRange) as? String else { return }
            if self.picked.contains(key) {
                Theme.accentNSColor.withAlphaComponent(0.16).setFill()
                NSRect(x: 0, y: fragment.minY + origin.y,
                       width: self.bounds.width, height: fragment.height).fill()
            }
            guard self.hoveredRow == DiffRowHit(kind: .line, key: key) else { return }
            let numbers = layoutManager.boundingRect(
                forGlyphRange: layoutManager.glyphRange(forCharacterRange: numberRange, actualCharacterRange: nil),
                in: container).offsetBy(dx: origin.x, dy: origin.y)
            let badge = NSRect(x: numbers.minX, y: fragment.minY + origin.y + 1,
                               width: numbers.width - 6, height: fragment.height - 2)
            Theme.accentNSColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
                ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
            let plus = NSAttributedString(string: "+", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold),
                .foregroundColor: Theme.accentNSColor
            ])
            let size = plus.size()
            plus.draw(at: NSPoint(x: badge.minX + 5, y: badge.midY - size.height / 2))
        }
    }
}

// What a point in a diff that takes comments lands on: a line number to start a comment
// from, or a comment already there to open. The number only answers over its own
// characters, but a comment answers anywhere along its rows.
struct DiffRowHit: Equatable {
    enum Kind: Equatable { case line, comment }

    var kind: Kind
    var key: String

    // The point is in text container coordinates.
    static func at(_ point: NSPoint, layoutManager: NSLayoutManager,
                   container: NSTextContainer, storage: NSTextStorage) -> DiffRowHit? {
        guard storage.length > 0, point.x >= 0, point.y >= 0 else { return nil }
        let index = layoutManager.characterIndex(for: point, in: container,
                                                 fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < storage.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard point.y >= fragment.minY, point.y < fragment.maxY else { return nil }
        if let comment = storage.attribute(.diffComment, at: index, effectiveRange: nil) as? String {
            return DiffRowHit(kind: .comment, key: comment)
        }
        guard let key = storage.attribute(.diffLineAnchor, at: index, effectiveRange: nil) as? String
        else { return nil }
        return DiffRowHit(kind: .line, key: key)
    }
}

// What a point in a laid out diff lands on: the gap row it is over, and the control
// there if it is on one. A point anywhere along the row names the row, so the band can
// light up as the pointer arrives, but only the characters of a control open anything.
struct DiffGapHit: Equatable {
    var key: String
    var direction: DiffExpandDirection?

    // The point is in text container coordinates.
    static func at(_ point: NSPoint, layoutManager: NSLayoutManager,
                   container: NSTextContainer, storage: NSTextStorage) -> DiffGapHit? {
        guard storage.length > 0, point.x >= 0, point.y >= 0 else { return nil }
        let index = layoutManager.characterIndex(for: point, in: container,
                                                 fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < storage.length else { return nil }
        // The lookup above snaps to the nearest row and to the nearest character on it,
        // so a point past the text would answer with whatever is closest. Only a point
        // inside the row, and on a character of it, is on that character.
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard point.y >= fragment.minY, point.y < fragment.maxY else { return nil }
        guard let key = storage.attribute(.diffGap, at: index, effectiveRange: nil) as? String
        else { return nil }
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        guard point.x < used.maxX else { return DiffGapHit(key: key) }
        let action = storage.attribute(.diffGapAction, at: index, effectiveRange: nil) as? String
        return DiffGapHit(key: key, direction: action.flatMap(DiffExpandDirection.init(rawValue:)))
    }
}

// One attributed string for a whole diff.
enum DiffText {
    // Lining up and colouring a long diff takes long enough to stall the window, so it is
    // built away from the main thread.
    static func build(_ lines: [DiffLine], language: CodeLanguage? = nil,
                      scale: CGFloat = 1, numbered: Bool = false,
                      comments: DiffComments? = nil) async -> NSAttributedString {
        await Task.detached(priority: .userInitiated) {
            Finished(text: attributed(lines, language: language, scale: scale, numbered: numbered,
                                      comments: comments))
        }.value.text
    }

    // NSAttributedString is not marked Sendable. This one is complete before it crosses
    // to the main thread and nothing changes it after, so handing it over is safe.
    private struct Finished: @unchecked Sendable {
        let text: NSAttributedString
    }

    static func attributed(_ lines: [DiffLine],
                           language: CodeLanguage? = nil,
                           scale: CGFloat = 1, numbered: Bool = false,
                           comments: DiffComments? = nil) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11 * scale, weight: .regular)
        // Colouring is for a diff a person reads; a huge one is scrolled, not read, and
        // plain text is much cheaper to build.
        let size = lines.reduce(0) { $0 + $1.text.utf8.count }
        let withinLimit = size <= CodeHighlight.sizeLimit
        // A single-file diff names its language up front. A commit diff spans many
        // files instead, and each section heading names the file the following lines
        // belong to, so the language follows the headings.
        var activeLanguage = withinLimit ? language : nil
        let result = NSMutableAttributedString()
        var numbers: [Int: (Int?, Int?)] = [:]
        if numbered {
            for row in DiffComparisonRow.align(lines) {
                if let left = row.left { numbers[left.id] = (row.oldNumber, row.left == row.right ? row.newNumber : nil) }
                if let right = row.right, right != row.left { numbers[right.id] = (nil, row.newNumber) }
            }
        }
        for (index, line) in lines.enumerated() {
            if line.kind == .section {
                activeLanguage = withinLimit
                    ? CodeLanguage(fileExtension: (line.text as NSString).pathExtension)
                    : nil
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color(line.kind)
            ]
            if let band = band(line.kind) {
                attributes[.diffRowBackground] = band
            }
            if let gap = line.gap {
                attributes[.diffGap] = gap.key
            }
            if line.kind == .section {
                // A little air around a section title so one file's diff reads as
                // separate from the next.
                let style = NSMutableParagraphStyle()
                style.paragraphSpacingBefore = 4
                style.paragraphSpacing = 4
                attributes[.paragraphStyle] = style
            }
            let isCode = line.kind == .addition || line.kind == .deletion || line.kind == .context
            if numbered, isCode {
                let pair = numbers[line.id]
                let old = pair?.0.map(String.init) ?? ""
                let new = pair?.1.map(String.init) ?? ""
                let prefix = String(repeating: " ", count: max(0, 5 - old.count)) + old + " "
                    + String(repeating: " ", count: max(0, 5 - new.count)) + new + "  "
                var numberAttributes = attributes
                numberAttributes[.foregroundColor] = NSColor.secondaryLabelColor
                // In a diff that takes comments the numbers are where one starts.
                if comments != nil {
                    let anchor = line.kind == .deletion
                        ? pair?.0.map { DiffAnchor(side: .old, line: $0) }
                        : pair?.1.map { DiffAnchor(side: .new, line: $0) }
                    if let anchor { numberAttributes[.diffLineAnchor] = DiffComments.key(anchor) }
                }
                result.append(NSAttributedString(string: prefix, attributes: numberAttributes))
            }
            if let gap = line.gap {
                result.append(controls(gap, attributes: attributes))
            } else if let activeLanguage, isCode {
                result.append(codeLine(line, language: activeLanguage, attributes: attributes))
            } else {
                result.append(NSAttributedString(string: line.text, attributes: attributes))
            }
            for comment in comments?.below[line.id] ?? [] {
                result.append(NSAttributedString(string: "\n", attributes: attributes))
                result.append(commentRows(comment, indent: numbered ? 14 : 1, scale: scale))
            }
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
        return result
    }

    // A review comment drawn as rows of its own under the line it is about: who left it,
    // then the note, wrapped by hand since the diff never wraps its lines.
    private static func commentRows(_ comment: DiffComments.Comment, indent: Int,
                                    scale: CGFloat) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 11 * scale, weight: .regular)
        var base: [NSAttributedString.Key: Any] = [
            .font: mono,
            .foregroundColor: NSColor.labelColor,
            // A neutral card rather than an accent tint: the accent is the same green as an
            // added line, and a comment among added lines would vanish into them.
            .diffRowBackground: NSColor(Theme.card),
            .diffComment: comment.id
        ]
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2 * scale
        base[.paragraphStyle] = style
        let lead = String(repeating: " ", count: indent)
        let result = NSMutableAttributedString()
        func run(_ text: String, font: NSFont? = nil, colour: NSColor? = nil) {
            var attributes = base
            if let font { attributes[.font] = font }
            if let colour { attributes[.foregroundColor] = colour }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        run(lead)
        run(comment.author, font: NSFont.systemFont(ofSize: 11 * scale, weight: .semibold),
            colour: Theme.accentNSColor)
        run("  ·  click to edit", font: NSFont.systemFont(ofSize: 10.5 * scale),
            colour: .tertiaryLabelColor)
        for line in wrapped(comment.body, width: 96) {
            run("\n" + lead)
            run(line, font: NSFont.systemFont(ofSize: 12 * scale))
        }
        return result
    }

    // Breaks a note into lines of at most `width` characters, on spaces where it can.
    static func wrapped(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        for paragraph in text.trimmed.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                var word = String(word)
                while word.count > width {
                    if !line.isEmpty { lines.append(line); line = "" }
                    lines.append(String(word.prefix(width)))
                    word = String(word.dropFirst(width))
                }
                if line.isEmpty { line = word }
                else if line.count + 1 + word.count <= width { line += " " + word }
                else { lines.append(line); line = word }
            }
            lines.append(line)
        }
        return lines
    }

    // What a gap row offers. A gap too long to open in one go opens from either end, so
    // it carries an arrow for each: down carries on from the code above the row, up reads
    // back from the code below it. The count in the middle always opens the lot, and a
    // gap short enough to open whole is nothing but that count.
    private static func controls(_ gap: DiffGap,
                                 attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var plain = attributes
        plain[.foregroundColor] = NSColor.tertiaryLabelColor
        let result = NSMutableAttributedString()
        func add(_ text: String, _ direction: DiffExpandDirection? = nil) {
            var run = plain
            if let direction { run[.diffGapAction] = direction.rawValue }
            result.append(NSAttributedString(string: text, attributes: run))
        }

        guard let count = gap.count else {
            add(" ↓ ", .down)
            add("the rest of the file", .all)
            return result
        }
        if count > GitInspector.gapExpandWhole {
            add(" ↑ ", .up)
            add(counted(count, "line"), .all)
            add(" ↓ ", .down)
        } else {
            add(" " + counted(count, "line"), .all)
        }
        return result
    }

    // A changed line with its code in syntax colours. The sign keeps the diff colour and
    // the band runs behind the row, so added and removed still read at a glance while the
    // code itself reads like code. Each line is scanned on its own: a diff can start in
    // the middle of anything, so carrying string or comment state between its lines
    // would guess wrong as often as right.
    private static func codeLine(_ line: DiffLine, language: CodeLanguage,
                                 attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var code = Substring(line.text)
        if line.kind != .context, let sign = code.first {
            result.append(NSAttributedString(string: String(sign), attributes: attributes))
            code = code.dropFirst()
        }
        var plain = attributes
        plain[.foregroundColor] = NSColor.labelColor
        var state = CodeHighlight.State.normal
        let tokens = CodeHighlight.tokens(in: code, language: language, state: &state)
        var i = code.startIndex
        for token in tokens {
            if i < token.range.lowerBound {
                result.append(NSAttributedString(string: String(code[i..<token.range.lowerBound]),
                                                 attributes: plain))
            }
            var run = plain
            run[.foregroundColor] = CodeStyle.nsColor(for: token.kind)
            result.append(NSAttributedString(string: String(code[token.range]), attributes: run))
            i = token.range.upperBound
        }
        if i < code.endIndex {
            result.append(NSAttributedString(string: String(code[i...]), attributes: plain))
        }
        return result
    }

    private static func color(_ kind: DiffLine.Kind) -> NSColor {
        switch kind {
        case .addition: NSColor(Theme.addition)
        case .deletion: NSColor(Theme.deletion)
        case .hunk, .meta, .section, .gap: .secondaryLabelColor
        case .context: .labelColor
        }
    }

    private static func band(_ kind: DiffLine.Kind) -> NSColor? {
        switch kind {
        case .addition: NSColor(Theme.dotOn).withAlphaComponent(0.14)
        case .deletion: NSColor(Theme.deletion).withAlphaComponent(0.10)
        case .hunk, .section, .gap: NSColor(Theme.field)
        case .meta, .context: nil
        }
    }
}

extension NSAttributedString.Key {
    // The colour of the band behind a diff row. Painted by the view rather than through
    // .backgroundColor, which stops at the last glyph instead of the pane's edge.
    static let diffRowBackground = NSAttributedString.Key("codeStationDiffRowBackground")

    // Marks a row standing in for unchanged lines, named by DiffGap.key.
    static let diffGap = NSAttributedString.Key("codeStationDiffGap")

    // Marks one control on such a row, holding the DiffExpandDirection it opens. Only
    // characters carrying it answer a press.
    static let diffGapAction = NSAttributedString.Key("codeStationDiffGapAction")

    // Marks a line's numbers in a diff that takes comments, holding DiffComments.key of
    // the line they number.
    static let diffLineAnchor = NSAttributedString.Key("codeStationDiffLineAnchor")

    // Marks the rows of a review comment, holding the comment's id.
    static let diffComment = NSAttributedString.Key("codeStationDiffComment")
}

// The review comments a diff draws, already placed on the lines they belong under. It is
// handed to the builder off the main thread, so it carries plain values rather than the
// comments themselves.
struct DiffComments: Sendable, Equatable {
    struct Comment: Sendable, Equatable {
        var id: String
        var author: String
        var body: String
    }

    var below: [Int: [Comment]] = [:]

    init(_ placement: ReviewPlacement) {
        below = placement.below.mapValues { comments in
            comments.map { Comment(id: $0.id.uuidString, author: $0.authorName, body: $0.body) }
        }
    }

    static func key(_ anchor: DiffAnchor) -> String { "\(anchor.side.rawValue):\(anchor.line)" }

    static func anchor(_ key: String) -> DiffAnchor? {
        let parts = key.split(separator: ":")
        guard parts.count == 2, let side = ReviewSide(rawValue: String(parts[0])),
              let line = Int(parts[1]) else { return nil }
        return DiffAnchor(side: side, line: line)
    }

    // Every line a run covers, for drawing the run picked out.
    static func keys(_ anchor: DiffAnchor) -> Set<String> {
        Set((anchor.line...(anchor.lastLine ?? anchor.line)).map {
            key(DiffAnchor(side: anchor.side, line: $0))
        })
    }
}
