import SwiftUI

/// „Am o programare”: se alege procedura (stomatolog, operație, endoscopie, contrast) și apar medicamentele
/// de pe listă despre care trebuie să afle medicul, fiecare cu motivul. Nu spune niciodată „opriți”;
/// doar medicul decide (2.4). La pacient: text mare și butoane mari; la aparținător: stilul obișnuit și
/// „Trimite” (text simplu).
struct ProcedurePrepView: View {
    let audience: ShareSheet.Audience

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var procedure: Procedure?
    @ScaledMetric(relativeTo: .title) private var seniorTitleSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title2) private var seniorTextSize: CGFloat = 22

    private var isSenior: Bool { audience == .senior }

    private var prep: ProcedurePrep? {
        procedure.map { ProcedurePrep(procedure: $0, meds: store.visibleMeds) }
    }

    var body: some View {
        let prep = prep
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text("La ce mergeți?")
                        .font(isSenior ? Font.system(size: seniorTitleSize, weight: .semibold) : Font.title2.weight(.semibold))
                        .foregroundStyle(PgColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)

                    VStack(spacing: Spacing.s) {
                        ForEach(Procedure.allCases) { option in
                            choice(option)
                        }
                    }

                    if let prep {
                        result(prep)
                    }

                    if isSenior {
                        SeniorButton("Gata", systemImage: "checkmark", prominence: .secondary, identifier: "procedure.doneButton") {
                            dismiss()
                        }
                    }
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(PgColor.background)
            .navigationTitle("Am o programare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // ca în ShareSheet: un singur ToolbarItem; „Trimite” stă în pagină, sub rezultat
                if !isSenior {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Gata") { dismiss() }
                            .pgBarButton()
                            .accessibilityIdentifier("procedure.doneButton")
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

    private var cornerRadius: CGFloat {
        isSenior ? Radius.seniorCard : Radius.card
    }

    /// Un rând mare pentru fiecare procedură; cel ales e evidențiat (fundal și bifă), nu doar prin culoare.
    private func choice(_ option: Procedure) -> some View {
        let selected = procedure == option
        return Button {
            procedure = option
        } label: {
            HStack(alignment: .center, spacing: Spacing.m) {
                Image(systemName: option.systemImage)
                    .font(strongFont)
                    .foregroundStyle(PgColor.accent)
                    .frame(width: isSenior ? 36 : 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(option.title)
                        .font(strongFont)
                        .foregroundStyle(PgColor.textPrimary)
                    Text(option.examples)
                        .font(isSenior ? Font.system(size: seniorTextSize * 0.8) : Font.subheadline)
                        .foregroundStyle(PgColor.textSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(strongFont)
                    .foregroundStyle(selected ? PgColor.accent : PgColor.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, minHeight: isSenior ? ControlHeight.senior : ControlHeight.caregiver, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(selected ? PgColor.calmCard : PgColor.surface))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("procedure.option.\(option.id)")
    }

    private func result(_ prep: ProcedurePrep) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(prep.isEmpty ? "Ce să spuneți medicului" : "Spuneți-i \(prep.procedure.doctor) că luați:")
                .font(isSenior ? Font.system(size: seniorTextSize, weight: .bold) : Font.headline)
                .foregroundStyle(PgColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: Spacing.m) {
                if prep.isEmpty {
                    Text(prep.noneText)
                        .font(bodyFont)
                        .foregroundStyle(PgColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("procedure.none")
                }
                ForEach(prep.items) { item in
                    itemRow(item)
                }
                Text(prep.closing)
                    .font(isSenior ? bodyFont : Font.subheadline)
                    .foregroundStyle(PgColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("procedure.closing")
                if !isSenior {
                    SwiftUI.ShareLink(item: prep.plainText(patientName: store.patient?.name ?? "Pacientul")) {
                        Label("Trimite lista", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("procedure.shareButton")
                }
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(PgColor.surface))
        }
        .accessibilityIdentifier("procedure.result")
    }

    private func itemRow(_ item: ProcedurePrep.Item) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(EmergencyCard.joined(item.meds))
                .font(strongFont)
                .foregroundStyle(PgColor.textPrimary)
            Text(item.group)
                .font(isSenior ? bodyFont : Font.subheadline)
                .foregroundStyle(PgColor.accent)
            Text(item.reason)
                .font(bodyFont)
                .foregroundStyle(PgColor.textPrimary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("procedure.item.\(item.id)")
    }
}
