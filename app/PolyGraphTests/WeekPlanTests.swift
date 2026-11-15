import Foundation
import Testing
@testable import PolyGraph

/// Calendarul săptămânal pe programul demo din sâmbăta 14.11.2026 (07:00, 07:30, 08:00, 13:00, 19:00),
/// cu ora 12:00 ca „acum”.
@MainActor
struct WeekPlanTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest") ?? .current
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 12, _ minute: Int = 0) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)))
    }

    private func schedule() throws -> Schedule {
        try JSONCoding.decoder.decode(Schedule.self, from: ContractFiles.data("fixtures/expected_schedule.json"))
    }

    private func fromilid() throws -> MedicationItem {
        try JSONCoding.decoder.decode(MedicationItem.self, from: ContractFiles.data("fixtures/med_09_fromilid.json"))
    }

    private func plan(doses: [Dose] = [], meds: [MedicationItem] = [], start: Int = 9) throws -> WeekPlan {
        WeekPlan(
            start: try date(start, 0), schedules: ["2026-11-14": try schedule()], doses: doses, meds: meds,
            now: try date(14), calendar: calendar)
    }

    @Test func weekStartsOnMonday() throws {
        let start = WeekPlan.weekStart(of: try date(14), calendar: calendar)
        #expect(PgFormat.isoDay(start, calendar: calendar) == "2026-11-09")
        #expect(WeekPlan.isoDays(from: start, calendar: calendar).first == "2026-11-09")
        #expect(WeekPlan.isoDays(from: start, calendar: calendar).last == "2026-11-15")
        // duminica aparține săptămânii care a început luni
        #expect(PgFormat.isoDay(WeekPlan.weekStart(of: try date(15), calendar: calendar), calendar: calendar) == "2026-11-09")
    }

    @Test func daysRunMondayToSundayWithTodayMarked() throws {
        let days = try plan().days
        #expect(days.map(\.weekday) == PgFormat.weekdays)
        #expect(days.map(\.id).first == "2026-11-09")
        #expect(days.filter(\.isToday).map(\.id) == ["2026-11-14"])
        #expect(days[5].moments.map(\.time) == ["07:00", "07:30", "08:00", "13:00", "19:00"])
        #expect(days[0].moments.isEmpty)
    }

    @Test func statesComeFromTheConfirmedDoses() throws {
        let doses = [
            Dose(medid: "med_05", recordedAt: nil, scheduledAt: try date(14, 7, 0), status: .taken),
            Dose(medid: "med_07", recordedAt: nil, scheduledAt: try date(14, 7, 30), status: .taken),
        ]
        let today = try plan(doses: doses).days[5]
        #expect(today.moments.map(\.state) == [.taken, .partial, .unconfirmed, .upcoming, .upcoming])
        #expect(today.doneCount == 1)
        #expect(today.dueCount == 3)
    }

    @Test func phoneConfirmationsCountBeforeTheyReachTheServer() throws {
        let local = [DoseLog.key(day: "2026-11-14", time: "08:00", medID: "med_02"): DoseStatus.skipped]
        let plan = WeekPlan(
            start: try date(9, 0), schedules: ["2026-11-14": try schedule()], doses: [], local: local, meds: [],
            now: try date(14), calendar: calendar)
        #expect(plan.days[5].moments[2].state == .skipped)
    }

    @Test func aShortCourseShowsWhenItStartsAndEnds() throws {
        let med = try fromilid()
        // Fromilid: 14–20 noiembrie; începe sâmbătă în săptămâna 9–15 și se termină vineri în săptămâna 16–22
        let first = try plan(meds: [med]).changes
        #expect(first.map(\.kind) == [.starts])
        #expect(first.first?.text.hasPrefix("Fromilid: începe sâmbătă, 14") == true)
        let second = try plan(meds: [med], start: 16).changes
        #expect(second.map(\.kind) == [.ends])
        #expect(second.first?.text.hasPrefix("Fromilid: ultima zi vineri, 20") == true)
    }
}
