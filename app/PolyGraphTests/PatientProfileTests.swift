import Foundation
import Testing
@testable import PolyGraph

/// Profilul de sănătate: etichetele afecțiunilor (aceleași ca în portal), citirea câmpurilor și PATCH-ul.
@MainActor
struct PatientProfileTests {
    private struct Labels: Decodable {
        struct Item: Decodable {
            let code: String
            let label: String
        }

        let conditions: [Item]
    }

    @Test func labelsAndOrderMatchTheContractFixture() throws {
        let fixture = try JSONDecoder().decode(Labels.self, from: ContractFiles.data("fixtures/conditions.json"))
        #expect(Condition.ordered.map(\.rawValue) == fixture.conditions.map(\.code))
        #expect(Condition.ordered.map(\.label) == fixture.conditions.map(\.label))
    }

    @Test func numbersAreReadTheWayPeopleWriteThem() {
        var profile = PatientProfile()
        profile.heightText = " 158 "
        profile.weightText = "64,5"
        #expect(profile.heightCm == 158)
        #expect(profile.weightKg == 64.5)
        #expect(profile.problem == nil)
        profile.heightText = "1,58"
        #expect(profile.problem?.contains("centimetri") == true)
        profile.heightText = ""
        profile.weightText = "400"
        #expect(profile.problem?.contains("kilograme") == true)
    }

    @Test func summaryCountsConditionsAndNote() {
        var profile = PatientProfile()
        #expect(profile.shortSummary.isEmpty)
        profile.heightText = "158"
        profile.weightText = "64"
        profile.conditions = [.hypertension, .falls]
        profile.note = "gută"
        #expect(profile.shortSummary == "1,58 m · 64 kg · 3 afecțiuni")
    }

    @Test func updateSendsNullsSoFieldsCanBeCleared() throws {
        var profile = PatientProfile()
        profile.conditions = [.falls, .hypertension]
        let data = try JSONEncoder().encode(ProfileUpdate(profile))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["height_cm"] is NSNull)
        #expect(json["weight_kg"] is NSNull)
        #expect(json["conditions_note"] is NSNull)
        // în ordinea din listă, nu în ordinea atingerilor
        #expect(json["conditions"] as? [String] == ["hypertension", "falls"])
    }
}
