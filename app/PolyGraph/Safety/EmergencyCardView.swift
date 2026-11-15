import SwiftUI

/// „Fișa de urgență”, pe un singur ecran, de arătat echipajului de pe ambulanță sau medicului de gardă.
/// La pacient (din „Ziua de azi”): text mare și „Gata” ca buton mare; la aparținător (din Medicamente):
/// stilul obișnuit și „Trimite fișa” (text simplu, pentru un mesaj sau pentru imprimare).
struct EmergencyCardView: View {
    let audience: ShareSheet.Audience

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .title) private var seniorTitleSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title2) private var seniorTextSize: CGFloat = 22

    private var isSenior: Bool { audience == .senior }

    private var card: EmergencyCard {
        EmergencyCard(patient: store.patient, meds: store.visibleMeds, analysis: store.analysis, now: store.clock.now)
    }

    var body: some View {
        let card = card
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    header(card)

                    if !card.flags.isEmpty {
                        section("Important", identifier: "emergency.flags") {
                            ForEach(card.flags) { flag in
                                flagRow(flag)
                            }
                        }
                    }

                    if !card.conditions.isEmpty || card.conditionsNote != nil {
                        section("Afecțiuni", identifier: "emergency.conditions") {
                            ForEach(card.conditions, id: \.self) { condition in
                                bullet(condition)
                            }
                            if let note = card.conditionsNote {
                                bullet(note)
                            }
                        }
                    }

                    section("Medicamente (\(card.meds.count))", identifier: "emergency.meds") {
                        if card.meds.isEmpty {
                            Text("Nu e niciun medicament pe listă.")
                                .font(bodyFont)
                                .foregroundStyle(PgColor.textSecondary)
                        }
                        ForEach(card.meds) { med in
                            medRow(med)
                        }
                    }

                    if !card.warnings.isEmpty {
                        section("Combinații grave semnalate", identifier: "emergency.warnings") {
                            ForEach(card.warnings) { warning in
                                bullet(warning.text)
                            }
                        }
                    }

                    if let contact = card.contact {
                        Label("Persoana de contact: \(contact)", systemImage: "person.crop.circle")
                            .font(bodyFont)
                            .foregroundStyle(PgColor.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("emergency.contact")
                    }

                    Text(EmergencyCard.disclaimer)
                        .font(isSenior ? Font.body : Font.footnote)
                        .foregroundStyle(PgColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("emergency.disclaimer")

                    if isSenior {
                        SeniorButton("Gata", systemImage: "checkmark", prominence: .secondary, identifier: "emergency.doneButton") {
                            dismiss()
                        }
                    }
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(PgColor.background)
            .navigationTitle("Fișa de urgență")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isSenior {
                    ToolbarItem(placement: .topBarLeading) {
                        SwiftUI.ShareLink(item: card.plainText, subject: Text("Fișa de urgență · \(card.patientName)")) {
                            Label("Trimite fișa", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("emergency.shareButton")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Gata") { dismiss() }
                            .pgBarButton()
                            .accessibilityIdentifier("emergency.doneButton")
                    }
                }
            }
        }
    }

    // MARK: - Bucăți

    private var bodyFont: Font {
        isSenior ? Font.system(size: seniorTextSize) : Font.body
    }

    private var strongFont: Font {
        isSenior ? Font.system(size: seniorTextSize, weight: .semibold) : Font.body.weight(.semibold)
    }

    private func header(_ card: EmergencyCard) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(card.patientName)
                .font(isSenior ? Font.system(size: seniorTitleSize, weight: .bold) : Font.title.weight(.bold))
                .foregroundStyle(PgColor.textPrimary)
            if let age = card.ageText {
                Text(age)
                    .font(bodyFont)
                    .foregroundStyle(PgColor.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("emergency.header")
    }

    private func section<Content: View>(
        _ title: String, identifier: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(title)
                .font(isSenior ? Font.system(size: seniorTextSize, weight: .bold) : Font.headline)
                .foregroundStyle(PgColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Spacing.s) {
                content()
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: isSenior ? Radius.seniorCard : Radius.card, style: .continuous)
                    .fill(PgColor.surface))
        }
        .accessibilityIdentifier(identifier)
    }

    /// Grupele importante, cu pictogramă și numele medicamentelor; fără roșu de alarmă (2.4.2).
    private func flagRow(_ flag: EmergencyCard.Flag) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(PgColor.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(flag.title)
                    .font(strongFont)
                    .foregroundStyle(PgColor.textPrimary)
                Text(EmergencyCard.joined(flag.meds))
                    .font(bodyFont)
                    .foregroundStyle(PgColor.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("emergency.flag.\(flag.id)")
    }

    private func medRow(_ med: EmergencyCard.Med) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(med.name)
                .font(strongFont)
                .foregroundStyle(PgColor.textPrimary)
            Text([med.substances, med.dosage, med.prescriber].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(bodyFont)
                .foregroundStyle(PgColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("emergency.med.\(med.id)")
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text("•")
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(bodyFont)
        .foregroundStyle(PgColor.textPrimary)
    }
}
