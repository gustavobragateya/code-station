import ServiceManagement
import SwiftUI

// Whether macOS launches the app when the user logs in. The system owns this state, so
// it is read back from the service rather than stored by us.
@MainActor
@Observable
final class LoginItem {
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    private(set) var failure: String?

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    // Registering only works for an app bundle, so a binary run straight from the build
    // folder gets an error here rather than a toggle that silently does nothing.
    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        refresh()
    }
}

// What the app itself does, as opposed to what a session runs with. It is observed
// rather than read from UserDefaults where it is needed, so the sidebar's offer to clear
// old sessions follows the threshold the moment it is changed.
@MainActor
@Observable
final class AppSettings {
    var changesDiffLayout = DiffLayout.unified
    private let agentAvatarURL: URL
    @ObservationIgnored private let preferences: UserDefaults

    var sidebarSessionLimit: Int {
        didSet {
            let resolved = SidebarSessionVisibility.resolvedLimit(sidebarSessionLimit)
            guard resolved == sidebarSessionLimit else {
                sidebarSessionLimit = resolved
                return
            }
            Preferences.setSidebarSessionLimit(sidebarSessionLimit, in: preferences)
        }
    }

    var oldSessionDays: Int {
        didSet { Preferences.setOldSessionDays(oldSessionDays, in: preferences) }
    }

    var oldSessionCleanupPolicy: OldSessionCleanupPolicy {
        didSet {
            Preferences.setOldSessionCleanupPolicy(oldSessionCleanupPolicy, in: preferences)
        }
    }

    var sessionMemoryLimit: SessionMemoryLimit {
        didSet { Preferences.setSessionMemoryLimit(sessionMemoryLimit, in: preferences) }
    }

    var autoPruneOrphanedWorktrees: Bool {
        didSet {
            Preferences.setAutoPruneOrphanedWorktrees(autoPruneOrphanedWorktrees,
                                                      in: preferences)
        }
    }

    var skillsRefreshInterval: SkillsRefreshInterval {
        didSet {
            Preferences.setSkillsRefreshInterval(skillsRefreshInterval, in: preferences)
        }
    }

    var projectSort: ProjectSort {
        didSet { Preferences.setProjectSort(projectSort, in: preferences) }
    }

    var projectGrouping: ProjectGrouping {
        didSet { Preferences.setProjectGrouping(projectGrouping, in: preferences) }
    }

    // Which app a shell opens in when it opens in a window of its own. nil means no app
    // was picked, so the drawer inside this app is what the terminal button offers first.
    var terminalBundleID: String? {
        didSet { Preferences.setTerminalBundleID(terminalBundleID, in: preferences) }
    }

    var opensTerminalInDrawer: Bool { terminalBundleID == nil }

    var appearance: Appearance {
        didSet {
            Preferences.setAppearance(appearance, in: preferences)
            appearance.apply()
        }
    }

    var sidebarIconSet: SidebarIconSet {
        didSet {
            Preferences.setSidebarIconSet(sidebarIconSet, in: preferences)
        }
    }

    var opensWorkingSetByDefault: Bool {
        didSet {
            Preferences.setOpensWorkingSetByDefault(opensWorkingSetByDefault,
                                                    in: preferences)
        }
    }

    var diceBearAvatarStyle: DiceBearAvatarStyle {
        didSet {
            Preferences.setDiceBearAvatarStyle(diceBearAvatarStyle, in: preferences)
        }
    }

    var textSize: TextSize {
        didSet { Preferences.setTextSize(textSize, in: preferences) }
    }

    var messageColour: MessageColour {
        didSet { Preferences.setMessageColour(messageColour, in: preferences) }
    }

    var mobileAccessEnabled: Bool {
        didSet { Preferences.setMobileAccessEnabled(mobileAccessEnabled, in: preferences) }
    }

    var sessionRecapsEnabled: Bool {
        didSet {
            Preferences.setSessionRecapsEnabled(sessionRecapsEnabled, in: preferences)
        }
    }

    var sessionTitlesEnabled: Bool {
        didSet {
            Preferences.setSessionTitlesEnabled(sessionTitlesEnabled, in: preferences)
        }
    }

    var promptSuggestionsEnabled: Bool {
        didSet {
            Preferences.setPromptSuggestionsEnabled(promptSuggestionsEnabled, in: preferences)
        }
    }

    // The Design ambition a session follows until it picks its own.
    var designAmbition: DesignAmbition {
        didSet { Preferences.setDesignAmbition(designAmbition, in: preferences) }
    }

    var sessionFinishedSound: SessionSound {
        didSet {
            Preferences.setSessionFinishedSound(sessionFinishedSound, in: preferences)
        }
    }

    // Whether the money a session has spent is on screen, one answer per agent. The
    // choice sits with the agent because only some CLIs report a cost at all.
    private var costShown: [AgentKind: Bool]

    private(set) var agentAvatars: [AgentAvatar]
    private(set) var defaultAgentAvatarName: String
    private(set) var hasCompletedOnboarding: Bool

    init(agentAvatarURL: URL = AppPaths.supportFile("agent-avatar.png"),
         preferences: UserDefaults = .standard) {
        self.agentAvatarURL = agentAvatarURL
        self.preferences = preferences
        oldSessionDays = Preferences.oldSessionDays(in: preferences)
        oldSessionCleanupPolicy = Preferences.oldSessionCleanupPolicy(in: preferences)
        autoPruneOrphanedWorktrees = Preferences.autoPruneOrphanedWorktrees(in: preferences)
        sessionMemoryLimit = Preferences.sessionMemoryLimit(in: preferences)
        sidebarSessionLimit = Preferences.sidebarSessionLimit(in: preferences)
        skillsRefreshInterval = Preferences.skillsRefreshInterval(in: preferences)
        projectSort = Preferences.projectSort(in: preferences)
        projectGrouping = Preferences.projectGrouping(in: preferences)
        terminalBundleID = Preferences.terminalBundleID(in: preferences)
        appearance = Preferences.appearance(in: preferences)
        sidebarIconSet = Preferences.sidebarIconSet(in: preferences)
        opensWorkingSetByDefault = Preferences.opensWorkingSetByDefault(in: preferences)
        diceBearAvatarStyle = Preferences.diceBearAvatarStyle(in: preferences)
        textSize = Preferences.textSize(in: preferences)
        messageColour = Preferences.messageColour(in: preferences)
        mobileAccessEnabled = Preferences.mobileAccessEnabled(in: preferences)
        sessionRecapsEnabled = Preferences.sessionRecapsEnabled(in: preferences)
        sessionTitlesEnabled = Preferences.sessionTitlesEnabled(in: preferences)
        promptSuggestionsEnabled = Preferences.promptSuggestionsEnabled(in: preferences)
        sessionFinishedSound = Preferences.sessionFinishedSound(in: preferences)
        designAmbition = Preferences.designAmbition(in: preferences)
        hasCompletedOnboarding = Preferences.hasCompletedOnboarding(in: preferences)
        costShown = Dictionary(uniqueKeysWithValues: AgentKind.allCases.map {
            ($0, Preferences.showCost(for: $0, in: preferences))
        })
        let avatars = AgentAvatarFile.loadAll(from: agentAvatarURL)
        let preferredName = Preferences.defaultAgentAvatarName(in: preferences)
        agentAvatars = avatars
        defaultAgentAvatarName = AgentAvatarSelection.resolvedName(
            preferredName,
            availableNames: avatars.map { $0.url.lastPathComponent })
        if preferredName != defaultAgentAvatarName {
            Preferences.setDefaultAgentAvatarName(defaultAgentAvatarName, in: preferences)
        }
    }

