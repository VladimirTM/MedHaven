import Foundation
import Testing
@testable import PolyGraph

/// „Fișa de urgență” și „Am o programare”, pe medicamentele pacientului demo (fără Fromilid):
/// Sintrom (B01AA07), Nurofen (M01AE01), Simvastatin, Amlodipină, Euthyrox, Calcium + Vitamin D, Omeprazol,
/// Amitriptilin.
@MainActor
struct SafetyTests {
    private struct DemoPatient: Decodable {
        let meds: [MedicationItem]
    }

    private func demoMeds() throws -> [MedicationItem] {
        try JSONCoding.decoder
            .decode(DemoPatient.self, from: ContractFiles.data("fixtures/demo_patient.json")).meds
    }

    private func demoCard() throws -> EmergencyCard {
        EmergencyCard(patient: nil, meds: try demoMeds(), analysis: nil, now: Date())
    }

    // MARK: - Grupele

    @Test func groupsMatchByAtcPrefix() throws {
        let meds = try demoMeds()
        #expect(MedGroup.anticoagulant.meds(in: meds).map(\.product.brand) == ["Sintrom"])
        #expect(MedGroup.nsaid.meds(in: meds).map(\.product.brand) == ["Nurofen"])
        #expect(MedGroup.antiplatelet.meds(in: meds).isEmpty)
        #expect(MedGroup.metformin.meds(in: meds).isEmpty)
    }

    // MARK: - Fișa de urgență

    @Test func emergencyCardPutsTheAnticoagulantFirst() throws {
        let card = try demoCard()
        #expect(card.flags.map(\.id) == ["anticoagulant"])
        #expect(card.flags.first?.meds == ["Sintrom 4 mg"])
        #expect(card.flags.first?.title == "Ia un anticoagulant (subțiază sângele)")
    }

    @Test func emergencyCardListsEveryMedWithItsDosage() throws {
        let card = try demoCard()
        #expect(card.meds.count == 8)
        let sintrom = try #require(card.meds.first)
        #expect(sintrom.name == "Sintrom 4 mg")
        #expect(!sintrom.dosage.isEmpty)
        // OTC-ul (Nurofen, fără medic) apare ca atare
        let nurofen = try #require(card.meds.first { $0.name.hasPrefix("Nurofen") })
        #expect(nurofen.prescriber == "fără rețetă")
    }

    @Test func emergencyCardWithoutPatientStillWorks() throws {
        let card = try demoCard()
        #expect(card.patientName == "Pacientul")
        #expect(card.ageText == nil)
        #expect(card.contact == nil)
        #expect(card.warnings.isEmpty)
    }

    @Test func emergencyPlainTextHasTheImportantPartsInOrder() throws {
        let text = try demoCard().plainText
        let important = try #require(text.range(of: "IMPORTANT"))
        let meds = try #require(text.range(of: "MEDICAMENTE (8)"))
        #expect(important.lowerBound < meds.lowerBound)
        #expect(text.contains("Ia un anticoagulant (subțiază sângele): Sintrom 4 mg"))
        #expect(text.hasSuffix(EmergencyCard.disclaimer))
    }

    @Test func namesAreJoinedInRomanian() {
        #expect(EmergencyCard.joined([]) == "")
        #expect(EmergencyCard.joined(["Sintrom"]) == "Sintrom")
        #expect(EmergencyCard.joined(["Sintrom", "Nurofen"]) == "Sintrom și Nurofen")
        #expect(EmergencyCard.joined(["Sintrom", "Nurofen", "Aspenter"]) == "Sintrom, Nurofen și Aspenter")
    }

    // MARK: - Am o programare

    @Test func dentistAsksAboutTheBloodThinnerAndTheNsaid() throws {
        let prep = ProcedurePrep(procedure: .dentist, meds: try demoMeds())
        #expect(prep.items.map(\.id) == ["anticoagulant", "nsaid"])
        #expect(prep.items.first?.meds == ["Sintrom 4 mg"])
    }

    @Test func eachProcedureFindsWhatMattersForIt() throws {
        let meds = try demoMeds()
        #expect(ProcedurePrep(procedure: .surgery, meds: meds).items.map(\.id) == ["anticoagulant", "nsaid"])
        #expect(ProcedurePrep(procedure: .endoscopy, meds: meds).items.map(\.id) == ["anticoagulant"])
        #expect(ProcedurePrep(procedure: .contrast, meds: meds).items.map(\.id) == ["nsaid"])
    }

    @Test func nothingFoundStillSaysToTellTheDoctor() {
        let prep = ProcedurePrep(procedure: .dentist, meds: [])
        #expect(prep.isEmpty)
        let text = prep.plainText(patientName: "Maria")
        #expect(text.contains(prep.noneText))
        #expect(text.contains("Doar medicul decide"))
    }

    /// Regula de siguranță din 2.4: nicio formulare de oprire și nicio doză în texte.
    @Test func textsNeverTellToStopAMedicine() {
        let forbidden = ["opriți", "oprește", "nu mai luați", "întrerupeți", "renunțați"]
        var texts = MedGroup.allCases.map(\.plainName) + MedGroup.allCases.map(EmergencyCard.flagTitle)
        for procedure in Procedure.allCases {
            texts += ProcedurePrep.rules(for: procedure).map(\.reason)
            let prep = ProcedurePrep(procedure: procedure, meds: [])
            texts += [prep.closing, prep.noneText, procedure.title, procedure.examples]
        }
        texts.append(EmergencyCard.disclaimer)
        let hits = texts.filter { text in forbidden.contains { text.lowercased().contains($0) } }
        #expect(hits.isEmpty, "Formulări interzise: \(hits)")
    }
}
