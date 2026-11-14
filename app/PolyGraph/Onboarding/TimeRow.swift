import SwiftUI

/// Un rând „Micul dejun · 08:00”; la atingere se deschide roata de sub el (tiparul din Calendar).
/// Comun pentru onboarding și pentru „Orele zilei” din Setări (E1).
struct TimeRow: View {
    let title: String
    @Binding var selection: Date
    let identifier: String

    @State private var expanded = false
    @Environment(\.pgReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var fontSize: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withPgAnimation(.pgStandard, reduceMotion: reduceMotion) { expanded.toggle() }
            } label: {
                HStack {
                    Text(title)
                        .foregroundStyle(PgColor.textPrimary)
                    Spacer()
                    Text(PgFormat.clock(selection))
                        .monospacedDigit()
                        .foregroundStyle(PgColor.accent)
                }
                .font(.system(size: fontSize, weight: .semibold))
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: ControlHeight.senior)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("\(title), ora \(PgFormat.clock(selection))")
            .accessibilityHint(expanded ? "Atingeți ca să închideți" : "Atingeți ca să schimbați ora")
            .accessibilityIdentifier(identifier)

            if expanded {
                DatePicker(title, selection: $selection, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .environment(\.locale, PgFormat.romanian)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("\(identifier).picker")
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(PgColor.surface))
    }
}
