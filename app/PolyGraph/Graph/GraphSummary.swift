import Foundation

/// Interpretarea grafului pe înțelesul oricui, din aceleași alerte ca graful: câte combinații grave și
/// moderate sunt între medicamente, care medicament are cele mai multe legături și la ce mâncare sau
/// băutură trebuie avut grijă. Cele `minor` nu intră, ca în tab-ul Alerte.
struct GraphSummary {
    struct Pair {
        let alertID: String
        /// „Sintrom cu Nurofen”
        let text: String
    }

    struct Hub {
        let medID: String
        let name: String
        let count: Int
    }

    struct Food {
        /// „Alcool”
        let label: String
        /// „Sintrom, Nurofen”
        let meds: String
        let severity: Severity
    }

    let serious: [Pair]
    let moderateCount: Int
    let hub: Hub?
    let foods: [Food]

    var isEmpty: Bool { serious.isEmpty && moderateCount == 0 && foods.isEmpty }

    init(alerts: [Alert], graph: Graph?, meds: [MedicationItem]) {
        func name(_ id: String) -> String? {
            meds.first { $0.id == id }.map { $0.product.brand.isEmpty ? $0.displayName : $0.product.brand }
        }

        let shown = alerts.shownInApp.sortedBySeverity()
        let pairs = shown.filter { $0.kind == .ddi && $0.medids.count == 2 }
        let isSerious: (Alert) -> Bool = { $0.severity == .critical || $0.severity == .major }

        serious = pairs.filter(isSerious).compactMap { alert in
            let names = alert.medids.compactMap(name)
            guard names.count == 2 else { return nil }
            return Pair(alertID: alert.id, text: "\(names[0]) cu \(names[1])")
        }
        moderateCount = pairs.filter { !isSerious($0) }.count

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
        hub = best.flatMap { entry in name(entry.key).map { Hub(medID: entry.key, name: $0, count: entry.value.all) } }

        // alimentele: eticheta vine din nodul `f:` al grafului, legat de alertă prin muchia food_interaction
        let labels = graph.map(Self.foodLabels) ?? [:]
        var grouped: [(label: String, meds: [String], severity: Severity)] = []
        for alert in shown where alert.kind == .food {
            guard let label = labels[alert.id] ?? Self.foodKey(alert) else { continue }
            let names = alert.medids.compactMap(name)
            if let i = grouped.firstIndex(where: { $0.label == label }) {
                for n in names where !grouped[i].meds.contains(n) { grouped[i].meds.append(n) }
            } else {
                grouped.append((label, names, alert.severity))
            }
        }
        foods = grouped.map {
            Food(label: Self.capitalized($0.label), meds: $0.meds.joined(separator: ", "), severity: $0.severity)
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
