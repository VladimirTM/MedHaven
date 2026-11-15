import Foundation

/// O săptămână de tratament, luni–duminică: momentele fiecărei zile (din programul calculat de server pentru
/// ziua aceea), starea lor (luate / sărite / neconfirmate / urmează) și medicamentele care încep sau se termină
/// în săptămână (cure scurte, rețete noi). Pentru tratamentele cronice zilele seamănă; ce contează e ce se
/// schimbă și cum a mers până acum. Aceeași grilă ca pagina familiei de pe web (`/acasa/saptamana`).
struct WeekPlan {
    enum State: Equatable {
        case taken
        case skipped
        /// o parte din dozele momentului confirmate
        case partial
        /// a trecut ora și nu s-a confirmat nimic
        case unconfirmed
        case upcoming

        var text: String {
            switch self {
            case .taken: "Luate"
            case .skipped: "Sărite"
            case .partial: "Parțial"
            case .unconfirmed: "Neconfirmate"
            case .upcoming: "Urmează"
            }
        }

        var systemImage: String {
            switch self {
            case .taken: "checkmark.circle.fill"
            case .skipped: "minus.circle"
            case .partial: "circle.lefthalf.filled"
            case .unconfirmed: "circle"
            case .upcoming: "clock"
            }
        }

        var isDone: Bool { self == .taken || self == .skipped }
    }

    struct Moment: Identifiable {
        /// „2026-11-16T07:30”
        let id: String
        let time: String
        let label: String
        let doses: [DoseElement]
        let state: State
    }

    struct Day: Identifiable {
        /// „2026-11-16”
        let id: String
        let date: Date
        /// „luni”
        let weekday: String
        /// „16”
        let dayNumber: String
        let isToday: Bool
        let isPast: Bool
        let moments: [Moment]

        /// câte momente s-au confirmat din câte au trecut (pentru zilele trecute și azi)
        var doneCount: Int { moments.filter { $0.state.isDone }.count }
        var dueCount: Int { moments.filter { $0.state != .upcoming }.count }
    }

    /// un medicament care începe sau se termină în săptămâna asta
    struct Change: Identifiable {
        enum Kind: Equatable {
            case starts
            case ends
        }

        let id: String
        let medID: String
        let kind: Kind
        /// „Fromilid: ultima zi joi, 19 nov.”
        let text: String
    }

    let start: Date
    let days: [Day]
    let changes: [Change]

    /// „16–22 noiembrie”
    var title: String {
        guard let first = days.first?.date, let last = days.last?.date else { return "" }
        let calendar = Calendar.current
        let month = { (date: Date) in PgFormat.longMonths[max(0, min(11, calendar.component(.month, from: date) - 1))] }
        let d1 = calendar.component(.day, from: first), d2 = calendar.component(.day, from: last)
        return month(first) == month(last) ? "\(d1)–\(d2) \(month(last))" : "\(d1) \(month(first)) – \(d2) \(month(last))"
    }

    /// `schedules`: programul fiecărei zile, de luni până duminică (lipsă = zi neîncărcată, fără momente);
    /// `doses`: dozele confirmate pe server în zilele astea; `local`: confirmările de pe telefon (`DoseLog`),
    /// care pot să nu fi ajuns încă la server.
    init(
        start: Date, schedules: [String: Schedule], doses: [Dose], local: [String: DoseStatus] = [:],
        meds: [MedicationItem], now: Date, calendar: Calendar = .current
    ) {
        self.start = calendar.startOfDay(for: start)
        let today = PgFormat.isoDay(now, calendar: calendar)
        let nowClock = PgFormat.clock(now, calendar: calendar)

        var statuses: [String: DoseStatus] = [:]
        for dose in doses {
            let key = DoseLog.key(
                day: PgFormat.isoDay(dose.scheduledAt, calendar: calendar),
                time: PgFormat.clock(dose.scheduledAt, calendar: calendar), medID: dose.medid)
            statuses[key] = dose.status
        }
        for (key, status) in local { statuses[key] = status }

        let dates = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: start)) }
        let builtDays = dates.map { date -> Day in
            let iso = PgFormat.isoDay(date, calendar: calendar)
            let moments = (schedules[iso]?.moments ?? []).map { moment -> Moment in
                let recorded = moment.doses.map { statuses[DoseLog.key(day: iso, time: moment.time, medID: $0.medid)] }
                    .map { $0 == .pending ? nil : $0 }
                let state: State
                if !recorded.isEmpty && recorded.allSatisfy({ $0 != nil }) {
                    state = recorded.contains(.taken) ? .taken : .skipped
                } else if recorded.contains(where: { $0 != nil }) {
                    state = .partial
                } else if iso < today || (iso == today && moment.time <= nowClock) {
                    state = .unconfirmed
                } else {
                    state = .upcoming
                }
                return Moment(id: "\(iso)T\(moment.time)", time: moment.time, label: moment.label, doses: moment.doses, state: state)
            }
            let weekdayIndex = (calendar.component(.weekday, from: date) + 5) % 7  // 1 = duminică → luni = 0
            return Day(
                id: iso, date: date, weekday: PgFormat.weekdays[weekdayIndex],
                dayNumber: String(calendar.component(.day, from: date)), isToday: iso == today, isPast: iso < today,
                moments: moments)
        }
        days = builtDays

        // ce începe după luni sau se termină până duminică (datele sunt „AAAA-LL-ZZ”, comparabile ca text)
        let first = builtDays.first?.id ?? "", last = builtDays.last?.id ?? ""
        let dayNames = Dictionary(uniqueKeysWithValues: builtDays.map { ($0.id, Self.dayName($0)) })
        var changes: [Change] = []
        for med in meds {
            let name = med.product.brand
            if let starts = med.startDate, starts > first, starts <= last, let when = dayNames[starts] {
                changes.append(Change(id: "\(med.id)-start", medID: med.id, kind: .starts, text: "\(name): începe \(when)"))
            }
            if let ends = med.endDate, ends >= first, ends <= last, let when = dayNames[ends] {
                changes.append(Change(id: "\(med.id)-end", medID: med.id, kind: .ends, text: "\(name): ultima zi \(when)"))
            }
        }
        self.changes = changes
    }

    /// „joi, 19 nov.”
    static func dayName(_ day: Day) -> String {
        let month = Calendar.current.component(.month, from: day.date)
        return "\(day.weekday), \(day.dayNumber) \(PgFormat.shortMonths[max(0, min(11, month - 1))])"
    }

    /// luni din săptămâna datei
    static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: date)
        let offset = (calendar.component(.weekday, from: day) + 5) % 7
        return calendar.date(byAdding: .day, value: -offset, to: day) ?? day
    }

    /// zilele săptămânii, „AAAA-LL-ZZ”, de luni până duminică
    static func isoDays(from start: Date, calendar: Calendar = .current) -> [String] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: start)) }
            .map { PgFormat.isoDay($0, calendar: calendar) }
    }
}

extension PgFormat {
    static let longMonths = [
        "ianuarie", "februarie", "martie", "aprilie", "mai", "iunie", "iulie", "august", "septembrie", "octombrie",
        "noiembrie", "decembrie",
    ]
}
