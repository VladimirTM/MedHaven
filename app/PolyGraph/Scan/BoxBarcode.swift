import Foundation
import UIKit
import Vision

nonisolated enum BoxBarcode {
    static func readPhoto(_ image: UIImage) -> String? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.dataMatrix, .ean13, .ean8]
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: image.imageOrientation.cgOrientation)
        guard (try? handler.perform([request])) != nil else { return nil }

        let observations = request.results ?? []
        let matrixCodes = Set(observations.filter { $0.symbology == .dataMatrix }.compactMap {
            dataMatrixPayload($0)
        })
        if !matrixCodes.isEmpty { return matrixCodes.count == 1 ? matrixCodes.first : nil }

        // O poză poate conține mai multe cutii. Un singur GTIN liniar trebuie să fie neechivoc.
        let codes = Set(observations.compactMap { observation in
            observation.payloadStringValue.flatMap { linearPayload($0, symbology: observation.symbology) }
        })
        return codes.count == 1 ? codes.first : nil
    }

    static func dataMatrixPayload(_ observation: VNBarcodeObservation, text: String? = nil) -> String? {
        let rawBytes = observation.payloadData.flatMap { String(data: $0, encoding: .ascii) }
        return [rawBytes, text, observation.payloadStringValue].compactMap { $0 }.first {
            (try? GS1.parse($0)) != nil
        }
    }

    static func printedProductCode(_ lines: [OCRLine]) -> String? {
        let pattern = #/(?i)^PC[ :]*([0-9]{14})$/#
        let codes = Set(lines.compactMap { line -> String? in
            guard let match = line.text.wholeMatch(of: pattern) else { return nil }
            let gtin = String(match.1)
            return GS1.isValidGTIN(gtin) ? "01" + gtin : nil
        })
        return codes.count == 1 ? codes.first : nil
    }

    static func linearPayload(_ raw: String, symbology: VNBarcodeSymbology) -> String? {
        let gtin: String
        switch symbology {
        case .ean13 where raw.count == 13: gtin = "0" + raw
        case .ean8 where raw.count == 8: gtin = "000000" + raw
        default: return nil
        }
        guard GS1.isValidGTIN(gtin) else { return nil }
        // API-ul existent primește GTIN-ul în elementul GS1 01.
        return "01" + gtin
    }
}
