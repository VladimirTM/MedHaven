import Foundation
import Testing
@testable import PolyGraph

/// Cardul zilei din tab-ul Medicamente: dozele, momentele ratate, momentul următor și ultimul check-in.
@MainActor
struct CaregiverTodayTests {
    private func dose(_ medID: String) -> DoseElement {
        DoseElement(instruction: "", medid: medID, qty: 1, reasons: [])
    }

    private var moments: [Moment] {
        [
            Moment(doses: [dose("a"), dose("b")], label: "Dimineața", time: "08:00"),
            Moment(doses: [dose("c")], label: "Prânz", time: "13:00"),
            Moment(doses: [dose("a"), dose("d")], label: "Seara", time: "20:00"),
        ]
    }

    private func checkIn(_ title: String, at: Date) -> FeedEvent {
        FeedEvent(
            alertid: nil, at: at, body: "", checkinid: "c1", id: UUID().uuidString, medids: [],
            severity: nil, title: title, type: .checkin)
    }

    @Test func countsDosesAndPicksNextMoment() {
        let statuses: [String: DoseStatus] = ["08:00|a": .taken, "08:00|b": .taken]
        let today = CaregiverToday(
            patientName: "Maria Popescu", moments: moments, alerts: [], events: [], nowMinutes: 10 * 60,
            status: { statuses["\($0)|\($1)"] })
        #expect(today.title == "Maria, azi")
        #expect(today.dosesTaken == 2 && today.dosesTotal == 5)
        #expect(today.missedMoments == 0)
        #expect(today.next?.time == "13:00")
        #expect(today.nextLine(medName: { $0.uppercased() }) == "Următoarea: 13:00 · C")
    }

    @Test func momentPastGraceIsMissedNotNext() {
        let today = CaregiverToday(
            patientName: "Maria", moments: moments, alerts: [], events: [], nowMinutes: 16 * 60,
            status: { time, _ in time == "08:00" ? .taken : nil })
        #expect(today.missedMoments == 1)
        #expect(today.missedText == "1 moment ratat")
        #expect(today.next?.time == "20:00")
    }

    @Test func dayEndWhenNothingIsLeft() {
        let done = CaregiverToday(
            patientName: nil, moments: moments, alerts: [], events: [], nowMinutes: 23 * 60,
            status: { _, _ in .taken })
        #expect(done.title == "Azi")
        #expect(done.next == nil)
        #expect(done.dayEndLine == "Toate dozele de azi sunt confirmate")

        let empty = CaregiverToday(
            patientName: "Maria", moments: [], alerts: [], events: [], nowMinutes: 600, status: { _, _ in nil })
        #expect(empty.dayEndLine == nil && empty.dosesTotal == 0)
    }

    @Test func latestCheckInWithSymptoms() {
        let old = checkIn("Maria a raportat: amețeală", at: Date(timeIntervalSince1970: 1_000))
        let new = checkIn("Maria a raportat: amețeală, vânătăi", at: Date(timeIntervalSince1970: 2_000))
        let today = CaregiverToday(
            patientName: "Maria", moments: [], alerts: [], events: [new, old], nowMinutes: 600,
            status: { _, _ in nil })
        #expect(today.lastCheckIn?.at == new.at)
        #expect(today.checkInDetail == "amețeală, vânătăi")
    }
}
