import Foundation
import Testing
@testable import TicklerCLI
@testable import TicklerCore

@Test func commandNameIsTickler() {
    #expect(TicklerCommand.configuration.commandName == "tickler")
}

struct CompletionTests {
    @Test func candidatesCarryTheTitleForZshAndFish() throws {
        let calendar = Calendar.current
        let due = try #require(calendar.date(from: DateComponents(year: 2030, month: 1, day: 2, hour: 9, minute: 30)))
        let reminder = Reminder(
            id: "abc234", title: "OPS-1: check the MR", notes: "", dueAt: due, originalDueAt: due, rescheduleCount: 0,
            status: .open, sessionId: nil, cwd: nil, source: .human, externalRef: nil, notifiedAt: nil, doneAt: nil,
            createdAt: due, updatedAt: due
        )
        #expect(IDCompletion.candidate(reminder, shell: "zsh") == #"abc234:2030-01-02 09\:30 OPS-1\: check the MR"#)
        #expect(IDCompletion.candidate(reminder, shell: "fish") == "abc234\t2030-01-02 09:30 OPS-1: check the MR")
        #expect(IDCompletion.candidate(reminder, shell: "bash") == "abc234")
    }

    @Test func zshScriptIsPrinted() {
        #expect(TicklerCommand.completionScript(for: .zsh).contains("compdef _tickler tickler"))
    }
}
