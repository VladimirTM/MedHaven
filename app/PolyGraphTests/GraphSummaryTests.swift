import Foundation
import Testing
@testable import PolyGraph

/// „Pe scurt” de sub graf, pe fixture-ul demo (fără Fromilid).
@MainActor
struct GraphSummaryTests {
    private struct ExpectedAlerts: Decodable {
        let withoutMed09: [Alert]

        enum CodingKeys: String, CodingKey {
            case withoutMed09 = "without_med_09"
        }
    }

    private struct DemoPatient: Decodable {
        let meds: [MedicationItem]
    }

    private func demoSummary() throws -> GraphSummary {
        let alerts = try JSONCoding.decoder
            .decode(ExpectedAlerts.self, from: ContractFiles.data("fixtures/expected_alerts.json")).withoutMed09
        let meds = try JSONCoding.decoder
            .decode(DemoPatient.self, from: ContractFiles.data("fixtures/demo_patient.json")).meds
        return GraphSummary(alerts: alerts, graph: nil, meds: meds)
    }

    @Test func countsSeriousAndModeratePairsWithoutMinor() throws {
        let summary = try demoSummary()
        #expect(summary.serious.map(\.text) == ["Sintrom cu Nurofen", "Simvastatin LPH cu Amlodipină Actavis"])
        #expect(summary.moderateCount == 10)
    }

    @Test func hubIsTheMedInMostPairsPreferringSeriousOnTies() throws {
        // Nurofen, Euthyrox și Omeprazol au câte 4; Nurofen are și o combinație gravă
        let hub = try #require(try demoSummary().hub)
        #expect(hub.medID == "med_02")
        #expect(hub.name == "Nurofen")
        #expect(hub.count == 4)
    }

    @Test func foodsAreGroupedOnceWithAllTheirMeds() throws {
        let foods = try demoSummary().foods
        #expect(foods.count == 5)
        #expect(foods.first?.severity == .major)
        let alcohol = try #require(foods.first { $0.label == "Alcohol" })
        #expect(alcohol.meds == "Sintrom, Nurofen, Simvastatin LPH, Amitriptilin")
        #expect(foods.contains { $0.label == "Vitamin k" })
    }

    @Test func seriousPairsSayWhatHappensAndWhatToDo() throws {
        let first = try #require(try demoSummary().serious.first)
        #expect(first.alertID == "al_ddi_med_01_med_02")
        #expect(first.explanation == "Risc crescut de sângerare.")
        #expect(first.recommendation.hasPrefix("Discutați cu medicul cardiolog înainte de următoarea doză de Nurofen."))
    }

    @Test func moderatePairsExplainThemselvesEvenWhenTheTitleOnlyNamesThePair() throws {
        let moderate = try demoSummary().moderate
        #expect(moderate.first?.alertID == "al_ddi_med_01_med_05")
        #expect(moderate.first?.explanation == "Euthyrox-ul poate crește efectul Sintrom-ului.")
        // titlul „Simvastatină + omeprazol” nu explică nimic: se folosește prima propoziție din detaliu
        let simvaOmeprazol = try #require(moderate.first { $0.alertID == "al_ddi_med_03_med_07" })
        #expect(simvaOmeprazol.explanation == "Omeprazolul poate crește ușor concentrația de simvastatină.")
        // „DDInter nu dă un nivel” se sare; rămâne explicația analogiei, în cuvinte simple
        let ibuOmeprazol = try #require(moderate.first { $0.alertID == "al_ddi_med_02_med_07" })
        #expect(ibuOmeprazol.explanation.hasPrefix("Nu există date directe"))
        #expect(!moderate.contains { $0.explanation.contains("DDInter") })
    }

    @Test func hubCountsItsSeriousCombinations() throws {
        #expect(try demoSummary().hub?.serious == 1)
    }

    @Test func seriousFoodsCarryTheirAdvice() throws {
        let first = try #require(try demoSummary().foods.first)
        #expect(first.severity == .major)
        #expect(first.advice == "Evitați grepfrutul și sucul de grepfrut.")
    }

    @Test func sentenceAddsTheFinalPeriodOnlyOnce() {
        #expect(GraphSummary.sentence("Risc crescut de sângerare") == "Risc crescut de sângerare.")
        #expect(GraphSummary.sentence("Evitați alcoolul.") == "Evitați alcoolul.")
    }

    @Test func combinationWordsAgreeWithTheCount() {
        #expect(GraphSummary.combinations(1, "gravă", "grave") == "o combinație gravă")
        #expect(GraphSummary.combinations(2, "gravă", "grave") == "2 combinații grave")
        #expect(GraphSummary.combinations(20, "gravă", "grave") == "20 de combinații grave")
    }
}

/// Legenda substanțelor numerotate de sub graf. Aceleași numere le verifică `test_qa2_graph.py` pentru
/// `pgLegend` din `graph-core.js`, pe același exemplu: cercul din desen și rândul din legendă au același număr.
struct GraphLegendTests {
    private func demoLegend() throws -> GraphLegend {
        let graph = try JSONCoding.decoder.decode(Graph.self, from: ContractFiles.data("examples/graph.demo.json"))
        return GraphLegend(graph: graph)
    }

    @Test func substancesAreNumberedInTheOrderOfTheGraphNodes() throws {
        let items = try demoLegend().items
        #expect(items.count == 9)
        #expect(items.map(\.number) == Array(1...9))
        #expect(items.first?.id == "s:B01AA07")
        #expect(items.first?.products == ["Sintrom 4 mg"])
        #expect(items.first?.classes == ["antagoniști ai vitaminei K"])
        #expect(items.first?.severity == nil)
    }

    @Test func aProductWithTwoSubstancesGetsTwoNumbers() throws {
        let calcium = try demoLegend().items.filter { $0.products == ["Calcium + Vitamin D"] }
        #expect(calcium.map(\.number) == [6, 7])
        #expect(calcium.map(\.id) == ["s:A12AA04", "s:A11CC05"])
    }

    @Test func noGraphMeansNoLegend() {
        #expect(GraphLegend(graph: nil).isEmpty)
    }
}
