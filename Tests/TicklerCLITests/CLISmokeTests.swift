import Testing
@testable import TicklerCLI

@Test func commandNameIsTickler() {
    #expect(TicklerCommand.configuration.commandName == "tickler")
}
