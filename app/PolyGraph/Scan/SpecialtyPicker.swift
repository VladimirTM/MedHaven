import SwiftUI

/// Specialitățile din meniul „Specialitatea” al confirmării. Valorile sunt cele pe care backend-ul le recunoaște
/// în recomandări („Discutați cu medicul cardiolog…”, `SPECIALIST` din `engine/texts_ro.py`) și cele din
/// fixture-uri, ca lista de medicamente să se grupeze sub același titlu.
enum Specialty {
    /// medicina de familie prima: la vârstnici, cele mai multe rețete vin de acolo
    static let all: [String] = [
        "medicină de familie",
        "cardiologie",
        "diabetologie",
        "endocrinologie",
        "gastroenterologie",
        "geriatrie",
        "nefrologie",
        "neurologie",
        "ORL",
        "ortopedie",
        "pneumologie",
        "psihiatrie",
        "reumatologie",
        "urologie",
    ]

    /// „Cardiologie”, „ORL”: titlul din meniu, cu prima literă mare
    static func title(_ value: String) -> String {
        value.prefix(1).uppercased(with: PgFormat.romanian) + value.dropFirst()
    }

    /// valoarea din listă care se potrivește cu ce e scris (fără diacritice și majuscule), dacă există
    static func canonical(_ text: String) -> String? {
        let key = normalized(text)
        guard !key.isEmpty else { return nil }
        return all.first { normalized($0) == key }
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: PgFormat.romanian)
    }
}

/// Meniu cu specialitățile cunoscute, plus „Altă specialitate…” cu un câmp liber sub el.
struct SpecialtyPicker: View {
    @Binding var specialty: String
    @State private var writesOther: Bool

    private static let none = ""
    private static let other = "\u{0}other"

    init(specialty: Binding<String>) {
        _specialty = specialty
        let text = specialty.wrappedValue
        _writesOther = State(initialValue: !text.isEmpty && Specialty.canonical(text) == nil)
    }

    var body: some View {
        Picker("Specialitatea", selection: selection) {
            Text("Nu știu").tag(Self.none)
            ForEach(Specialty.all, id: \.self) { value in
                Text(Specialty.title(value)).tag(value)
            }
            Text("Altă specialitate…").tag(Self.other)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("confirm.specialtyField")

        if writesOther {
            TextField("Scrieți specialitatea", text: $specialty)
                .accessibilityIdentifier("confirm.specialtyOtherField")
        }
    }

    private var selection: Binding<String> {
        Binding(
            get: {
                if writesOther { return Self.other }
                return Specialty.canonical(specialty) ?? Self.none
            },
            set: { choice in
                switch choice {
                case Self.other:
                    writesOther = true
                    specialty = ""
                default:
                    writesOther = false
                    specialty = choice
                }
            })
    }
}
