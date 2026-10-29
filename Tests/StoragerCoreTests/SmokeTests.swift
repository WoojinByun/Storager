import Testing
@testable import StoragerCore

@Test func logSubsystemIsBundleID() {
    #expect(Log.subsystem == "com.wjbyun.Storager")
}
