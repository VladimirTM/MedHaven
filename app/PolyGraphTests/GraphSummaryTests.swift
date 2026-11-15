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

    @Test func combinationWordsAgreeWithTheCount() {
        #expect(GraphSummary.combinations(1, "gravă", "grave") == "o combinație gravă")
        #expect(GraphSummary.combinations(2, "gravă", "grave") == "2 combinații grave")
        #expect(GraphSummary.combinations(20, "gravă", "grave") == "20 de combinații grave")
    }
}
