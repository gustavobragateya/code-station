import Testing
@testable import MenuBarApp

// The phone line is the only place outside the pairing dialog that says a phone can reach
// the app, so it has to tell a joined phone apart from a code nobody has used yet.
@MainActor
struct SidebarPhoneStatusTests {
    @Test func noSharesShowNoLine() {
        #expect(SidebarPhoneStatus(shared: 0, connected: 0) == nil)
    }

    @Test func aCodeNobodyJoinedIsOnlyShared() throws {
        let status = try #require(SidebarPhoneStatus(shared: 3, connected: 0))

        #expect(!status.isConnected)
        #expect(status.text == "3 shared")
    }

    @Test func everyShareJoinedReadsAsOnPhone() throws {
        let status = try #require(SidebarPhoneStatus(shared: 1, connected: 1))

        #expect(status.isConnected)
        #expect(status.text == "1 on phone")
    }

    @Test func someSharesJoinedSayHowManyOfAll() throws {
        let status = try #require(SidebarPhoneStatus(shared: 3, connected: 1))

        #expect(status.text == "1 of 3 on phone")
    }

    @Test func homeButtonSpeaksBothLines() {
        let value = SidebarBrandBar.accessibilityValue(
            runningCount: 3, phone: SidebarPhoneStatus(shared: 1, connected: 1))

        #expect(value == "3 running sessions, 1 shared with a connected phone")
    }

    @Test func homeButtonSpeaksThePhoneAloneWhenNothingRuns() {
        let value = SidebarBrandBar.accessibilityValue(
            runningCount: 0, phone: SidebarPhoneStatus(shared: 2, connected: 0))

        #expect(value == "2 shared with a phone, none connected")
    }

    @Test func homeButtonSaysNothingWhenIdle() {
        #expect(SidebarBrandBar.accessibilityValue(runningCount: 0, phone: nil) == "")
    }
}
