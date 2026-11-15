import Foundation

/// Grupele de medicamente care contează la urgență și înaintea unei proceduri, după codul ATC al substanțelor.
/// Folosite de „Fișa de urgență” (`EmergencyCard`) și de „Am o programare” (`ProcedurePrep`). Textele nu dau
/// niciodată sfaturi despre doze și nu spun „opriți” (2.4): doar ce trebuie să afle medicul.
enum MedGroup: String, CaseIterable {
    case anticoagulant
    case antiplatelet
    case nsaid
    case insulin
    case antidiabetic
    case metformin
    case bisphosphonate
    case corticosteroid
    case bloodPressure
    case diuretic
    case digoxin
    case antiepileptic
    case opioid
    case iron

    /// prefixele ATC; o substanță intră în grupă dacă ATC-ul ei începe cu unul dintre ele
    var atcPrefixes: [String] {
        switch self {
        case .anticoagulant: ["B01AA", "B01AB", "B01AE", "B01AF"]
        case .antiplatelet: ["B01AC"]
        case .nsaid: ["M01A"]
        case .insulin: ["A10A"]
        case .antidiabetic: ["A10B"]
        case .metformin: ["A10BA02", "A10BD"]
        case .bisphosphonate: ["M05BA", "M05BB"]
        case .corticosteroid: ["H02A"]
        case .bloodPressure: ["C09"]
        case .diuretic: ["C03"]
        case .digoxin: ["C01AA"]
        case .antiepileptic: ["N03"]
        case .opioid: ["N02A"]
        case .iron: ["B03A"]
        }
    }

    /// în cuvinte simple: „subțiază sângele”
    var plainName: String {
        switch self {
        case .anticoagulant: "anticoagulant, subțiază sângele"
        case .antiplatelet: "antiagregant (ca aspirina), subțiază sângele"
        case .nsaid: "antiinflamator (AINS)"
        case .insulin: "insulină"
        case .antidiabetic: "pentru diabet"
        case .metformin: "metformin, pentru diabet"
        case .bisphosphonate: "pentru oase (osteoporoză)"
        case .corticosteroid: "corticosteroid"
        case .bloodPressure: "pentru tensiune"
        case .diuretic: "diuretic, pentru tensiune sau apă în corp"
        case .digoxin: "digoxină, pentru inimă"
        case .antiepileptic: "anticonvulsivant (pentru epilepsie)"
        case .opioid: "analgezic opioid, pentru durere"
        case .iron: "fier"
        }
    }

    func matches(_ substance: Substance) -> Bool {
        guard let atc = substance.atc?.uppercased(), !atc.isEmpty else { return false }
        return atcPrefixes.contains { atc.hasPrefix($0) }
    }

    func matches(_ med: MedicationItem) -> Bool {
        med.substances.contains { matches($0) }
    }

    /// medicamentele din grupă, în ordinea listei
    func meds(in meds: [MedicationItem]) -> [MedicationItem] {
        meds.filter { matches($0) }
    }
}
