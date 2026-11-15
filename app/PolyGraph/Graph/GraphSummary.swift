import Foundation

/// Interpretarea grafului pe înțelesul oricui, din aceleași alerte ca graful: care sunt combinațiile grave și
/// moderate dintre medicamente și ce înseamnă fiecare, care medicament are cele mai multe legături și la ce
/// mâncare sau băutură trebuie avut grijă. Cele `minor` nu intră, ca în tab-ul Alerte.
struct GraphSummary {
    struct Pair {
        let alertID: String
        /// „Sintrom cu Nurofen”
        let text: String
        /// ce se întâmplă, într-o propoziție: „Risc crescut de sângerare.”
        let explanation: String
        /// ce e de făcut: „Discutați cu medicul cardiolog înainte de următoarea doză de Nurofen.”
        let recommendation: String
    }

    struct Hub {
        let medID: String
        let name: String
        let count: Int
        /// câte dintre combinațiile lui sunt grave
        let serious: Int
    }

    struct Food {
        /// „Alcool”
        let label: String
        /// „Sintrom, Nurofen”
        let meds: String
        let severity: Severity
        /// recomandarea alertei celei mai grave cu alimentul: „Evitați grepfrutul și sucul de grepfrut.”
        let advice: String
    }

    let serious: [Pair]
    /// combinațiile „de discutat”, cele mai importante primele (ordinea din tab-ul Alerte)
    let moderate: [Pair]
    let hub: Hub?
    let foods: [Food]

    var moderateCount: Int { moderate.count }

    var isEmpty: Bool { serious.isEmpty && moderateCount == 0 && foods.isEmpty }

    init(alerts: [Alert], graph: Graph?, meds: [MedicationItem]) {
        func name(_ id: String) -> String? {
            meds.first { $0.id == id }.map { $0.product.brand.isEmpty ? $0.displayName : $0.product.brand }
        }

        let shown = alerts.shownInApp.sortedBySeverity()
        let pairs = shown.filter { $0.kind == .ddi && $0.medids.count == 2 }
        let isSerious: (Alert) -> Bool = { $0.severity == .critical || $0.severity == .major }

        func pair(_ alert: Alert) -> Pair? {
            let names = alert.medids.compactMap(name)
            guard names.count == 2 else { return nil }
            return Pair(
                alertID: alert.id, text: "\(names[0]) cu \(names[1])",
                explanation: Self.explanation(alert), recommendation: Self.sentence(alert.recommendation))
        }
        serious = pairs.filter(isSerious).compactMap(pair)
        moderate = pairs.filter { !isSerious($0) }.compactMap(pair)

        // medicamentul din cele mai multe combinații; la egalitate, cel cu mai multe grave, apoi ordinea listei
        var counts: [String: (all: Int, serious: Int)] = [:]
        for alert in pairs {
            for id in alert.medids {
                counts[id, default: (0, 0)].all += 1
                if isSerious(alert) { counts[id, default: (0, 0)].serious += 1 }
            }
        }
        let order = Dictionary(uniqueKeysWithValues: meds.enumerated().map { ($1.id, $0) })
        let best = counts
            .filter { $0.value.all >= 2 && name($0.key) != nil }
            .min { lhs, rhs in
                if lhs.value.all != rhs.value.all { return lhs.value.all > rhs.value.all }
                if lhs.value.serious != rhs.value.serious { return lhs.value.serious > rhs.value.serious }
                return (order[lhs.key] ?? .max) < (order[rhs.key] ?? .max)
            }
        hub = best.flatMap { entry in
            name(entry.key).map { Hub(medID: entry.key, name: $0, count: entry.value.all, serious: entry.value.serious) }
        }

        // alimentele: eticheta vine din nodul `f:` al grafului, legat de alertă prin muchia food_interaction
        let labels = graph.map { Self.foodLabels($0) } ?? [:]
        var grouped: [(label: String, meds: [String], severity: Severity, advice: String)] = []
        for alert in shown where alert.kind == .food {
            guard let label = labels[alert.id] ?? Self.foodKey(alert) else { continue }
            let names = alert.medids.compactMap(name)
            if let i = grouped.firstIndex(where: { $0.label == label }) {
                for n in names where !grouped[i].meds.contains(n) { grouped[i].meds.append(n) }
            } else {
                // alertele vin ordonate după severitate: prima e cea mai gravă, cu recomandarea ei
                grouped.append((label, names, alert.severity, Self.sentence(alert.recommendation)))
            }
        }
        foods = grouped.map {
            Food(
                label: Self.capitalized($0.label), meds: $0.meds.joined(separator: ", "), severity: $0.severity,
                advice: $0.advice)
        }
    }

    // MARK: - Textele

    /// „o combinație gravă”, „2 combinații grave”, „20 de combinații grave”
    static func combinations(_ count: Int, _ singular: String, _ plural: String) -> String {
        switch count {
        case 1: "o combinație \(singular)"
        case 2...19: "\(count) combinații \(plural)"
        default: "\(count) de combinații \(plural)"
        }
    }

    /// Ce înseamnă combinația, într-o propoziție: titlul alertei („Risc crescut de sângerare.”); când titlul
    /// doar numește perechea („Simvastatină + omeprazol”), prima propoziție din detaliu care spune ce se întâmplă.
    static func explanation(_ alert: Alert) -> String {
        let title = alert.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty && !title.contains("+") { return sentence(title) }
        // „Omeprazolul poate crește ușor concentrația de simvastatină. Evaluat prin analogie…” → prima propoziție;
        // „Pentru X + Y, DDInter nu dă un nivel.” nu explică nimic, deci se sare
        let sentences = alert.detail
            .components(separatedBy: ". ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("nu dă un nivel") }
        guard let first = sentences.first else { return sentence(title) }
        if first.hasPrefix("Evaluat prin analogie") {
            return "Nu există date directe pentru perechea aceasta; riscul e estimat după un medicament din aceeași "
                + "clasă și trebuie confirmat de medic."
        }
        return sentence(first)
    }

    /// textul cu punct la final: „Risc crescut de sângerare” → „Risc crescut de sângerare.”
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return trimmed }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    // MARK: - Ajutoare

    private static func foodLabels(_ graph: Graph) -> [String: String] {
        let foodNodes = Dictionary(
            graph.nodes.map(\.data).filter { $0.type == .food }.map { ($0.id, $0.label) },
            uniquingKeysWith: { first, _ in first })
        var labels: [String: String] = [:]
        for edge in graph.edges.map(\.data) where edge.type == .foodInteraction {
            guard let alertID = edge.alertid,
                  let label = foodNodes[edge.target] ?? foodNodes[edge.source] else { continue }
            labels[alertID] = label
        }
        return labels
    }

    /// rezerva, dacă graful lipsește: „al_food_med_01_vitamin_k” → „vitamin k” (nu doar „k”, QA-04)
    private static func foodKey(_ alert: Alert) -> String? {
        var rest = Substring(alert.id)
        guard rest.hasPrefix("al_food_") else { return nil }
        rest = rest.dropFirst("al_food_".count)
        for id in alert.medids where rest.hasPrefix("\(id)_") {
            rest = rest.dropFirst(id.count + 1)
        }
        let key = rest.replacingOccurrences(of: "_", with: " ")
        return key.isEmpty ? nil : key
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased(with: PgFormat.romanian) + text.dropFirst()
    }
}
