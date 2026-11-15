import Foundation

/// O procedură programată la care medicul trebuie să afle din timp de anumite medicamente.
enum Procedure: String, CaseIterable, Identifiable {
    case dentist
    case surgery
    case endoscopy
    case contrast

    var id: String { rawValue }

    /// „La stomatolog”
    var title: String {
        switch self {
        case .dentist: "La stomatolog"
        case .surgery: "O operație"
        case .endoscopy: "Endoscopie sau colonoscopie"
        case .contrast: "Investigație cu substanță de contrast"
        }
    }

    /// exemple, ca omul să-și recunoască programarea
    var examples: String {
        switch self {
        case .dentist: "extracție, implant, detartraj"
        case .surgery: "inclusiv mică chirurgie sau o operație de cataractă"
        case .endoscopy: "gastroscopie, colonoscopie"
        case .contrast: "CT sau RMN cu contrast, coronarografie"
        }
    }

    var systemImage: String {
        switch self {
        case .dentist: "mouth"
        case .surgery: "bandage"
        case .endoscopy: "stethoscope"
        case .contrast: "drop"
        }
    }

    /// „medicului stomatolog”, la dativ, pentru „Spuneți-i …”
    var doctor: String {
        switch self {
        case .dentist: "medicului stomatolog"
        case .surgery: "chirurgului și medicului anestezist"
        case .endoscopy: "medicului care face endoscopia"
        case .contrast: "medicului care face investigația"
        }
    }
}

/// „Am o programare”: pentru procedura aleasă, medicamentele de pe listă despre care trebuie să afle medicul
/// și de ce. Regula de siguranță din 2.4: nu spune niciodată „opriți” sau „nu mai luați” și nu atinge dozele;
/// doar medicul decide dacă se schimbă ceva.
struct ProcedurePrep {
    struct Item: Identifiable {
        /// `MedGroup.rawValue`
        let id: String
        /// „anticoagulant, subțiază sângele”
        let group: String
        /// „Sintrom 4 mg”
        let meds: [String]
        /// „O extracție poate sângera mai mult.”
        let reason: String
    }

    struct Rule {
        let group: MedGroup
        let reason: String
    }

    let procedure: Procedure
    let items: [Item]

    var isEmpty: Bool { items.isEmpty }

    init(procedure: Procedure, meds: [MedicationItem]) {
        self.procedure = procedure
        items = Self.rules(for: procedure).compactMap { rule in
            let names = rule.group.meds(in: meds).map(\.displayName)
            guard !names.isEmpty else { return nil }
            return Item(id: rule.group.rawValue, group: rule.group.plainName, meds: names, reason: rule.reason)
        }
    }

    static func rules(for procedure: Procedure) -> [Rule] {
        let bleeding = "Subțiază sângele, deci intervenția poate sângera mai mult."
        switch procedure {
        case .dentist:
            return [
                Rule(group: .anticoagulant, reason: bleeding + " Medicul stomatolog trebuie să știe dinainte."),
                Rule(group: .antiplatelet, reason: bleeding),
                Rule(group: .nsaid, reason: "Antiinflamatoarele pot crește sângerarea după o extracție."),
                Rule(
                    group: .bisphosphonate,
                    reason: "La extracții și implanturi, tratamentul pentru oase contează pentru vindecarea maxilarului."),
            ]
        case .surgery:
            return [
                Rule(group: .anticoagulant, reason: bleeding),
                Rule(group: .antiplatelet, reason: bleeding),
                Rule(group: .nsaid, reason: "Antiinflamatoarele pot crește sângerarea."),
                Rule(group: .insulin, reason: "Înaintea operației se ține post, iar insulina poate scădea prea mult glicemia."),
                Rule(group: .antidiabetic, reason: "Înaintea operației se ține post, iar glicemia poate scădea prea mult."),
                Rule(group: .bloodPressure, reason: "Medicul anestezist vrea să știe de medicamentele pentru tensiune."),
                Rule(group: .diuretic, reason: "Medicul anestezist vrea să știe de diuretice (apa și sărurile din corp)."),
                Rule(group: .corticosteroid, reason: "Corticosteroizii contează pentru anestezie și pentru vindecare."),
            ]
        case .endoscopy:
            return [
                Rule(group: .anticoagulant, reason: bleeding + " Contează mai ales dacă se ia o biopsie sau se scoate un polip."),
                Rule(group: .antiplatelet, reason: bleeding + " Contează mai ales dacă se ia o biopsie sau se scoate un polip."),
                Rule(group: .insulin, reason: "Pregătirea înseamnă post, iar insulina poate scădea prea mult glicemia."),
                Rule(group: .antidiabetic, reason: "Pregătirea înseamnă post, iar glicemia poate scădea prea mult."),
                Rule(group: .iron, reason: "Fierul colorează scaunul și poate încurca pregătirea pentru colonoscopie."),
            ]
        case .contrast:
            return [
                Rule(
                    group: .metformin,
                    reason: "Substanța de contrast solicită rinichii; medicul verifică analizele și spune ce e de făcut cu metforminul."),
                Rule(group: .nsaid, reason: "Antiinflamatoarele și substanța de contrast solicită amândouă rinichii."),
                Rule(group: .diuretic, reason: "Diureticele și substanța de contrast solicită amândouă rinichii."),
            ]
        }
    }

    /// Ce se spune mereu, la final: lista completă și cine decide.
    var closing: String {
        "Spuneți-i \(procedure.doctor) toate medicamentele, inclusiv cele fără rețetă. "
            + "Doar medicul decide dacă se schimbă ceva înainte de programare."
    }

    /// când nicio grupă nu se potrivește
    var noneText: String {
        "Nu am găsit pe listă medicamente din grupele care contează de obicei la această programare."
    }

    /// Lista ca text simplu, pentru „Trimite”.
    func plainText(patientName: String) -> String {
        var lines = ["\(procedure.title.uppercased(with: PgFormat.romanian)) · \(patientName)", ""]
        if items.isEmpty {
            lines.append(noneText)
        } else {
            lines.append("De spus medicului:")
            lines += items.map { "• \(EmergencyCard.joined($0.meds)) (\($0.group)): \($0.reason)" }
        }
        lines.append("")
        lines.append(closing)
        return lines.joined(separator: "\n")
    }
}
