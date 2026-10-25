import Foundation
import Testing
@testable import TicklerCore

private func reminder(
    _ id: String,
    at due: String,
    status: Reminder.Status = .open,
    trigger: String? = nil,
    autoRun: String? = nil
) -> Reminder {
    let date = Fixture.date(due)
    var reminder = Reminder(
        id: id, title: "t", notes: "", dueAt: date, originalDueAt: date, rescheduleCount: 0, status: status,
        sessionId: nil, cwd: nil, source: .claude, externalRef: nil, notifiedAt: nil,
        doneAt: nil, createdAt: Fixture.now, updatedAt: Fixture.now
    )
    reminder.trigger = trigger
    reminder.autoRun = autoRun
    return reminder
}

private let lead: TimeInterval = 15 * 60

/// Fixture.now is 2026-10-01 10:45.
struct IslandPlannerTests {
    @Test func emptyHidesAndNeverWakes() {
        let plan = IslandPlanner.plan(open: [], now: Fixture.now, lead: lead)
        #expect(plan == IslandPlan(shown: nil, othersInWindow: 0, nextChange: nil))
    }

    @Test func beforeTheWindowWakesWhenItEnters() {
        let plan = IslandPlanner.plan(open: [reminder("late01", at: "2026-10-01 11:30")], now: Fixture.now, lead: lead)
        #expect(plan.shown == nil)
        #expect(plan.nextChange == Fixture.date("2026-10-01 11:15"))
    }

    @Test func insideTheWindowShowsUntilFiveMinutesPastDue() {
        let plan = IslandPlanner.plan(open: [reminder("soon01", at: "2026-10-01 10:55")], now: Fixture.now, lead: lead)
        #expect(plan.shown?.id == "soon01")
        #expect(plan.othersInWindow == 0)
        #expect(plan.nextChange == Fixture.date("2026-10-01 11:00"))
    }

    @Test func autoRunRemindersAreNeverShown() {
        let plan = IslandPlanner.plan(
            open: [reminder("auto01", at: "2026-10-01 10:50", autoRun: "read"), reminder("late01", at: "2026-10-01 11:30")],
            now: Fixture.now,
            lead: lead
        )
        #expect(plan.shown == nil)
        #expect(plan.nextChange == Fixture.date("2026-10-01 11:15"))
    }

    @Test func windowEdgesAreIncluded() {
        let edge = IslandPlanner.plan(open: [reminder("edge01", at: "2026-10-01 11:00")], now: Fixture.now, lead: lead)
        #expect(edge.shown?.id == "edge01")
        let grace = IslandPlanner.plan(open: [reminder("edge02", at: "2026-10-01 10:40")], now: Fixture.now, lead: lead)
        #expect(grace.shown?.id == "edge02")
    }

    @Test func dueFourMinutesAgoShowsSixMinutesAgoDoesNot() {
        let recent = IslandPlanner.plan(open: [reminder("now001", at: "2026-10-01 10:41")], now: Fixture.now, lead: lead)
        #expect(recent.shown?.id == "now001")
        #expect(recent.nextChange == Fixture.date("2026-10-01 10:46"))
        let old = IslandPlanner.plan(open: [reminder("old001", at: "2026-10-01 10:39")], now: Fixture.now, lead: lead)
        #expect(old.shown == nil)
        #expect(old.nextChange == nil)
    }

    @Test func waitingTriggerIsExcludedAndDoneToo() {
        let reminders = [
            reminder("wait01", at: "2026-10-01 10:50", trigger: "merged"),
            reminder("done01", at: "2026-10-01 10:50", status: .done),
        ]
        let plan = IslandPlanner.plan(open: reminders, now: Fixture.now, lead: lead)
        #expect(plan == IslandPlan(shown: nil, othersInWindow: 0, nextChange: nil))
    }

    @Test func earliestWinsTiesByIdAndOthersAreCounted() {
        let reminders = [
            reminder("bbbb01", at: "2026-10-01 10:50"),
            reminder("aaaa01", at: "2026-10-01 10:50"),
            reminder("cccc01", at: "2026-10-01 10:58"),
            reminder("dddd01", at: "2026-10-01 12:00"),
        ]
        let plan = IslandPlanner.plan(open: reminders, now: Fixture.now, lead: lead)
        #expect(plan.shown?.id == "aaaa01")
        #expect(plan.othersInWindow == 2)
        #expect(plan.nextChange == Fixture.date("2026-10-01 10:55"))
    }

    @Test func nextEntryCanComeBeforeTheShownOneLeaves() {
        let reminders = [reminder("show01", at: "2026-10-01 10:58"), reminder("next01", at: "2026-10-01 11:10")]
        let plan = IslandPlanner.plan(open: reminders, now: Fixture.now, lead: lead)
        #expect(plan.shown?.id == "show01")
        #expect(plan.nextChange == Fixture.date("2026-10-01 10:55"))
    }

    @Test func leadIsClamped() {
        let far = [reminder("far001", at: "2026-10-01 13:00")]
        #expect(IslandPlanner.plan(open: far, now: Fixture.now, lead: 10 * 3600).shown == nil)
        let close = [reminder("near01", at: "2026-10-01 10:45")]
        #expect(IslandPlanner.plan(open: close, now: Fixture.now, lead: 0).shown?.id == "near01")
        let soon = [reminder("soon01", at: "2026-10-01 10:46")]
        #expect(IslandPlanner.plan(open: soon, now: Fixture.now, lead: 0).shown?.id == "soon01")
    }
}
