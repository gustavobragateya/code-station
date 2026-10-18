import SwiftUI

// The desktop side of mobile access: the button that hands out a code, the badge that
// says how many are out, and the sheet that shows one.

// The dialog behind the QR button, kept apart from it so a header that folds its actions
// into a menu opens the same thing without drawing the button.
@MainActor
enum MobilePairing {
    static func open(scope: MobileScope, dialogs: DialogPresenter, store: ProjectStore) {
        dialogs.show(Dialog(
            title: title(scope, store: store),
            message: """
            \(reach(scope, store: store))

            No phone can connect until you start sharing below. Sharing continues after this dialog closes. Reopen it to cancel or stop sharing.
            """,
            content: AnyView(MobilePairingView(scope: scope)),
            actions: [.init(label: "Done", kind: .primary)],
            width: 390))
    }

    private static func title(_ scope: MobileScope, store: ProjectStore) -> String {
        switch scope {
        case .session: "Open this session on your phone"
        case .project(let id): "Open \(store.project(id)?.name ?? "this project") on your phone"
        case .everything: "Open Code Station on your phone"
        }
    }

    // What the code lets the phone do, said plainly, because it is the whole difference
    // between the three codes.
    private static func reach(_ scope: MobileScope, store: ProjectStore) -> String {
        switch scope {
        case .session:
            "A phone on the same trusted Wi-Fi can read this one session, send prompts, stop turns and answer requests. It can reach nothing else."
        case .project(let id):
            "A phone on the same trusted Wi-Fi can read any session in \(store.project(id)?.name ?? "this project"), start new ones there, send prompts, stop turns and answer requests."
        case .everything:
            "A phone on the same trusted Wi-Fi can read any session in any project, start new ones anywhere, send prompts, stop turns and answer requests."
        }
    }
}

// How far along a phone link is. Green is kept for a phone that is really on the other
// end. A code that is out but not picked up yet is amber news, not a live link.
enum PhoneLink: Equatable {
    case none
    case waiting
    case connected

    static func of(shared: Bool, connected: Bool) -> PhoneLink {
        if connected { return .connected }
        return shared ? .waiting : .none
    }

    // The words the pill shows. The pairing does not say what the phone is called, so it
    // is named as a phone.
    var word: String? {
        switch self {
        case .none: nil
        case .waiting: "Waiting for phone"
        case .connected: "Phone connected"
        }
    }

    var tint: Color {
        switch self {
        case .none: .secondary
        case .waiting: Theme.attentionText
        case .connected: Theme.addition
        }
    }

    var fill: Color? {
        switch self {
        case .none: nil
        case .waiting: Theme.attention.opacity(0.11)
        case .connected: HeaderRailState.live.seat
        }
    }
}

// The phone pill on the Home header, the one place a code is handed out. Every code
// reaches the whole app, so a phone is either in on everything or on nothing.
struct MobileAccessButton: View {
    @Environment(MobileAccessController.self) private var mobileAccess
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(ProjectStore.self) private var store

    var body: some View {
        let shared = mobileAccess.share(for: .everything) != nil
        let connected = mobileAccess.isLive(.everything)
        PhonePill(link: .of(shared: shared, connected: connected),
                  label: tooltip(shared: shared, connected: connected)) {
            MobilePairing.open(scope: .everything, dialogs: dialogs, store: store)
        }
    }

    private func tooltip(shared: Bool, connected: Bool) -> String {
        if connected { return "Phone connected" }
        if shared { return "Shared with a phone" }
        return "Open Code Station on a phone"
    }
}

// A bordered pill that says "Open on phone" while nothing is shared, and lets a peek card
// explain what that means. Once a code is out it fills amber and says it is waiting, and
// once a phone joins it turns green with a slow ring around its light.
private struct PhonePill: View {
    let link: PhoneLink
    let label: String
    let action: () -> Void

    @State private var hovering = false
    @State private var anchor = FrameAnchor()
    @FocusState private var focused: Bool

    static let offer = "Open on phone"