    func resetAppearance() {
        appearance = .system
        textSize = .standard
        messageColour = .projectIcon
        diceBearAvatarStyle = .waves
        sidebarIconSet = .diceBear
        opensWorkingSetByDefault = false
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        Preferences.setHasCompletedOnboarding(true, in: preferences)
    }

    func shouldShowOnboarding(hasExistingWork: Bool) -> Bool {
        guard !hasCompletedOnboarding else { return false }
        // A populated project store proves the app has already been used, even when an
        // older build had no onboarding preference to save.
        guard !hasExistingWork else {
            completeOnboarding()
            return false
        }
        return true
    }

    func showsCost(for agent: AgentKind) -> Bool { costShown[agent] ?? true }

    func setShowsCost(_ shown: Bool, for agent: AgentKind) {
        costShown[agent] = shown
        Preferences.setShowCost(shown, for: agent, in: preferences)
    }

    func importAgentAvatars(from urls: [URL], personality: AgentPersonality = .standard) throws {
        add(try AgentAvatarFile.importImages(
            from: urls,
            to: agentAvatarURL,
            personality: personality))
    }

    func addStockAgentAvatar(personality: AgentPersonality) throws {
        add(try AgentAvatarFile.addStockPicture(
            personality: personality,
            to: agentAvatarURL))
    }

    private func add(_ avatars: [AgentAvatar]) {
        agentAvatars.append(contentsOf: avatars)
    }

    func setPersonality(_ personality: AgentPersonality, for avatar: AgentAvatar) throws {
        let updated = try AgentAvatarFile.setPersonality(
            personality, for: avatar, baseURL: agentAvatarURL)
        guard let index = agentAvatars.firstIndex(where: { $0.id == avatar.id }) else { return }
        agentAvatars[index] = updated
    }

    func saveBot(_ draft: BotDraft) throws {
        let saved = try AgentAvatarFile.save(personality: draft.personality, picture: draft.picture,
                                             photoData: draft.photoData, replacing: draft.avatar,
                                             to: agentAvatarURL)
        if let index = agentAvatars.firstIndex(where: { $0.id == saved.id }) {
            agentAvatars[index] = saved
        } else {
            agentAvatars.append(saved)
        }
        if draft.isDefault {
            setDefaultAgentAvatarName(saved.url.lastPathComponent)
        } else if defaultAgentAvatarName == saved.url.lastPathComponent {
            setDefaultAgentAvatarName(AgentAvatarSelection.defaultName)
        }
    }

    func removeAgentAvatar(_ avatar: AgentAvatar) throws {
        defer { reloadAgentAvatars() }
        try AgentAvatarFile.remove(at: avatar.url, from: agentAvatarURL)
    }

    func removeAgentAvatars() throws {
        defer { reloadAgentAvatars() }
        try AgentAvatarFile.removeAll(from: agentAvatarURL)
    }

    // Removing an avatar can take the chosen default with it, so the list and the default
    // are read back together and the built-in bot takes over when needed.
    private func reloadAgentAvatars() {
        agentAvatars = AgentAvatarFile.loadAll(from: agentAvatarURL)
        let resolvedDefault = AgentAvatarSelection.resolvedName(
            defaultAgentAvatarName,
            availableNames: agentAvatars.map { $0.url.lastPathComponent })
        if resolvedDefault != defaultAgentAvatarName {
            setDefaultAgentAvatarName(resolvedDefault)
        }
    }

    func setDefaultAgentAvatarName(_ name: String) {
        guard name == AgentAvatarSelection.defaultName
                || agentAvatars.contains(where: { $0.url.lastPathComponent == name }) else {
            return
        }
        defaultAgentAvatarName = name
        Preferences.setDefaultAgentAvatarName(name, in: preferences)
    }
}

// Settings is a setup job rather than somewhere to sit, so it is a sheet over the
// window, the way the MCP config manager is.
struct SettingsView: View {
    @Environment(LoginItem.self) private var loginItem
    @Environment(ProjectStore.self) private var store
    @Environment(SessionRunner.self) private var runner
    @Environment(AppSettings.self) private var settings
    @Environment(DialogPresenter.self) private var dialogs
    @Environment(\.dismiss) private var dismiss

    let skills: SkillsManager

