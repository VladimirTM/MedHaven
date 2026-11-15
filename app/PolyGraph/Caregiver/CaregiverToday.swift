import SwiftUI
import UIKit

/// Rezumatul zilei pentru aparținător, deasupra listei de medicamente: dozele de azi, alertele grave,
/// ultimul check-in și momentul următor. Totul vine din ce are deja telefonul (programul, bifele sincronizate,
/// analiza și Noutăți), fără o cerere nouă la server.
struct CaregiverToday {
    let firstName: String
    let dosesTaken: Int
    let dosesTotal: Int
    /// momente trecute de `SeniorDay.graceMinutes` și neconfirmate
    let missedMoments: Int
    let seriousAlerts: Int
    let lastCheckIn: FeedEvent?
    /// primul moment neconfirmat care încă nu a trecut de perioada de grație
    let next: Moment?

    init(
        patientName: String?,
        moments: [Moment],
        alerts: [Alert],
        events: [FeedEvent],
        nowMinutes: Int,
        status: (_ time: String, _ medID: String) -> DoseStatus?
    ) {
        firstName = patientName?.split(separator: " ").first.map(String.init) ?? ""
        var taken = 0
        var total = 0
        var missed = 0
        var next: Moment?
        for moment in moments {
            let statuses = moment.doses.map { status(moment.time, $0.medid) }
            total += statuses.count
            taken += statuses.filter { $0 == .taken }.count
            let done = !statuses.isEmpty && statuses.allSatisfy { $0 == .taken || $0 == .skipped }
            guard !done, let minutes = SeniorDay.minutes(moment.time) else { continue }
            if nowMinutes > minutes + SeniorDay.graceMinutes {
                missed += 1
            } else if next == nil {
                next = moment
            }
        }
        dosesTaken = taken
        dosesTotal = total
        missedMoments = missed
        self.next = next
        seriousAlerts = AlertSections(alerts).serious.count
        lastCheckIn = events.filter { $0.type == .checkin }.max { $0.at < $1.at }
    }

    var title: String {
        firstName.isEmpty ? "Azi" : "\(firstName) azi"
    }

    /// „fără simptome” / „amețeală, vânătăi”
    var checkInDetail: String? {
        guard let lastCheckIn else { return nil }
        let symptoms = lastCheckIn.symptomLabels
        return symptoms.isEmpty ? "fără simptome" : symptoms.joined(separator: ", ")
    }

    /// „1 moment ratat” / „2 momente ratate”
    var missedText: String? {
        switch missedMoments {
        case 0: nil
        case 1: "1 moment ratat"
        default: "\(missedMoments) momente ratate"
        }
    }

    /// „Următoarea: 13:00 · Simvastatin, Amlodipină”
    func nextLine(medName: (String) -> String?) -> String? {
        guard let next else { return nil }
        var names: [String] = []
        for dose in next.doses {
            if let name = medName(dose.medid), !names.contains(name) { names.append(name) }
        }
        return names.isEmpty ? "Următoarea: \(next.time)" : "Următoarea: \(next.time) · \(names.joined(separator: ", "))"
    }

    /// Ce scrie sub cifre când nu mai urmează nimic azi; `nil` când programul e gol sau mai urmează ceva.
    var dayEndLine: String? {
        guard next == nil, dosesTotal > 0 else { return nil }
        return missedMoments == 0 ? "Toate dozele de azi sunt confirmate" : "Azi nu mai urmează nimic"
    }
}

/// Cardul de sus din tab-ul Medicamente: cine, ce zi, trei cifre (doze, alerte grave, check-in), apoi momentul
/// următor. Fiecare cifră e un buton care duce la tab-ul cu detaliile.
struct CaregiverTodayCard: View {
    let today: CaregiverToday
    let now: Date
    let medName: (String) -> String?
    let open: (CaregiverTab) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var avatar: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            header
            if typeSize.isAccessibilitySize {
                VStack(spacing: Spacing.xs) { tiles }
            } else {
                HStack(alignment: .top, spacing: Spacing.xs) { tiles }
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meds.today")
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Group {
                if let initial = today.firstName.first {
                    Text(String(initial).uppercased())
                } else {
                    Image(systemName: "person.fill")
                }
            }
                .font(.title2.weight(.semibold))
                .foregroundStyle(PgColor.accent)
                .frame(width: avatar, height: avatar)
                .background(PgColor.accent.opacity(0.16), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(today.title)
                    .font(.title3.weight(.semibold))
                Text(PgFormat.longDay(now))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var tiles: some View {
        Button { open(.week) } label: {
            TodayTile(title: "Doze luate") {
                if today.dosesTotal == 0 {
                    Text("–").font(.title2.weight(.semibold))
                    Text("fără program azi").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("\(today.dosesTaken) din \(today.dosesTotal)")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    ProgressView(value: Double(today.dosesTaken), total: Double(today.dosesTotal))
                        .tint(PgColor.accent)
                        .accessibilityHidden(true)
                    if let missed = today.missedText {
                        Text(missed)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(PgColor.warning)
                    }
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityHint("Deschide săptămâna")
        .accessibilityIdentifier("meds.today.doses")

        Button { open(.alerts) } label: {
            let tint = today.seriousAlerts > 0 ? Severity.major.color : nil
            TodayTile(title: "Alerte grave", tint: tint) {
                HStack(spacing: Spacing.xxs) {
                    Text("\(today.seriousAlerts)")
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(tint ?? PgColor.textPrimary)
                if today.seriousAlerts == 0 {
                    Text("nimic grav").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityHint("Deschide alertele")
        .accessibilityIdentifier("meds.today.alerts")

        Button { open(.feed) } label: {
            TodayTile(title: "Check-in") {
                if let checkIn = today.lastCheckIn {
                    Text(PgFormat.relativeDay(checkIn.at, now: now))
                        .font(.headline)
                        .monospacedDigit()
                    if let detail = today.checkInDetail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Încă niciunul").font(.headline)
                }
            }
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityHint("Deschide noutățile")
        .accessibilityIdentifier("meds.today.checkin")
    }

    @ViewBuilder
    private var footer: some View {
        if let line = today.nextLine(medName: medName) {
            Label(line, systemImage: "clock")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("meds.today.next")
        } else if let line = today.dayEndLine {
            Label {
                Text(line).foregroundStyle(.secondary)
            } icon: {
                Image(systemName: today.missedMoments == 0 ? "checkmark.circle.fill" : "moon")
                    .foregroundStyle(today.missedMoments == 0 ? PgColor.accent : .secondary)
            }
            .font(.subheadline)
            .accessibilityIdentifier("meds.today.next")
        }
    }
}

/// O cifră din card: eticheta sus, valoarea dedesubt, pe o suprafață ușor diferită de card.
private struct TodayTile<Content: View>: View {
    let title: String
    var tint: Color?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(tint ?? PgColor.textSecondary)
            content
        }
        .multilineTextAlignment(.leading)
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            tint.map { $0.opacity(0.16) } ?? Color(.tertiarySystemFill),
            in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