    var body: some View {
        let offering = link == .none
        return Button(action: action) {
            HStack(spacing: 8) {
                lead
                Text(link.word ?? Self.offer)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(offering ? Theme.accent : link.tint)
            .padding(.leading, offering ? 11 : 12)
            .padding(.trailing, 14)
            .frame(height: 32)
            .background(Capsule().fill(link.fill ?? Theme.card))
            .overlay {
                if offering {
                    Capsule().stroke(lit ? Theme.accent.opacity(0.4) : Theme.settingsBorder)
                }
            }
            .shadow(color: Theme.accent.opacity(offering && lit ? 0.1 : 0), radius: 5, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(PressablePill())
        .focused($focused)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: lit)
        .motion(HeaderMotion.slide, value: link)
        .appTooltip(delay: .zero, isFocused: focused && offering) {
            if offering {
                Tooltip(title: "", hanging: Tooltip.Hanging(
                    width: PhonePeek.width,
                    edges: peekEdges,
                    content: AnyView(PhonePeek())))
            } else {
                Tooltip(title: label, subtitle: "Show the code or stop sharing")
            }
        }
        .background(FrameAnchorView(anchor: anchor))
        .accessibilityLabel(label)
        .accessibilityValue(link.word ?? "Not shared")
    }

    private var lit: Bool { hovering || focused }

    @ViewBuilder
    private var lead: some View {
        switch link {
        case .none:
            Image(systemName: "qrcode")
                .font(.system(size: 12.5, weight: .semibold))
        case .waiting:
            Circle()
                .fill(Theme.attention)
                .frame(width: 6, height: 6)
        case .connected:
            PulsingDot(colour: Theme.addition, size: 6)
        }
    }

    // The pill sits at the right edge of the header, so its card lines up with the pill's
    // right side rather than hanging past the window.
    private var peekEdges: ClosedRange<CGFloat> {
        guard let frame = anchor.frame() else { return 0...PhonePeek.width }
        return (frame.maxX - PhonePeek.width)...frame.maxX
    }
}

// Pressing the pill gives a little under the pointer. The scale is on the label, never on
// the button, since the button carries AppKit-backed hover and tooltip views.
private struct PressablePill: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .motion(Motion.hover, value: configuration.isPressed)
    }
}

// What the Home phone pill offers, shown before anything is shared. The code is only a
// picture of one, blurred, since no code exists until sharing starts.
private struct PhonePeek: View {
    static let width: CGFloat = 280
    static let title = "Take Code Station with you"
    static let message = "Scan a code to watch your sessions and answer them from your phone. Works on the same Wi-Fi."

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let url = URL(string: "https://code-station.invalid/m"),
                   let image = MobilePairingQRCode.image(for: url) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .blur(radius: 2.5)
                        .opacity(0.55)
                }
            }
            .frame(width: 60, height: 60)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(Self.message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }
}

struct MobilePairingView: View {
    private enum ContentState: Equatable {
        case idle(hasFailure: Bool)
        case confirming
        case sharing
    }

    @Environment(MobileAccessController.self) private var mobileAccess
    let scope: MobileScope

    @State private var starting = false
    @State private var confirming = false
    @State private var failure: String?

    var body: some View {
        Group {
            if let share = mobileAccess.share(for: scope) {
                VStack(spacing: 14) {
                    if let image = MobilePairingQRCode.image(for: share.url) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 214, height: 214)
                            .padding(18)
                            .surface(.white, cornerRadius: 12)
                    }

                    HStack(spacing: 7) {
                        Circle()
                            .fill(mobileAccess.isLive(scope) ? Theme.addition : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(mobileAccess.isLive(scope)
                             ? "Phone connected" : "Waiting for the phone")
                            .font(.system(size: 12, weight: .semibold))
                    }

                    Text(share.url.absoluteString)
                        .font(.mono(9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)

                    ActionButton(title: share.isConnected ? "Stop sharing" : "Cancel sharing",
                                 tone: .danger, height: 38, size: 13, fills: true) {
                        mobileAccess.revoke(scope)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
                .transition(.fadeIn)
            } else if confirming {
                confirmation.transition(.fadeIn)
            } else {
                idle.transition(.fadeIn)
            }
        }
        .smoothlyResizes(when: contentState)
    }

    private var idle: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                Text("Sharing is off")
                    .font(.system(size: 13, weight: .semibold))
                Text("Start sharing to create a temporary QR code and allow one phone to connect.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.deletion)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.fadeIn)
            }

            ActionButton(title: starting ? "Starting…" : "Start sharing",
                         tone: .green, height: 38, size: 13, fills: true,
                         action: startSharing)
                .disabled(starting)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    // A code that can browse hands over more than the screen the button was pressed on, so
    // that reach is spelled out once more and has to be agreed to before the code exists.
    private var confirmation: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(Theme.accent)

            VStack(spacing: 4) {
                Text("This code opens more than one session")
                    .font(.system(size: 13, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text(warning)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                ActionButton(title: "Back", tone: .outlined, height: 38, size: 13, fills: true) {
                    confirming = false
                }
                ActionButton(title: "Confirm", tone: .green, height: 38, size: 13, fills: true,
                             action: begin)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var warning: String {
        switch scope {
        case .project:
            "Whoever scans it can browse every session in this project, read what they say and start new ones that run on this Mac. Only scan it on a phone you trust."
        default:
            "Whoever scans it can browse every project, read any session and start new ones anywhere, all running on this Mac. Only scan it on a phone you trust."
        }
    }

    private var contentState: ContentState {
        if mobileAccess.share(for: scope) != nil { return .sharing }
        if confirming { return .confirming }
        return .idle(hasFailure: failure != nil)
    }

    private func startSharing() {
        guard !starting else { return }
        guard !scope.canBrowse else {
            failure = nil
            confirming = true
            return
        }
        begin()
    }

    private func begin() {
        guard !starting else { return }
        starting = true
        confirming = false
        failure = nil
        Task { @MainActor in
            defer { starting = false }
            do {
                _ = try await mobileAccess.startSharing(scope)
            } catch let error as LANServerFailure {
                failure = error.message
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}