    @State private var reviewingOldSessions = false
    @State private var showingLog = false
    @State private var tab = SettingsTab.general
    @State private var searchText = ""
    @State private var searchTarget: SettingsSearchTarget?
    @State private var searchResultID: String?
    @State private var searchedAgent: AgentKind?
    @State private var bots = BotSettingsFlow()
    @State private var appearanceBeforeReset: (
        appearance: Appearance, textSize: TextSize, messageColour: MessageColour,
        iconStyle: DiceBearAvatarStyle, iconSet: SidebarIconSet, workingSet: Bool)?
    @FocusState private var searchFocused: Bool
    // Ties the seat under the chosen pane to whichever row holds it, so picking another
    // pane slides the same shape down the list instead of redrawing it there.
    @Namespace private var paneSeat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                navigation
                if tab == .appearance && bots.isPresented {
                    BotSettingsView(flow: bots) {
                        navigate(to: .appearance)
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                paneHeading
                                tabContent
                            }
                            .padding(24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.fadeIn)
                        }
                        .scrollIndicators(.visible)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.background)
                        .id(tab)
                        .onChange(of: searchTarget) { _, target in
                            guard let target else { return }
                            Task { @MainActor in
                                await Task.yield()
                                proxy.scrollTo(target.id, anchor: .top)
                            }
                        }
                    }
                }
            }
            if bots.draft == nil { settingsFooter }
        }
        .frame(width: 960, height: 680)
        .background(Theme.background)
        .interactiveDismissDisabled(bots.draft?.isDirty == true)
        .onAppear { loginItem.refresh() }
        .sheet(isPresented: $reviewingOldSessions) {
            OldSessionsView(sessions: OldSessions.reviewable(days: settings.oldSessionDays,
                                                            store: store, runner: runner))
                .appOverlays()
        }
        .sheet(isPresented: $showingLog) { LogView().appOverlays() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppMark()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            Text("Settings")
                .font(.serif(18))
            Spacer(minLength: 0)
            Text("Teya Code Station")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .headerBand()
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Search settings", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($searchFocused)
                    .onChange(of: searchText) { _, query in
                        selectFirstSearchResult(for: query)
                    }
                if searchText.isEmpty {
                    Text("⌘F")
                        .font(.mono(9))
                        .foregroundStyle(.tertiary)
                } else {
                    Button {
                        searchText = ""
                        searchTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .hoverLift(amount: Motion.smallLift)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .fieldSurface(cornerRadius: 9)

            Button { searchFocused = true } label: { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

            if searchText.isBlank {
                VStack(spacing: 4) {
                    ForEach(SettingsTab.allCases, id: \.self) { choice in
                        SettingsNavigationItem(
                            title: choice.title,
                            symbol: choice.symbol,
                            selected: tab == choice,
                            seat: paneSeat) {
                                navigate(to: choice)
                            }
                    }
                }
            } else if searchResults.isEmpty {
                Text("No settings found")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(searchResults) { result in
                            SettingsSearchResultItem(
                                result: result,
                                selected: searchResultID == result.id) {
                                    select(result)
                                }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            Spacer(minLength: 16)
        }
        .padding(14)
        .frame(width: 190)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
        }
    }

    // A pane is swapped for another rather than redrawn in place, so the change is made
    // where the animation can see both sides of it.
    private func show(_ change: () -> Void) {
        withAnimation(reduceMotion ? nil : Motion.reveal, change)
    }

    private var searchResults: [SettingsSearchResult] {
        SettingsSearchIndex.results(for: searchText)
    }

    private func selectFirstSearchResult(for query: String) {
        guard let result = SettingsSearchIndex.results(for: query).first else {
            searchTarget = nil
            searchResultID = nil
            return
        }
        select(result)
    }

    private func select(_ result: SettingsSearchResult) {
        bots.leave(using: dialogs) {
            show {
                tab = result.tab
                bots.isPresented = result.target == .appearanceDefaultBot
            }
            searchTarget = result.target
            searchResultID = result.id
            searchedAgent = result.agent
        }
    }

    private func navigate(to destination: SettingsTab) {
        bots.leave(using: dialogs) {
            show { tab = destination; bots.isPresented = false }
            searchTarget = nil
        }
    }

    private func resetAppearance() {
        appearanceBeforeReset = (settings.appearance, settings.textSize, settings.messageColour,
                                 settings.diceBearAvatarStyle, settings.sidebarIconSet, settings.opensWorkingSetByDefault)
        settings.resetAppearance()
    }

    private func undoAppearanceReset() {
        guard let previous = appearanceBeforeReset else { return }
        settings.appearance = previous.appearance
        settings.textSize = previous.textSize
        settings.messageColour = previous.messageColour
        settings.diceBearAvatarStyle = previous.iconStyle
        settings.sidebarIconSet = previous.iconSet
        settings.opensWorkingSetByDefault = previous.workingSet
        appearanceBeforeReset = nil
    }

    private var paneHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tab.title)
                .font(tab == .appearance ? .logo(26) : .serif(26))
            Text(tab.note)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var settingsFooter: some View {
        SheetFooter(dismiss: { bots.leave(using: dialogs) { dismiss() } }) {
            Circle()
                .fill(Theme.dotOn)
                .frame(width: 7, height: 7)
                .background(Circle()
                    .fill(Theme.dotOn.opacity(0.12))
                    .frame(width: 13, height: 13))
                .accessibilityHidden(true)
            Text("Changes save automatically")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            if tab == .appearance && !bots.isPresented {
                InlineLink(title: "Reset Appearance", action: resetAppearance)
                    .padding(.leading, 6)
                if appearanceBeforeReset != nil { InlineLink(title: "Undo reset", action: undoAppearanceReset) }
            }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .general:
            VStack(alignment: .leading, spacing: 20) {
                sidebar.id(SettingsSearchTarget.generalSidebar.id)
                recaps.id(SettingsSearchTarget.generalRecaps.id)
                finishedSound.id(SettingsSearchTarget.generalSound.id)
                oldSessions.id(SettingsSearchTarget.generalOldSessions.id)
                orphanedWorktrees.id(SettingsSearchTarget.generalOrphanedWorktrees.id)
                sessionMemory.id(SettingsSearchTarget.generalSessionMemory.id)
                design.id(SettingsSearchTarget.generalDesign.id)
                skillRefresh.id(SettingsSearchTarget.generalSkills.id)
                system.id(SettingsSearchTarget.generalSystem.id)
            }
            .transition(.fadeIn)
        case .appearance:
            VStack(alignment: .leading, spacing: 20) {
                appearance.id(SettingsSearchTarget.appearanceTheme.id)
                workingSet.id(SettingsSearchTarget.appearanceWorkingSet.id)
                BotSettingsEntry {
                    show { bots.isPresented = true }
                }
                .id(SettingsSearchTarget.appearanceDefaultBot.id)
            }
            .transition(.fadeIn)
        case .keyboard:
            keyboardShortcuts.id(SettingsSearchTarget.keyboardShortcuts.id)
            .transition(.fadeIn)
        case .agents:
            AgentSettingsView(selectedAgent: runner.agent,
                              requestedAgent: searchedAgent)
            .transition(.fadeIn)
        case .advanced:
            VStack(alignment: .leading, spacing: 20) {
                SiteConfigurationSection(skills: skills)
            }
            .transition(.fadeIn)
        case .experimental:
            experimentalFeatures.id(SettingsSearchTarget.experimentalFeatures.id)
            .transition(.fadeIn)
        }
    }

    // Read only. The keys are bound where their action lives, so this is the one place
    // that says out loud what the whole set is.
    private var keyboardShortcuts: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(KeyboardShortcutsReference.groups) { group in
                ChoiceBlock(group.title.uppercased()) {
                    SettingsCard {
                        ForEach(Array(group.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                            if index > 0 { SettingsRowDivider() }
                            KeyboardShortcutRow(shortcut: shortcut)
                        }
                    }
                }
            }
        }
    }

    private var sidebar: some View {
        ChoiceBlock("SIDEBAR") {
            SettingsCard {
                HStack(alignment: .top, spacing: 12) {
                    settingCopy(
                        title: "Sessions shown",
                        detail: "How many recent sessions each project and workspace lists before See more.")
                    Spacer(minLength: 0)
                    OptionMenu(value: "\(settings.sidebarSessionLimit)") {
                        SidebarSessionVisibility.limitRange.map { limit in
                            .item("\(limit)", checked: settings.sidebarSessionLimit == limit) {
                                settings.sidebarSessionLimit = limit
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Sessions shown per sidebar list: \(settings.sidebarSessionLimit)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
        }
    }

    private var recaps: some View {
        @Bindable var settings = settings
        return ChoiceBlock("SESSION RETURN") {
            SettingsCard {
                SettingsToggleRow(
                    "Automatic session recaps",
                    detail: "Creates a short recap after a turn finishes while you are in another session or app. You can still request one manually when this is off.",
                    isOn: $settings.sessionRecapsEnabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
            SettingsCard {
                SettingsToggleRow(
                    "Automatic session titles",
                    detail: "Summarises the conversation into a short title after the first turn finishes. You can still regenerate a title from the session's right-click menu when this is off.",
                    isOn: $settings.sessionTitlesEnabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
            .id(SettingsSearchTarget.generalTitles.id)
            SettingsCard {
                SettingsToggleRow(
                    "Suggest the next prompt",
                    detail: "Offers a likely next prompt above the composer once a turn ends. Claude Code predicts one as part of the turn. Codex and Copilot cannot, so they are asked in a short separate run that costs a little on every turn.",
                    isOn: $settings.promptSuggestionsEnabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
            .id(SettingsSearchTarget.generalSuggestions.id)
        }
    }

    // Picking a sound plays it, so the list can be walked until one is right without a
    // separate preview button next to it.
    private var finishedSound: some View {
        ChoiceBlock("SOUND") {
            SettingsCard {
                HStack(alignment: .top, spacing: 12) {
                    settingCopy(
                        title: "When a session finishes",
                        detail: "Plays once a turn ends, whether or not you are looking at that session.")
                    Spacer(minLength: 0)
                    OptionMenu(value: settings.sessionFinishedSound.title) {
                        SessionSound.allCases.map { sound in
                            .item(sound.title,
                                  checked: settings.sessionFinishedSound == sound) {
                                settings.sessionFinishedSound = sound
                                sound.play()
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Sound when a session finishes: \(settings.sessionFinishedSound.title)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
        }
    }

    // The threshold and cleanup policy are separate choices: one says when a session is
    // old, while the other says what the app may do once the warning hour has passed.
    private var oldSessions: some View {
        @Bindable var settings = settings
        let days = settings.oldSessionDays
        let stale = OldSessions.olderThan(days, in: store.userSessions).count

        return ChoiceBlock("OLD SESSIONS") {
            SettingsCard {
                HStack(alignment: .top, spacing: 12) {
                    settingCopy(
                        title: "Count a session as old after",
                        detail: "Counted from its last turn. The sidebar offers to clear them.")
                    Spacer(minLength: 0)
                    DayField(days: $settings.oldSessionDays)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsRowDivider()

                OptionRow(
                    title: "Review before deleting",
                    detail: "Old sessions stay in the app until you delete them from the review screen.",
                    selected: settings.oldSessionCleanupPolicy == .review) {
                        settings.oldSessionCleanupPolicy = .review
                }

                SettingsRowDivider()

                OptionRow(
                    title: "Delete without asking when nothing would be lost",
                    detail: "After one warning hour, removes sessions with no Design files and no uncommitted worktree changes.",
                    selected: settings.oldSessionCleanupPolicy == .deleteSafe) {
                        settings.oldSessionCleanupPolicy = .deleteSafe
                }

                SettingsRowDivider()

                OptionRow(
                    title: "Delete without asking even when work would be lost",
                    detail: "After one warning hour, removes every old session, including generated Design files and uncommitted worktree changes.",
                    selected: settings.oldSessionCleanupPolicy == .deleteAll,
                    warning: true) {
                        settings.oldSessionCleanupPolicy = .deleteAll
                }

                SettingsRowDivider()

                HStack(spacing: 10) {
                    Text(stale == 0
                         ? "Nothing is older than that right now."
                         : "\(counted(stale, "session")) \(stale == 1 ? "is" : "are") older than that right now.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    InlineLink(title: "Review them…") { reviewingOldSessions = true }
                        .disabled(stale == 0)
                        .opacity(stale == 0 ? 0.4 : 1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
        }
    }

    private var orphanedWorktrees: some View {
        @Bindable var settings = settings
        return ChoiceBlock("ORPHANED WORKTREES") {
            SettingsCard {
                SettingsToggleRow(
                    "Prune automatically",
                    detail: "After one warning hour, removes app-created worktrees that no session owns. Uncommitted changes are lost; branches with unmerged commits are kept.",
                    isOn: $settings.autoPruneOrphanedWorktrees)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
        }
    }

    private var sessionMemory: some View {
        let limit = settings.sessionMemoryLimit
        return ChoiceBlock("SESSION MEMORY") {
            SettingsCard {
                HStack(alignment: .top, spacing: 12) {
                    settingCopy(
                        title: "Stop a turn after it uses",
                        detail: limit.detail().map {
                            "Counted across the agent and everything it starts. Automatic is a quarter of this Mac's memory, currently \($0)."
                        } ?? "Counted across the agent and everything it starts. Raise this for work that needs a large build, lower it to keep more of the Mac free.")
                    Spacer(minLength: 0)
                    OptionMenu(value: limit.title) {
                        SessionMemoryLimit.choices().map { choice in
                            .item(choice.title, checked: limit == choice) {
                                settings.sessionMemoryLimit = choice
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Session memory limit: \(limit.title)")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
        }
    }

    private var design: some View {
        ChoiceBlock("DESIGN") {
            SettingsCard {
                HStack(alignment: .center, spacing: 20) {
                    settingCopy(
                        title: "Ambition",
                        detail: "\(settings.designAmbition.detail) Each Design session can choose its own from the composer.")
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        ForEach(DesignAmbition.allCases) { ambition in
                            ChoicePill(title: ambition.title,
                                       selected: settings.designAmbition == ambition) {
                                settings.designAmbition = ambition
                            }
                            .accessibilityLabel("Design ambition: \(ambition.title)")
                            .accessibilityValue(settings.designAmbition == ambition ? "Selected" : "Not selected")
                        }
                    }
                    .fixedSize()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
        }
    }

    private var skillRefresh: some View {
        ChoiceBlock("SKILLS") {
            SettingsCard {
                HStack(alignment: .top, spacing: 12) {
                    settingCopy(
                        title: "Refresh the skills list",
                        detail: "Checks the marketplace for new versions. You can still refresh it from Skills at any time.")
                    Spacer(minLength: 0)
                    OptionMenu(value: settings.skillsRefreshInterval.title) {
                        SkillsRefreshInterval.allCases.map { interval in
                            .item(interval.title,
                                  checked: settings.skillsRefreshInterval == interval) {
                                settings.skillsRefreshInterval = interval
                            }
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
            }
        }
    }

    private var appearance: some View {
        ChoiceBlock("APPEARANCE") {
            SettingsCard {
                HStack(alignment: .center, spacing: 20) {
                    settingCopy(
                        title: "Theme",
                        detail: "Follow macOS or keep the app in one appearance.")
                        .frame(width: 160, alignment: .leading)

                    HStack(spacing: 9) {
                        ForEach(Appearance.allCases) { choice in
                            SettingsThemeChoice(
                                appearance: choice,
                                selected: settings.appearance == choice) {
                                    settings.appearance = choice
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(14)

                SettingsRowDivider()

                HStack(alignment: .center, spacing: 20) {
                    settingCopy(
                        title: "Session text",
                        detail: "Changes transcripts, diffs, tool output, and terminals.")
                        .frame(width: 160, alignment: .leading)

                    Spacer(minLength: 0)

                    Text("Aa")
                        .font(.serif(22 * settings.textSize.scale, .regular))
                        .frame(width: 36)
                        .accessibilityLabel("Text size preview: \(settings.textSize.label)")
                    HStack(spacing: 4) {
                        ForEach(TextSize.allCases) { size in
                            ChoicePill(title: size.label, selected: settings.textSize == size) {
                                settings.textSize = size
                            }
                            .accessibilityLabel("Session text size: \(size.label)")
                            .accessibilityValue(settings.textSize == size ? "Selected" : "Not selected")
                        }
                    }
                }
                .padding(14)

                SettingsRowDivider()

                HStack(alignment: .center, spacing: 20) {
                    settingCopy(
                        title: "Your messages",
                        detail: "The colour behind what you send in a session.")
                        .frame(width: 160, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        MessageColourPicker(selection: settings.messageColour,
                                            projectTints: previewProjectTints) { colour in
                            settings.messageColour = colour
                        }
                        messageColourNote
                    }
                }
                .padding(14)

                SettingsRowDivider()
                sidebarIcons.id(SettingsSearchTarget.appearanceSidebarIcons.id)
            }
        }
    }

    // The bubble colours the sample projects would get, read the same way the sidebar
    // reads them, so the picker changes with the icon style.
    private var previewProjectTints: [Theme.ProjectTint] {
        Self.previewProjects.map { project in
            SidebarAvatar(subject: .project, id: project.id).identityTint(
                iconSet: settings.sidebarIconSet,
                style: settings.diceBearAvatarStyle,
                name: project.name,
                monogramTint: Theme.projectTint(for: project.name))
        }
    }

    private var messageColourNote: some View {
        HStack(alignment: .top, spacing: 10) {
            if settings.messageColour == .projectIcon {
                HStack(spacing: 3) {
                    ForEach(Self.previewProjects) { project in
                        SidebarIdentityTile(
                            avatar: SidebarAvatar(subject: .project, id: project.id),
                            name: project.name,
                            tint: Theme.projectTint(for: project.name),
                            side: 16)
                    }
                }
                .padding(.top, 1)
                .accessibilityHidden(true)

                Text("Your messages stay Stone, with a bar in the colour of the project's \(Text("sidebar icon").fontWeight(.semibold).foregroundStyle(.primary)) on the side you write from. Switching icon style changes the bar too.")
            } else {
                Text("Every session uses \(Text(settings.messageColour.label).fontWeight(.semibold).foregroundStyle(.primary)), whatever the project.")
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Theme.sunken, cornerRadius: 9, border: Theme.settingsHairline)
        .accessibilityElement(children: .combine)
    }

    private var workingSet: some View {
        @Bindable var settings = settings
        return ChoiceBlock("SESSION LAYOUT") {
            SettingsCard {
                SettingsToggleRow(
                    "Open working set automatically",
                    detail: "Opens the Working Set when an agent starts work in a session with no saved panel choice. Opening or closing it yourself is remembered.",
                    isOn: $settings.opensWorkingSetByDefault)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
        }
    }

    private var sidebarIcons: some View {
        HStack(spacing: 20) {
            settingCopy(title: "Sidebar icons", detail: "Give projects a distinct, recognisable look.")
                .frame(width: 160, alignment: .leading)
            HStack(spacing: 12) {
                ForEach(Self.previewProjects.prefix(3)) { project in
                    VStack(spacing: 5) {
                        SidebarIdentityTile(avatar: SidebarAvatar(subject: .project, id: project.id),
                                            name: project.name, tint: Theme.projectTint(for: project.name), side: 26)
                        Text(project.name).font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sidebar icon preview")
            .accessibilityValue(sidebarIconStyleLabel)
            Spacer(minLength: 0)
            OptionMenu(value: sidebarIconStyleLabel) { sidebarIconStyleMenu }
                .accessibilityLabel("Sidebar icon style: \(sidebarIconStyleLabel)")
        }
        .padding(14)
    }

    private var sidebarIconStyleLabel: String {
        switch settings.sidebarIconSet {
        case .monograms: "Monogram"
        case .diceBear: settings.diceBearAvatarStyle.label
        }
    }

    private var sidebarIconStyleMenu: [MenuEntry] {
        var entries: [MenuEntry] = [
            .item("Monogram", image: sidebarIconMonogramImage, imageShape: .tile,
                  checked: settings.sidebarIconSet == .monograms) {
                settings.sidebarIconSet = .monograms
            },
        ]
        entries.append(contentsOf:
            DiceBearAvatarStyle.allCases.map { style in
                .item(style.label,
                      image: SidebarAvatar.preview.artworkImage(style: style),
                      imageShape: .tile,
                      checked: settings.sidebarIconSet == .diceBear
                        && settings.diceBearAvatarStyle == style) {
                    settings.diceBearAvatarStyle = style
                    settings.sidebarIconSet = .diceBear
                }
            })
        return entries
    }

    private var sidebarIconMonogramImage: NSImage? {
        let name = "atlas-web"
        let renderer = ImageRenderer(content: ProjectTileView(
            name: name,
            tint: Theme.projectTint(for: name),
            side: 22))
        renderer.scale = 2
        return renderer.nsImage
    }

    // Fixed examples keep repository names and paths out of settings screenshots.
    private static let previewProjects = [
        Project(id: UUID(uuidString: "5A3B0000-0000-4000-8000-000000000001")!,
                name: "atlas-web", path: "~/Developer/atlas-web"),
        Project(id: UUID(uuidString: "5A3B0000-0000-4000-8000-000000000002")!,
                name: "orbit-api", path: "~/Developer/orbit-api"),
        Project(id: UUID(uuidString: "5A3B0000-0000-4000-8000-000000000003")!,
                name: "harbor-mobile", path: "~/Developer/harbor-mobile"),
        Project(id: UUID(uuidString: "5A3B0000-0000-4000-8000-000000000004")!,
                name: "summit-infra", path: "~/Developer/summit-infra"),
    ]

    // MARK: - Terminal

    private var system: some View {
        ChoiceBlock("SYSTEM") {
            SettingsCard {
                terminal
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                SettingsRowDivider()
                startAtLogin
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
                SettingsRowDivider()
                log
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
        }
    }

    private var terminal: some View {
        // Reading the stored choice here is what ties this row to the setting, so the words
        // change the moment a different terminal is picked.
        let inDrawer = settings.opensTerminalInDrawer
        let value = inDrawer ? SystemTerminal.drawerName : SystemTerminal.appName

        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Terminal")
                    .font(.system(size: 13, weight: .semibold))
                Text(inDrawer
                     ? "The Terminal button offers a shell in the drawer and one in a window of its own. The drawer is named first, and a window opens in \(SystemTerminal.appName), the app macOS hands shell scripts. Pick an app to name it first instead."
                     : "The Terminal button offers a shell in the drawer and one in a window of its own. \(value) is named first, and is where a window opens.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            OptionMenu(value: value) { terminalMenu }
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Terminal: \(value)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var terminalMenu: [MenuEntry] {
        var entries: [MenuEntry] = [
            .item(SystemTerminal.drawerName,
                  icon: "terminal",
                  checked: settings.opensTerminalInDrawer,
                  subtitle: "A shell in the drawer, beside what you were reading.") {
                settings.terminalBundleID = nil
            },
            .separator
        ]
        entries.append(contentsOf: SystemTerminal.installed.compactMap { url in
            guard let id = SystemTerminal.bundleID(of: url) else { return nil }
            return .item(SystemTerminal.name(of: url),
                         image: NSWorkspace.shared.icon(forFile: url.path),
                         checked: settings.terminalBundleID == id) {
                settings.terminalBundleID = id
            }
        })
        entries.append(.separator)
        entries.append(.item("Choose…", icon: "folder") { chooseTerminal() })
        return entries
    }

    // The list only holds apps that say they run shell scripts, and not every terminal
    // says so, so there is a way to name one the list never offered.
    private func chooseTerminal() {
        guard let url = FilePicker.chooseFile(prompt: "Choose",
                                              message: "Pick the terminal to open a shell in.",
                                              types: [.application],
                                              directory: URL(fileURLWithPath: "/Applications"))
        else { return }

        guard let id = SystemTerminal.bundleID(of: url) else {
            dialogs.show(.notice(
                "Could not use that app",
                message: "\(SystemTerminal.name(of: url)) does not look like an application macOS can open."))
            return
        }
        settings.terminalBundleID = id
    }

    private var startAtLogin: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsToggleRow(
                "Start at login",
                detail: "Opens Teya Code Station when you log in, so sessions are there waiting.",
                isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))

            if let failure = loginItem.failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.deletion)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var experimentalFeatures: some View {
        @Bindable var settings = settings
        return ChoiceBlock("EXPERIMENTAL") {
            SettingsCard {
                SettingsToggleRow(
                    "Mobile access",
                    detail: "Puts a QR code on Home. A phone on the same trusted Wi-Fi that scans it can read and run every session in every project.",
                    isOn: $settings.mobileAccessEnabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 13)
            }
        }
    }

    private func settingCopy(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // A turn that stops moving looks the same as one that is working, and the transcript
    // keeps no record of the difference. This is where that record is.
    private var log: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Session log")
                    .font(.system(size: 13, weight: .semibold))
                Text("Every line Claude Code sent, and what the app did with it. Worth opening when a turn seems stuck.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            InlineLink(title: "Open") { showingLog = true }
            InlineLink(title: "Reveal") { SessionLog.revealInFinder() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsNavigationItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let seat: Namespace.ID
    let action: () -> Void

    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .scaleEffect(selected ? 1 : 0.1)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.card)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
                        .matchedGeometryEffect(id: "pane", in: seat)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.card.opacity(0.5))
                }
            }
            .overlay {
                if focused {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.accent, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovering = $0 }
        .motion(Motion.hover, value: hovering)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct SettingsSearchResultItem: View {
    let result: SettingsSearchResult
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: result.tab.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                    Text(result.tab.title)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .surface(selected ? Theme.card : .clear, cornerRadius: 9,
                     border: selected ? Theme.border : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(cornerRadius: 9)
    }
}

// Each colour is shown as a small bubble wearing it, so the choice is judged by the thing
// it changes. The arrow keys step through the colours like a radio group.
private struct MessageColourPicker: View {
    let selection: MessageColour
    let projectTints: [Theme.ProjectTint]
    let choose: (MessageColour) -> Void

    @FocusState private var focused: MessageColour?

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MessageColour.allCases) { colour in
                choice(colour)
            }
        }
        .onMoveCommand { direction in
            let step = switch direction {
            case .left, .up: -1
            case .right, .down: 1
            @unknown default: 0
            }
            let all = MessageColour.allCases
            guard step != 0, let index = all.firstIndex(of: focused ?? selection) else { return }
            let next = all[(index + step + all.count) % all.count]
            choose(next)
            focused = next
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your message colour")
    }

    private func choice(_ colour: MessageColour) -> some View {
        let selected = selection == colour
        let isFocused = focused == colour
        return Button { choose(colour) } label: {
            VStack(spacing: 7) {
                MessageColourMiniBubble(colour: colour, projectTints: projectTints)
                Text(colour.label)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 8)
            .padding(.bottom, 7)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.sunken : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Theme.accent, lineWidth: isFocused ? 2 : 1.5)
                .opacity(selected || isFocused ? 1 : 0))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .hoverLift()
        .focused($focused, equals: colour)
        .accessibilityLabel("\(colour.label) message colour")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct MessageColourMiniBubble: View {
    let colour: MessageColour
    let projectTints: [Theme.ProjectTint]

    private let shape = UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8,
                                               bottomTrailingRadius: 3, topTrailingRadius: 8)

    var body: some View {
        let style = colour.style(projectTint: projectTints.first)
        style.fill
            .overlay(alignment: .trailing) { edge }
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().frame(width: 30, height: 3)
                    Capsule().frame(width: 20, height: 3)
                }
                .foregroundStyle(Color.primary.opacity(0.16))
                .padding(.leading, 8)
                .padding(.top, 8)
                .environment(\.colorScheme, style.inverts ? inverted : scheme)
            }
            .frame(width: 52, height: 26)
            .clipShape(shape)
            .overlay(shape.stroke(style.ring))
            .accessibilityHidden(true)
    }

    @Environment(\.colorScheme) private var scheme
    private var inverted: ColorScheme { scheme == .dark ? .light : .dark }

    // Project icon has no one colour, so its bar is split between the colours the
    // sample projects would get.
    @ViewBuilder private var edge: some View {
        if colour == .projectIcon {
            VStack(spacing: 0) {
                ForEach(Array(projectTints.enumerated()), id: \.offset) { _, tint in
                    UserMessageStyle.tinted(tint.colour).edge
                }
            }
            .frame(width: 3.5)
        }
    }
}

private struct SettingsThemeChoice: View {
    let appearance: Appearance
    let selected: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                SettingsThemePreview(appearance: appearance)
                    .frame(height: 44)
                    .accessibilityHidden(true)

                HStack(spacing: 6) {
                    Text(appearance.label)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .opacity(selected ? 1 : 0)
                }
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(Theme.field)
            }
            .frame(maxWidth: .infinity)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(focused || selected ? Theme.accent : Theme.border,
                        lineWidth: focused ? 2 : selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverLift()
        .focused($focused)
        .accessibilityLabel("\(appearance.label) theme")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct SettingsThemePreview: View {
    let appearance: Appearance

    var body: some View {
        switch appearance {
        case .system:
            HStack(spacing: 0) {
                preview(dark: false)
                preview(dark: true)
            }
        case .light:
            preview(dark: false)
        case .dark:
            preview(dark: true)
        }
    }

    private func preview(dark: Bool) -> some View {
        ZStack {
            (dark ? Color(red: 0.082, green: 0.082, blue: 0.067)
                  : Color(red: 0.969, green: 0.957, blue: 0.918))

            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(dark
                          ? Color(red: 0.18, green: 0.18, blue: 0.16)
                          : Color(red: 0.91, green: 0.90, blue: 0.85))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(dark ? Color.white.opacity(0.15) : Color.black.opacity(0.12))
                        .frame(maxWidth: .infinity, minHeight: 7)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(dark
                              ? Color(red: 0.58, green: 0.76, blue: 0.60).opacity(0.55)
                              : Theme.accentFill.opacity(0.32))
                        .frame(maxWidth: .infinity, minHeight: 7)
                }
            }
            .padding(7)
            .surface(dark
                     ? Color(red: 0.125, green: 0.122, blue: 0.114)
                     : Color(red: 1, green: 0.992, blue: 0.965),
                     cornerRadius: 5,
                     border: dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1))
            .padding(7)
        }
    }
}

private struct DayField: View {
    @Binding var days: Int

    private var value: Binding<Int> {
        Binding(
            get: { days },
            set: { days = OldSessions.resolvedDays($0) }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("Days", value: value, format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 36)
                .accessibilityLabel("Old session age in days")
            Text(days == 1 ? "day" : "days")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .fieldSurface(cornerRadius: 9)
    }
}

enum SettingsSearchTarget: String, Hashable {
    case generalSidebar
    case generalRecaps
    case generalTitles
    case generalSuggestions
    case generalSound
    case generalOldSessions
    case generalOrphanedWorktrees
    case generalSessionMemory
    case generalDesign
    case generalSkills
    case generalSystem
    case appearanceTheme
    case appearanceWorkingSet
    case appearanceSidebarIcons
    case appearanceDefaultBot
    case keyboardShortcuts
    case agentDefault
    case agentConfigure
    case agentDetails
    case agentUsage
    case agentModel
    case agentEffort
    case agentPermissions
    case agentCost
    case agentFiles
    case advancedConfiguration
    case advancedReset
    case experimentalFeatures

    var id: String { rawValue }
}

struct SettingsSearchResult: Identifiable, Equatable {
    let title: String
    let tab: SettingsTab
    let target: SettingsSearchTarget
    let keywords: String
    var agent: AgentKind?

    var id: String {
        [tab.title, agent?.title, title].compactMap { $0 }.joined(separator: ":")
    }
}

enum SettingsSearchIndex {
    static let entries = [
        result("Sessions shown", .general, .generalSidebar,
               "sidebar recent project workspace see more limit"),
        result("Automatic session recaps", .general, .generalRecaps,
               "recap catch up return summary conversation finish away manual toggle"),
        result("Automatic session titles", .general, .generalTitles,
               "title name rename regenerate summarise sentence first turn right click manual toggle"),
        result("Suggest the next prompt", .general, .generalSuggestions,
               "suggestion suggest next prompt predict composer follow up autocomplete toggle"),
        result("Session finished sound", .general, .generalSound,
               "sound alert audio chime beep play finish turn ends notification silent off"),
        result("Old sessions", .general, .generalOldSessions,
               "count old after days delete automatically review clear stale design saved work uncommitted"),
        result("Orphaned worktrees", .general, .generalOrphanedWorktrees,
               "git checkout prune automatically no session disk cleanup uncommitted branch"),
        result("Session memory", .general, .generalSessionMemory,
               "limit ram gigabytes gb stop turn protect mac build automatic out of memory"),
        result("Design ambition", .general, .generalDesign,
               "design restrained balanced all out showcase polish bold style canvas default"),
        result("Skills refresh", .general, .generalSkills,
               "skills marketplace refresh versions interval daily"),
        result("Terminal", .general, .generalSystem,
               "system open shell command app"),
        result("Start at login", .general, .generalSystem,
               "system launch log in startup"),
        result("Session log", .general, .generalSystem,
               "system open reveal stuck diagnostics"),
        result("Theme", .appearance, .appearanceTheme,
               "appearance system light dark macos"),
        result("Session text", .appearance, .appearanceTheme,
               "appearance size small regular large transcript diff terminal"),
        result("Your messages", .appearance, .appearanceTheme,
               "appearance colour color bubble prompt sent project icon stone paper lemon leaf ink"),
        result("Open working set automatically", .appearance, .appearanceWorkingSet,
               "appearance session layout panel sidebar default first turn agent closed open"),
        result("Sidebar icons", .appearance, .appearanceSidebarIcons,
               "appearance style monogram dicebear motion still animated"),
        result("Your bots", .appearance, .appearanceDefaultBot,
               "appearance default avatar image personality picture photo add edit remove delete collection crew"),
        result("Keyboard shortcuts", .keyboard, .keyboardShortcuts,
               "keys key command cmd control ctrl option shift escape reference list bindings"),
        result("Back and forward", .keyboard, .keyboardShortcuts,
               "previous next session project workspace history navigate bracket retrace"),
        result("Default agent", .agents, .agentDefault,
               "claude code codex copilot new sessions"),
        result("Configure agent", .agents, .agentConfigure,
               "switch account settings claude code codex copilot"),
        result("Claude Code account", .agents, .agentDetails,
               "connected refresh version plan path sign in login", agent: .claudeCode),
        result("Codex account", .agents, .agentDetails,
               "connected refresh auth version plan path sign in login", agent: .codex),
        result("Claude Code usage", .agents, .agentUsage,
               "limits meters current weekly updated reset", agent: .claudeCode),
        result("Codex usage", .agents, .agentUsage,
               "limits meters current weekly updated reset", agent: .codex),
        result("Copilot account", .agents, .agentDetails,
               "connected refresh github version path sign in login", agent: .copilot),
        result("Copilot usage", .agents, .agentUsage,
               "premium requests github", agent: .copilot),
        result("Model", .agents, .agentModel,
               "default opus sonnet haiku fable sol terra luna auto gpt"),
        result("Effort", .agents, .agentEffort,
               "thinking default low medium high extra max"),
        result("Permissions", .agents, .agentPermissions,
               "accept edits ask risky manual sandbox access"),
        result("Cost", .agents, .agentCost,
               "spent dollars session usage show"),
        result("Agent files", .agents, .agentFiles,
               "claude settings json codex config toml copilot reveal"),
        result("Current configuration", .advanced, .advancedConfiguration,
               "json environments api access credentials oauth shared defaults starter requests mcp presets skills marketplace shortcuts"),
        result("Reset from file", .advanced, .advancedReset,
               "repository url github load choose file restore aspects"),
        result("Mobile access", .experimental, .experimentalFeatures,
               "qr code phone wifi experimental")
    ]

    static func results(for query: String) -> [SettingsSearchResult] {
        let words = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !words.isEmpty else { return [] }
        let phrase = words.joined(separator: " ")
        return entries.enumerated().filter { _, entry in
            let haystack = "\(entry.title) \(entry.tab.title) \(entry.keywords)".lowercased()
            return words.allSatisfy(haystack.contains)
        }
        .sorted { lhs, rhs in
            let leftRank = rank(lhs.element, phrase: phrase, words: words)
            let rightRank = rank(rhs.element, phrase: phrase, words: words)
            return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
        }
        .map(\.element)
    }

    private static func rank(_ entry: SettingsSearchResult,
                             phrase: String,
                             words: [String]) -> Int {
        let title = entry.title.lowercased()
        if title == phrase { return 0 }
        if title.hasPrefix(phrase) { return 1 }
        if title.contains(phrase) { return 2 }
        if words.allSatisfy(title.contains) { return 3 }
        return 4
    }

    private static func result(_ title: String,
                               _ tab: SettingsTab,
                               _ target: SettingsSearchTarget,
                               _ keywords: String,
                               agent: AgentKind? = nil) -> SettingsSearchResult {
        SettingsSearchResult(title: title,
                             tab: tab,
                             target: target,
                             keywords: keywords,
                             agent: agent)
    }
}

enum SettingsTab: CaseIterable, Hashable {
    case general
    case appearance
    case keyboard
    case agents
    case advanced
    case experimental

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .keyboard: "Keyboard"
        case .agents: "Agents"
        case .advanced: "Advanced"
        case .experimental: "Experimental"
        }
    }

    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .appearance: "paintpalette"
        case .keyboard: "keyboard"
        case .agents: "cpu"
        case .advanced: "gearshape"
        case .experimental: "flask"
        }
    }

    var note: String {
        switch self {
        case .general: "Settings for Teya Code Station."
        case .appearance: "Make Code Station comfortable to read and easy to recognise at a glance."
        case .keyboard: "Every key Code Station answers, and what it does."
        case .agents: "Choose an agent and set how it runs."
        case .advanced: "Manage shared configuration and other advanced settings."
        case .experimental: "Try features that are still in development."
        }
    }
}

// The key sits at the trailing edge in a cap of its own, so a column of them reads down
// the card however long the sentence beside it runs.
private struct KeyboardShortcutRow: View {
    let shortcut: KeyboardShortcutHelp

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortcut.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(shortcut.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(shortcut.keys)
                .font(.mono(11, .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .fieldSurface(cornerRadius: 6)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
