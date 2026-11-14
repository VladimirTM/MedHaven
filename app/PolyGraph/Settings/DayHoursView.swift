import OSLog
import SwiftUI

/// E1: „Orele zilei” din Setări (aparținătorul). Aceleași rânduri ca la onboarding; „Salvează” trimite
/// PATCH /patients cu `anchors`, iar serverul mută și dozele de azi deja bifate.
struct DayHoursView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var wake = Date()
    @State private var breakfast = Date()
    @State private var lunch = Date()
    @State private var dinner = Date()
    @State private var bedtime = Date()
    @State private var loaded = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                TimeRow(title: "Trezirea", selection: $wake, identifier: "hours.wakeTime")
                TimeRow(title: "Micul dejun", selection: $breakfast, identifier: "hours.breakfastTime")
                TimeRow(title: "Prânzul", selection: $lunch, identifier: "hours.lunchTime")
                TimeRow(title: "Cina", selection: $dinner, identifier: "hours.dinnerTime")
                TimeRow(title: "Culcarea", selection: $bedtime, identifier: "hours.bedTime")
                Text("Pastilele se mută odată cu orele. Regulile dintre ele rămân aceleași.")
                    .font(.body)
                    .foregroundStyle(PgColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.body)
                        .foregroundStyle(PgColor.textPrimary)
                        .accessibilityIdentifier("hours.error")
                }
                SeniorButton(isSaving ? "Se salvează…" : "Salvează", identifier: "hours.saveButton") {
                    Task { await save() }
                }
                .disabled(isSaving || !inOrder)
                if !inOrder {
                    Text("Orele trebuie să fie în ordinea zilei: trezirea, micul dejun, prânzul, cina, culcarea.")
                        .font(.footnote)
                        .foregroundStyle(PgColor.textSecondary)
                        .accessibilityIdentifier("hours.orderHint")
                }
            }
            .padding(Spacing.m)
        }
        .background(PgColor.background)
        .navigationTitle("Orele zilei")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: savedCount)
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        .onAppear(perform: load)
    }

    private var clocks: [String] {
        [wake, breakfast, lunch, dinner, bedtime].map { PgFormat.clock($0) }
    }

    /// Aceeași regulă ca serverul (422 „Orele trebuie să fie în ordinea zilei”), verificată înainte de trimitere.
    private var inOrder: Bool {
        zip(clocks, clocks.dropFirst()).allSatisfy { $0 < $1 }
    }

    private func load() {
        guard !loaded, let anchors = store.patient?.anchors ?? store.schedule?.anchors else { return }
        loaded = true
        wake = PgFormat.date(fromClock: anchors.wake) ?? wake
        breakfast = PgFormat.date(fromClock: anchors.breakfast) ?? breakfast
        lunch = PgFormat.date(fromClock: anchors.lunch) ?? lunch
        dinner = PgFormat.date(fromClock: anchors.dinner) ?? dinner
        bedtime = PgFormat.date(fromClock: anchors.bed) ?? bedtime
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let anchors = Anchors(
            bed: PgFormat.clock(bedtime),
            breakfast: PgFormat.clock(breakfast),
            dinner: PgFormat.clock(dinner),
            lunch: PgFormat.clock(lunch),
            wake: PgFormat.clock(wake))
        do {
            try await store.updateAnchors(anchors)
            savedCount += 1
            Log.settings.info("orele zilei salvate")
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Nu am putut salva. Încercați din nou."
        }
    }
}
