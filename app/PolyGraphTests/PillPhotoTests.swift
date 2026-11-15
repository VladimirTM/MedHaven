import Foundation
import Testing
import UIKit
@testable import PolyGraph

/// E5: poza pastilei. Decodarea câmpului opțional, corpul multipart, textele și micșorarea înainte de trimitere.
/// T-E5-02 (Dynamic Type AX5 pe „Acum”, cu și fără poză) rămâne de verificat pe iPhone / în turul de review.
@MainActor
struct PillPhotoTests {
    private func demoMed(_ id: String = "med_01") throws -> [String: Any] {
        let data = try ContractFiles.data("fixtures/demo_patient.json")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let meds = try #require(root["meds"] as? [[String: Any]])
        return try #require(meds.first { $0["id"] as? String == id })
    }

    @Test func missingPillPhotoDecodesAsNilAndIsNotSent() throws {
        let raw = try demoMed()
        #expect(raw["pill_photo_url"] == nil, "Pacientul demo nu are poze de pastile")
        let med = try JSONCoding.decoder.decode(MedicationItem.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(med.pillPhotourl == nil)
        let sent = try #require(try JSONSerialization.jsonObject(with: JSONCoding.medicationBody(med)) as? [String: Any])
        #expect(sent["pill_photo_url"] == nil, "POST /meds nu trimite cheia când nu există poză")
    }

    @Test func pillPhotoDecodesAndSurvivesTheRoundTrip() throws {
        var raw = try demoMed()
        raw["pill_photo_url"] = "/media/\(String(repeating: "a", count: 64)).jpg"
        let med = try JSONCoding.decoder.decode(MedicationItem.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(med.pillPhotourl == raw["pill_photo_url"] as? String)
        let again = try JSONCoding.decoder.decode(MedicationItem.self, from: JSONCoding.encoder.encode(med))
        #expect(again.pillPhotourl == med.pillPhotourl)
    }

    @Test func explicitNullDecodesAsNil() throws {
        var raw = try demoMed()
        raw["pill_photo_url"] = NSNull()
        let med = try JSONCoding.decoder.decode(MedicationItem.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(med.pillPhotourl == nil)
    }

    @Test func blankItemHasNoPillPhoto() {
        #expect(MedDraft.blankItem().pillPhotourl == nil)
    }

    @Test func uploadBodyIsOneJPEGField() {
        let form = APIClient.pillPhotoForm(jpeg: Data([0xFF, 0xD8, 0xFF]), boundary: "B")
        let text = String(decoding: form.encoded(), as: UTF8.self)
        #expect(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"image\"; filename=\"pastila.jpg\"\r\n"))
        #expect(text.contains("Content-Type: image/jpeg\r\n\r\n"))
        #expect(text.hasSuffix("--B--\r\n"))
        #expect(form.contentType == "multipart/form-data; boundary=B")
    }

    @Test func mediaURLIsBuiltFromThePhonesServerAddress() {
        let api = APIClient(baseURL: URL(string: "http://192.168.1.10:8000"), token: "t")
        #expect(api.mediaURL("/media/abc.jpg")?.absoluteString == "http://192.168.1.10:8000/media/abc.jpg")
        #expect(api.mediaURL(nil) == nil)
    }

    @Test func wording() {
        #expect(PillPhoto.accessibilityLabel(brand: "Sintrom") == "Pastila de Sintrom")
        #expect(PillPhoto.hint == "Puneți o pastilă pe o suprafață deschisă la culoare, lângă cutie.")
        #expect(PillPhoto.boxCaption == "Cutia" && PillPhoto.pillCaption == "Pastila")
    }

    @Test func bigPhotoIsShrunkBeforeUpload() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        }
        let data = try #require(PillPhoto.jpeg(image))
        let decoded = try #require(UIImage(data: data))
        #expect(max(decoded.size.width, decoded.size.height) == 1600)
        #expect(data.count < 5 * 1024 * 1024)
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
    }
}
