import Foundation
import Testing
@testable import TicklerCore

struct TriggerTests {
    @Test func parsesEveryForm() {
        #expect(Trigger("merged") == .merged)
        #expect(Trigger(" Pipeline-Green ") == .pipelineGreen)
        #expect(Trigger("pipeline-failed") == .pipelineFailed)
        #expect(Trigger("approved") == .approved)
        #expect(Trigger("jira:done") == .jiraDone)
        #expect(Trigger("JIRA:Done") == .jiraDone)
        #expect(Trigger("jira:In Review") == .jiraStatus("In Review"))
        #expect(Trigger("jira: In Review ") == .jiraStatus("In Review"))
    }

    @Test func rejectsUnknownForms() {
        #expect(Trigger("") == nil)
        #expect(Trigger("green") == nil)
        #expect(Trigger("jira:") == nil)
        #expect(Trigger("jira:  ") == nil)
        #expect(Trigger("jira:a\nb") == nil)
    }

    @Test func rawValueRoundTrips() {
        let all: [Trigger] = [.merged, .pipelineGreen, .pipelineFailed, .approved, .jiraDone, .jiraStatus("In Review")]
        for trigger in all {
            #expect(Trigger(trigger.rawValue) == trigger)
        }
        #expect(Trigger.jiraStatus("In Review").rawValue == "jira:In Review")
    }

    @Test func supportedLinkKinds() {
        #expect(Trigger.merged.supports(.gitlabMR))
        #expect(Trigger.approved.supports(.githubPR))
        #expect(!Trigger.pipelineGreen.supports(.jira))
        #expect(Trigger.jiraDone.supports(.jira))
        #expect(!Trigger.jiraStatus("x").supports(.gitlabMR))
        #expect(!Trigger.merged.supports(.slack))
    }

    @Test func defaultDeadlineSkipsWeekends() {
        // Fixture.now is Thursday 2026-10-01 10:45: Fri 2, Mon 5, Tue 6.
        #expect(Trigger.defaultDeadline(after: Fixture.now, calendar: Fixture.calendar) == Fixture.date("2026-10-06 09:30"))
        #expect(Trigger.defaultDeadline(after: Fixture.date("2026-10-02 18:00"), calendar: Fixture.calendar)
            == Fixture.date("2026-10-07 09:30"))
        #expect(Trigger.defaultDeadline(after: Fixture.date("2026-10-03 12:00"), calendar: Fixture.calendar)
            == Fixture.date("2026-10-07 09:30"))
    }
}
