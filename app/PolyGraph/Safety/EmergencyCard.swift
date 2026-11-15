import Foundation

/// „Fișa de urgență”: ce trebuie să afle imediat un medic de pe ambulanță sau de la camera de gardă, pe un singur
/// ecran: cine e pacientul, ce medicamente cu risc ia (anticoagulantele primele), afecțiunile, lista completă cu
/// posologia și combinațiile grave deja semnalate. Totul vine din datele aplicației; nu interpretează și nu
/// recomandă nimic.
struct EmergencyCard {
    /// o grupă de medicamente pe care medicul de urgență trebuie s-o știe primul
    struct Flag: Identifiable {
        /// `MedGroup.rawValue`
        let id: String
        /// „Ia un anticoagulant (subțiază sângele)”
        let title: String
        /// „Sintrom 4 mg”
        let meds: [String]
    }

    struct Med: Identifiable {
        let id: String
        /// „Sintrom 4 mg”
        let name: String
        /// „acenocumarol”
        let substances: String
        /// „1 seara”
        let dosage: String
        /// „de la cardiologie”
        let prescriber: String?
    }

    struct Warning: Identifiable {
        let id: String
        /// „Risc crescut de sângerare: Sintrom și Nurofen”
        let text: String
    }

    /// grupele care apar sus, în ordinea importanței la urgență
    static let flagGroups: [MedGroup] = [
        .anticoagulant, .antiplatelet, .insulin, .antidiabetic, .digoxin, .antiepileptic, .opioid, .corticosteroid,
    ]

    let patientName: String
    /// „78 de ani”
    let ageText: String?
    let flags: [Flag]
    let conditions: [String]
    let conditionsNote: String?
    let meds: [Med]
    let warnings: [Warning]
    /// numele aparținătorului
    let contact: String?

    init(patient: Patient?, meds: [MedicationItem], analysis: Analysis?, now: Date) {
        patientName = patient?.name ?? "Pacientul"
        if let birthYear = patient?.birthYear, birthYear > 1900 {
            let years = Calendar(identifier: .gregorian).component(.year, from: now) - birthYear
            ageText = years > 0 && years < 130 ? "\(years) de ani" : nil
        } else {
            ageText = nil
        }

        flags = Self.flagGroups.compactMap { group in
            let names = group.meds(in: meds).map(\.displayName)
            guard !names.isEmpty else { return nil }
            return Flag(id: group.rawValue, title: Self.flagTitle(group), meds: names)
        }

        conditions = Condition.ordered.filter { (patient?.conditions ?? []).contains($0) }.map(\.label)
        let note = patient?.conditionsNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        conditionsNote = note.isEmpty ? nil : note

        // numele substanțelor în română vin din graf (nodurile `s:<ATC>`); altfel, DCI-ul
        let roNames = Dictionary(
            (analysis?.graph.nodes ?? []).map(\.data).filter { $0.type == .substance }.map { ($0.id, $0.label) },
            uniquingKeysWith: { first, _ in first })
        self.meds = meds.map { med in
            let substances = med.substances.map { substance in
                substance.atc.flatMap { roNames["s:\($0)"] } ?? substance.displayName ?? ""
            }
            .filter { !$0.isEmpty }
            .joined(separator: " + ")
            let specialty = med.prescriber.specialty?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return Med(
                id: med.id, name: med.displayName, substances: substances, dosage: PgFormat.dosageWords(med.dosage),
                prescriber: specialty.isEmpty ? "fără rețetă" : "de la \(specialty)")
        }

        let brands = Dictionary(meds.map { ($0.id, $0.product.brand) }, uniquingKeysWith: { first, _ in first })
        warnings = (analysis?.alerts ?? [])
            .filter { ($0.severity == .critical || $0.severity == .major) && $0.kind != .food && $0.kind != .expired }
            .sortedBySeverity()
            .map { alert in
                let names = alert.medids.compactMap { brands[$0] }
                let who = names.isEmpty ? "" : ": " + Self.joined(names)
                return Warning(id: alert.id, text: alert.title + who)
            }

        let caregiver = patient?.caregiverName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        contact = caregiver.isEmpty ? nil : caregiver
    }

    static func flagTitle(_ group: MedGroup) -> String {
        switch group {
        case .anticoagulant: "Ia un anticoagulant (subțiază sângele)"
        case .antiplatelet: "Ia un antiagregant (subțiază sângele)"
        case .insulin: "Face insulină"
        case .antidiabetic, .metformin: "Ia medicamente pentru diabet"
        case .digoxin: "Ia digoxină"
        case .antiepileptic: "Ia un anticonvulsivant"
        case .opioid: "Ia un analgezic opioid"
        case .corticosteroid: "Ia corticosteroizi"
        case .nsaid: "Ia un antiinflamator (AINS)"
        case .bisphosphonate: "Ia un medicament pentru oase"
        case .bloodPressure, .diuretic: "Ia medicamente pentru tensiune"
        case .iron: "Ia fier"
        }
    }

    /// „Sintrom”, „Sintrom și Nurofen”, „Sintrom, Nurofen și Aspenter”
    static func joined(_ names: [String]) -> String {
        guard names.count > 1, let last = names.last else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " și " + last
    }

    /// Fișa ca text simplu, pentru „Trimite” (mesaj, e-mail, imprimare).
    var plainText: String {
        var lines = ["FIȘA DE URGENȚĂ · \(patientName)" + (ageText.map { ", \($0)" } ?? "")]
        if !flags.isEmpty {
            lines.append("")
            lines.append("IMPORTANT")
            lines += flags.map { "• \($0.title): \(Self.joined($0.meds))" }
        }
        if !conditions.isEmpty || conditionsNote != nil {
            lines.append("")
            lines.append("AFECȚIUNI")
            lines += conditions.map { "• \($0)" }
            if let conditionsNote { lines.append("• \(conditionsNote)") }
        }
        lines.append("")
        lines.append("MEDICAMENTE (\(meds.count))")
        lines += meds.map { med in
            let substance = med.substances.isEmpty ? "" : " (\(med.substances))"
            let from = med.prescriber.map { ", \($0)" } ?? ""
            return "• \(med.name)\(substance): \(med.dosage)\(from)"
        }
        if !warnings.isEmpty {
            lines.append("")
            lines.append("COMBINAȚII GRAVE SEMNALATE")
            lines += warnings.map { "• \($0.text)" }
        }
        if let contact {
            lines.append("")
            lines.append("Persoana de contact: \(contact)")
        }
        lines.append("")
        lines.append(Self.disclaimer)
        return lines.joined(separator: "\n")
    }

    static let disclaimer =
        "Lista vine din aplicația MedHaven, completată de familie. Nu înlocuiește fișa medicală; alergiile nu sunt înregistrate aici."
}
