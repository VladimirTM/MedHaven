import SwiftUI

/// Calendarul săptămânal: luni–duminică, momentele fiecărei zile cu medicamentele și starea lor, plus ce
/// medicamente încep sau se termină în săptămână. Programul fiecărei zile vine de la server
/// (`GET /schedule?date=`), iar bifele din `GET /doses?date=` și de pe telefon (`DoseLog`).
///
/// La aparținător (tab-ul „Săptămâna”): banda cu cele 7 zile, ziua aleasă dedesubt și navigarea între săptămâni.
/// La pacient (din „Ziua de azi”): doar săptămâna curentă, zi după zi, cu text mare și ziua de azi evidențiată
/// (o grilă de 7 coloane nu se poate citi cu textul mare, 2.4.2).
struct WeekView: View {
    let audience: ShareSheet.Audience

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// luni din săptămâna afișată; `nil` = săptămâna de azi
    @State private var weekStart: Date?
    @State private var schedules: [String: Schedule] = [:]
    @State private var doses: [Dose] = []
    @State private var isLoading = false
    @State private var errorText: String?
    /// ziua aleasă în bandă (aparținător); `nil` = azi sau prima zi
    @State private var selectedDay: String?

    @ScaledMetric(relativeTo: .title) private var seniorTitleSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title2) private var seniorTextSize: CGFloat = 22

    private var isSenior: Bool { audience == .senior }

    private var start: Date {
        weekStart ?? WeekPlan.weekStart(of: store.clock.now)
    }

    private var plan: WeekPlan {
        WeekPlan(
            start: start, schedules: schedules, doses: doses, local: store.doseLog.statuses,
            meds: store.visibleMeds, now: store.clock.now)
    }

    /// se reîncarcă la altă săptămână și la orice schimbare a listei de medicamente
    private var loadKey: String {
        PgFormat.isoDay(start) + "|" + store.visibleMeds.map(\.id).joined(separator: ",")
    }

    var body: some View {
        let plan = plan
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if !isSenior {
                        weekHeader(plan)
                    }

                    if schedules.isEmpty && isLoading {
                        ProgressView("Se încarcă săptămâna…")
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, minHeight: 160)
                            .accessibilityIdentifier("week.loading")
                    } else if schedules.isEmpty, let errorText {
                        errorView(errorText)
                    } else {
                        if !plan.changes.isEmpty {
                            changesCard(plan)
                        }
                        if isSenior {
                            ForEach(plan.days) { day in
                                dayCard(day)
                                    .id(day.id)
                            }
                        } else {
                            dayStrip(plan)
                            if let day = selected(in: plan) {
                                dayCard(day)
                            }
                        }
                    }

                    if isSenior {
                        SeniorButton("Gata", systemImage: "checkmark", prominence: .secondary, identifier: "week.doneButton") {
                            dismiss()
                        }
                    }
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(PgColor.background)
            .navigationTitle("Săptămâna")
            .navigationBarTitleDisplayMode(isSenior ? .inline : .large)
            .refreshable { await load() }
            .task(id: loadKey) {
                await load()
                // la pacient, ziua de azi vine în vedere fără derulare
                if isSenior, let today = self.plan.days.first(where: \.isToday) {
                    proxy.scrollTo(today.id, anchor: .top)
                }
            }
            .accessibilityIdentifier("week.list")
        }
    }

    // MARK: - Încărcarea

    private func load() async {
        guard let id = store.settings.patientID else { return }
        let days = WeekPlan.isoDays(from: start)
        let today = PgFormat.isoDay(store.clock.now)
        isLoading = true
        defer { isLoading = false }
        do {
            var fetchedSchedules: [String: Schedule] = [:]
            var fetchedDoses: [Dose] = []
            for day in days {
                fetchedSchedules[day] = try await store.api.getSchedule(patientID: id, date: day)
                // bife există doar până azi
                if day <= today {
                    fetchedDoses += try await store.api.listDoses(patientID: id, date: day)
                }
            }
            schedules = fetchedSchedules
            doses = fetchedDoses
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "Nu am putut încărca săptămâna."
        }
    }

    private func selected(in plan: WeekPlan) -> WeekPlan.Day? {
        if let selectedDay, let day = plan.days.first(where: { $0.id == selectedDay }) { return day }
        return plan.days.first(where: \.isToday) ?? plan.days.first
    }

    private func move(weeks: Int) {
        let calendar = Calendar.current
        let current = WeekPlan.weekStart(of: store.clock.now)
        let next = calendar.date(byAdding: .day, value: 7 * weeks, to: start) ?? start
        weekStart = calendar.isDate(next, inSameDayAs: current) ? nil : next
        selectedDay = nil
        schedules = [:]
        doses = []
    }

    // MARK: - Antetul (aparținător)

    private func weekHeader(_ plan: WeekPlan) -> some View {
        HStack(spacing: Spacing.s) {
            Button {
                move(weeks: -1)
            } label: {
                Label("Săptămâna trecută", systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("week.prevButton")

            VStack(spacing: 0) {
                Text(plan.title)
                    .font(.headline)
                    .foregroundStyle(PgColor.textPrimary)
                    .accessibilityIdentifier("week.title")
                if weekStart != nil {
                    Button("Înapoi la săptămâna asta") {
                        weekStart = nil
                        selectedDay = nil
                        schedules = [:]
                        doses = []
                    }
                    .font(.footnote)
                    .accessibilityIdentifier("week.todayButton")
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                move(weeks: 1)
            } label: {
                Label("Săptămâna viitoare", systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("week.nextButton")
        }
        .font(.body.weight(.semibold))
    }

    // MARK: - Ce se schimbă

    private func changesCard(_ plan: WeekPlan) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Se schimbă în săptămâna asta")
                .font(isSenior ? Font.system(size: seniorTextSize, weight: .bold) : Font.headline)
                .foregroundStyle(PgColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            ForEach(plan.changes) { change in
                Label(change.text, systemImage: change.kind == .starts ? "play.circle" : "flag.checkered")
                    .font(bodyFont)
                    .foregroundStyle(PgColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("week.change.\(change.id)")
            }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(PgColor.calmCard))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("week.changes")
    }

    // MARK: - Banda cu zilele (aparținător)

    private func dayStrip(_ plan: WeekPlan) -> some View {
        let chosen = selected(in: plan)?.id
        return HStack(spacing: Spacing.xxs) {
            ForEach(plan.days) { day in
                Button {
                    selectedDay = day.id
                } label: {
                    VStack(spacing: Spacing.xxs) {
                        Text(String(day.weekday.prefix(2)))
                            .font(.caption)
                            .foregroundStyle(PgColor.textSecondary)
                        Text(day.dayNumber)
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(PgColor.textPrimary)
                        Image(systemName: stripIcon(day))
                            .font(.caption)
                            .foregroundStyle(day.dueCount > 0 && day.doneCount == day.dueCount ? PgColor.accent : PgColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .fill(chosen == day.id ? PgColor.calmCard : PgColor.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(day.isToday ? PgColor.accent : Color.clear, lineWidth: 2))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(stripAccessibilityLabel(day))
                .accessibilityAddTraits(chosen == day.id ? .isSelected : [])
                .accessibilityIdentifier("week.day.\(day.id)")
            }
        }
    }

    /// bifă = tot ce trebuia până acum e confirmat; jumătate = o parte; cerc gol = nimic; ceas = ziua urmează
    private func stripIcon(_ day: WeekPlan.Day) -> String {
        if day.moments.isEmpty { return "minus" }
        if day.dueCount == 0 { return "clock" }
        if day.doneCount == day.dueCount { return "checkmark.circle.fill" }
        return day.doneCount == 0 ? "circle" : "circle.lefthalf.filled"
    }

    private func stripAccessibilityLabel(_ day: WeekPlan.Day) -> String {
        let name = WeekPlan.dayName(day) + (day.isToday ? ", azi" : "")
        guard day.dueCount > 0 else { return name }
        return "\(name), \(day.doneCount) din \(day.dueCount) momente confirmate"
    }

    // MARK: - O zi

    private var bodyFont: Font {
        isSenior ? Font.system(size: seniorTextSize) : Font.body
    }

    private var cornerRadius: CGFloat {
        isSenior ? Radius.seniorCard : Radius.card
    }

    private func dayCard(_ day: WeekPlan.Day) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text((day.isToday ? "Azi, " : "") + WeekPlan.dayName(day))
                .font(isSenior ? Font.system(size: seniorTitleSize, weight: .semibold) : Font.title3.weight(.semibold))
                .foregroundStyle(PgColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if day.moments.isEmpty {
                Text("Niciun medicament programat.")
                    .font(bodyFont)
                    .foregroundStyle(PgColor.textSecondary)
            }
            ForEach(day.moments) { moment in
                momentRow(moment, isToday: day.isToday)
            }
        }
        .padding(isSenior ? Spacing.m : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isSenior && day.isToday ? PgColor.calmCard : Color.clear))
        .accessibilityIdentifier(isSenior ? "week.day.\(day.id)" : "week.dayDetail")
    }

    private func momentRow(_ moment: WeekPlan.Moment, isToday: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(moment.time)
                    .font(isSenior ? Font.system(size: seniorTextSize, weight: .semibold) : Font.headline)
                    .monospacedDigit()
                Text(moment.label)
                    .font(isSenior ? bodyFont : Font.subheadline)
                    .foregroundStyle(PgColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(PgColor.textPrimary)

            ForEach(moment.doses, id: \.medid) { dose in
                Text("\(PgFormat.doseAmount(dose.qty)) × \(store.med(id: dose.medid)?.product.brand ?? "medicament")")
                    .font(bodyFont)
                    .foregroundStyle(PgColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Label(moment.state.text, systemImage: moment.state.systemImage)
                .font(isSenior ? Font.system(size: seniorTextSize, weight: .semibold) : Font.subheadline.weight(.semibold))
                .foregroundStyle(moment.state.isDone ? PgColor.accent : PgColor.textSecondary)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(PgColor.surface))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("week.moment.\(moment.id)")
    }

    // MARK: - Eroarea

    private func errorView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Nu am putut încărca săptămâna.")
                .font(isSenior ? Font.system(size: seniorTitleSize, weight: .semibold) : Font.headline)
                .foregroundStyle(PgColor.textPrimary)
                .accessibilityIdentifier("week.error")
            Text(text)
                .font(bodyFont)
                .foregroundStyle(PgColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if isSenior {
                SeniorButton("Încearcă din nou", systemImage: "arrow.clockwise", prominence: .secondary, identifier: "week.retryButton") {
                    Task { await load() }
                }
            } else {
                Button("Încearcă din nou") {
                    Task { await load() }
                }
                .pgProminentButton()
                .accessibilityIdentifier("week.retryButton")
            }
        }
    }
}
