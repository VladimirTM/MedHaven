import SwiftUI

/// Înălțimea, greutatea și afecțiunile, cu rânduri mari (le poate completa și pacientul).
/// Aceleași câmpuri în onboarding și în Setări → „Profilul de sănătate”.
struct HealthProfileFields: View {
    @Binding var profile: PatientProfile
    /// „onboarding” sau „profile”: prefixul identificatorilor
    let idPrefix: String

    @ScaledMetric(relativeTo: .title2) private var fieldSize: CGFloat = 22
    @FocusState private var focused: Field?

    private enum Field { case height, weight, note }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.s) { numberFields }
                VStack(spacing: Spacing.s) { numberFields }
            }

            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Afecțiuni")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PgColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Alegeți tot ce se potrivește. Le vede medicul de familie, lângă lista de medicamente.")
                    .font(.body)
                    .foregroundStyle(PgColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    ForEach(Array(Condition.ordered.enumerated()), id: \.element) { index, condition in
                        if index > 0 {
                            Divider().padding(.leading, Spacing.m)
                        }
                        conditionRow(condition)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(PgColor.surface))
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))

                TextField("Alte afecțiuni (opțional)", text: $profile.note, axis: .vertical)
                    .font(.body)
                    .lineLimit(1...3)
                    .focused($focused, equals: .note)
                    .padding(Spacing.m)
                    .frame(minHeight: ControlHeight.caregiver)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .fill(PgColor.surface))
                    .accessibilityIdentifier("\(idPrefix).conditionsNote")
            }

            if let problem = profile.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.body)
                    .foregroundStyle(PgColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(idPrefix).profileProblem")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Gata") { focused = nil }
            }
        }
    }

    @ViewBuilder
    private var numberFields: some View {
        numberField("Înălțimea", unit: "cm", text: $profile.heightText, keyboard: .numberPad, field: .height,
                    identifier: "\(idPrefix).heightField")
        numberField("Greutatea", unit: "kg", text: $profile.weightText, keyboard: .decimalPad, field: .weight,
                    identifier: "\(idPrefix).weightField")
    }

    private func numberField(
        _ title: String, unit: String, text: Binding<String>, keyboard: UIKeyboardType, field: Field, identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PgColor.textSecondary)
            HStack(spacing: Spacing.xs) {
                TextField("–", text: text)
                    .font(.system(size: fieldSize))
                    .keyboardType(keyboard)
                    .focused($focused, equals: field)
                    .accessibilityLabel("\(title), în \(unit == "cm" ? "centimetri" : "kilograme")")
                    .accessibilityIdentifier(identifier)
                Text(unit)
                    .font(.system(size: fieldSize))
                    .foregroundStyle(PgColor.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.m)
            .frame(maxWidth: .infinity, minHeight: ControlHeight.senior)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(PgColor.surface))
            .contentShape(Rectangle())
            .onTapGesture { focused = field }
        }
        .frame(maxWidth: .infinity)
    }

    private func conditionRow(_ condition: Condition) -> some View {
        let selected = profile.conditions.contains(condition)
        return Button {
            if selected { profile.conditions.remove(condition) } else { profile.conditions.insert(condition) }
        } label: {
            HStack(spacing: Spacing.s) {
                Text(condition.label)
                    .font(.body)
                    .foregroundStyle(PgColor.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.xs)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? PgColor.accent : PgColor.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("\(idPrefix).condition.\(condition.rawValue)")
    }
}
