import Foundation

/// Afecțiunile din profilul pacientului, în română și în ordinea din listă.
/// Aceleași etichete ca în portal: sursa e `contracts/fixtures/conditions.json` (verificat de `PatientProfileTests`).
extension Condition {
    static let ordered: [Condition] = [
        .hypertension, .heartFailure, .atrialFibrillation, .coronaryDisease, .stroke, .highCholesterol,
        .diabetes, .hypothyroidism, .chronicKidneyDisease, .liverDisease, .copdAsthma, .gastricUlcer,
        .osteoporosis, .arthritis, .dementia, .parkinson, .depression, .epilepsy, .glaucoma, .prostate, .falls,
    ]

    var label: String {
        switch self {
        case .hypertension: "Hipertensiune arterială"
        case .heartFailure: "Insuficiență cardiacă"
        case .atrialFibrillation: "Fibrilație atrială"
        case .coronaryDisease: "Cardiopatie ischemică (angină, infarct în trecut)"
        case .stroke: "Accident vascular cerebral în trecut"
        case .highCholesterol: "Colesterol mărit"
        case .diabetes: "Diabet zaharat"
        case .hypothyroidism: "Hipotiroidism"
        case .chronicKidneyDisease: "Boală cronică de rinichi"
        case .liverDisease: "Boală de ficat"
        case .copdAsthma: "BPOC sau astm"
        case .gastricUlcer: "Ulcer sau reflux gastric"
        case .osteoporosis: "Osteoporoză"
        case .arthritis: "Artroză sau artrită"
        case .dementia: "Demență sau probleme de memorie"
        case .parkinson: "Boala Parkinson"
        case .depression: "Depresie sau anxietate"
        case .epilepsy: "Epilepsie"
        case .glaucoma: "Glaucom"
        case .prostate: "Adenom de prostată"
        case .falls: "Căderi în ultimul an"
        }
    }
}

/// Profilul de sănătate în forma în care se editează: textele câmpurilor, cum le scrie omul.
struct PatientProfile: Equatable {
    static let heightRange = 100...230
    static let weightRange = 25.0...250.0

    var heightText = ""
    var weightText = ""
    var conditions: Set<Condition> = []
    var note = ""

    init() {}

    init(_ patient: Patient) {
        heightText = patient.heightCm.map(String.init) ?? ""
        weightText = patient.weightKg.map(Self.weightString) ?? ""
        conditions = Set(patient.conditions ?? [])
        note = patient.conditionsNote ?? ""
    }

    /// „172” → 172; gol → nil
    var heightCm: Int? { Int(heightText.trimmingCharacters(in: .whitespaces)) }

    /// „64,5” sau „64.5” → 64.5; gol → nil
    var weightKg: Double? {
        Double(weightText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// mesajul de sub câmpuri, dacă ce e scris nu se poate salva
    var problem: String? {
        let height = heightText.trimmingCharacters(in: .whitespaces)
        let weight = weightText.trimmingCharacters(in: .whitespaces)
        if !height.isEmpty, heightCm.map { Self.heightRange.contains($0) } != true {
            return "Înălțimea se scrie în centimetri, între \(Self.heightRange.lowerBound) și \(Self.heightRange.upperBound)."
        }
        if !weight.isEmpty, weightKg.map { Self.weightRange.contains($0) } != true {
            return "Greutatea se scrie în kilograme, între 25 și 250."
        }
        if note.count > 200 { return "Alte afecțiuni: cel mult 200 de caractere." }
        return nil
    }

    var orderedConditions: [Condition] { Condition.ordered.filter(conditions.contains) }

    var trimmedNote: String? {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// „1,58 m · 64 kg · 7 afecțiuni”; gol dacă nu e completat nimic
    var shortSummary: String {
        var parts: [String] = []
        if let heightCm { parts.append(String(format: "%.2f m", Double(heightCm) / 100).replacingOccurrences(of: ".", with: ",")) }
        if let weightKg { parts.append("\(Self.weightString(weightKg)) kg") }
        let count = conditions.count + (trimmedNote == nil ? 0 : 1)
        switch count {
        case 0: break
        case 1: parts.append("1 afecțiune")
        case 2...19: parts.append("\(count) afecțiuni")
        default: parts.append("\(count) de afecțiuni")
        }
        return parts.joined(separator: " · ")
    }

    /// 64 → „64”; 64.5 → „64,5”
    static func weightString(_ kg: Double) -> String {
        kg.rounded() == kg ? String(Int(kg)) : String(format: "%.1f", kg).replacingOccurrences(of: ".", with: ",")
    }
}

/// PATCH cu profilul întreg: câmpurile goale se trimit `null`, ca să se poată și șterge (codarea sintetizată le-ar omite).
struct ProfileUpdate: Encodable {
    let heightCm: Int?
    let weightKg: Double?
    let conditions: [Condition]
    let conditionsNote: String?

    init(_ profile: PatientProfile) {
        heightCm = profile.heightCm
        weightKg = profile.weightKg
        conditions = profile.orderedConditions
        conditionsNote = profile.trimmedNote
    }

    enum CodingKeys: String, CodingKey {
        case heightCm = "height_cm"
        case weightKg = "weight_kg"
        case conditions
        case conditionsNote = "conditions_note"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(heightCm, forKey: .heightCm)
        try c.encode(weightKg, forKey: .weightKg)
        try c.encode(conditions, forKey: .conditions)
        try c.encode(conditionsNote, forKey: .conditionsNote)
    }
}
