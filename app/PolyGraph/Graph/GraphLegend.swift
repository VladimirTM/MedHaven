import Foundation

/// Legenda substanțelor de sub graf. În desen, fiecare substanță activă e un cerc cu un număr (numele lor
/// lungi se suprapuneau cu ale medicamentelor); aici apar numărul, numele, medicamentul din care vine și clasa ei.
/// Numerele urmează ordinea substanțelor în `graph.nodes` (backend-ul pune fiecare substanță după medicamentul ei),
/// aceeași regulă ca `pgLegend` din `graph-core.js`.
struct GraphLegend {
    struct Item: Identifiable {
        let number: Int
        /// `s:<ATC5>`
        let id: String
        /// „acenocumarol”
        let name: String
        /// cea mai gravă alertă a substanței; colorează bordura cercului, ca în graf
        let severity: Severity?
        /// „Sintrom 4 mg”
        let products: [String]
        /// „antagoniști ai vitaminei K”
        let classes: [String]
    }

    let items: [Item]

    var isEmpty: Bool { items.isEmpty }

    init(graph: Graph?) {
        guard let graph else {
            items = []
            return
        }
        let nodes = graph.nodes.map(\.data)
        let labels = Dictionary(nodes.map { ($0.id, $0.label) }, uniquingKeysWith: { first, _ in first })
        let substances = nodes.filter { $0.type == .substance }
        var products: [String: [String]] = [:]
        var classes: [String: [String]] = [:]
        for edge in graph.edges.map(\.data) {
            switch edge.type {
            case .contains:
                if let label = labels[edge.source] { products[edge.target, default: []].append(label) }
            case .inClass:
                if let label = labels[edge.target] { classes[edge.source, default: []].append(label) }
            default:
                break
            }
        }
        items = substances.enumerated().map { index, node in
            Item(
                number: index + 1, id: node.id, name: node.label, severity: node.severity,
                products: products[node.id] ?? [], classes: classes[node.id] ?? [])
        }
    }
}
