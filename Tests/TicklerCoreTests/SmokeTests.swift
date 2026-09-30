import Testing
@testable import TicklerCore

@Test func bundleIdentifierIsStable() {
    #expect(Tickler.bundleIdentifier == "io.github.pixibixi.tickler")
}
