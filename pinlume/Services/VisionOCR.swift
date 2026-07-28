import Vision
import Dispatch

struct QRCodePayload: Equatable {
    let value: String

    var url: URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}

struct OCRScanResult {
    let text: String
    let qrCodes: [QRCodePayload]

    var copyText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return text }
        return qrCodes.map(\.value).joined(separator: "\n")
    }
}

enum VisionOCR {

    static func makeTextRecognitionRequest(
        completionHandler: @escaping (VNRequest, Error?) -> Void
    ) -> VNRecognizeTextRequest {
        makeTextRecognitionRequest(recognitionLevel: .accurate, completionHandler: completionHandler)
    }

    static func performTextRecognition(
        cgImage: CGImage,
        completionHandler: @escaping (VNRequest, Error?) -> Void
    ) {
        // Preserve accurate OCR when it works; fall back for platform model failures.
        performTextRecognition(
            cgImage: cgImage,
            recognitionLevel: .accurate,
            retryWithFastOnFailure: true,
            completionHandler: completionHandler)
    }

    static func performTextAndQRCodeRecognition(
        cgImage: CGImage,
        completionHandler: @escaping (OCRScanResult) -> Void
    ) {
        performTextRecognition(cgImage: cgImage) { request, _ in
            let text = recognizedText(from: request)
            let qrCodes = detectQRCodes(cgImage: cgImage)
            completionHandler(OCRScanResult(text: text, qrCodes: qrCodes))
        }
    }

    static func performStructuredTextRecognition(
        cgImage: CGImage,
        completionHandler: @escaping (Result<StructuredOCRResult, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            performTextRecognition(cgImage: cgImage) { request, error in
                let result: Result<StructuredOCRResult, Error>
                if let error {
                    result = .failure(error)
                } else {
                    result = .success(structuredResult(from: request))
                }
                DispatchQueue.main.async {
                    completionHandler(result)
                }
            }
        }
    }

    static func recognizedText(from request: VNRequest) -> String {
        let lines = (request.results as? [VNRecognizedTextObservation])?
            .compactMap { $0.topCandidates(1).first?.string } ?? []
        return lines.joined(separator: "\n")
    }

    static func structuredResult(from request: VNRequest) -> StructuredOCRResult {
        let blocks: [RecognizedTextBlock] = (request.results as? [VNRecognizedTextObservation])?.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedTextBlock(
                text: candidate.string,
                normalizedBoundingBox: observation.boundingBox,
                confidence: candidate.confidence,
                characterBoxes: characterBoxes(for: candidate))
        } ?? []
        return StructuredOCRResult(blocks: blocks)
    }

    private static func characterBoxes(for candidate: VNRecognizedText) -> [OCRTextCharacterBox] {
        let text = candidate.string
        var boxes: [OCRTextCharacterBox] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(after: start)
            let range = start..<end
            if let rectangle = try? candidate.boundingBox(for: range),
               rectangle.boundingBox.width > 0,
               rectangle.boundingBox.height > 0 {
                boxes.append(OCRTextCharacterBox(
                    utf16Range: NSRange(range, in: text),
                    normalizedBoundingBox: rectangle.boundingBox))
            }
            start = end
        }
        return boxes
    }

    static func detectQRCodes(cgImage: CGImage) -> [QRCodePayload] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .microQR]

        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            return []
        }

        var seen = Set<String>()
        return (request.results ?? []).compactMap { observation -> QRCodePayload? in
            guard observation.symbology == .qr || observation.symbology == .microQR,
                  let value = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  seen.insert(value).inserted else {
                return nil
            }
            return QRCodePayload(value: value)
        }
    }

    private static func performTextRecognition(
        cgImage: CGImage,
        recognitionLevel: VNRequestTextRecognitionLevel,
        retryWithFastOnFailure: Bool,
        completionHandler: @escaping (VNRequest, Error?) -> Void
    ) {
        let request = makeTextRecognitionRequest(recognitionLevel: recognitionLevel) { request, error in
            if retryWithFastOnFailure, error != nil {
                performTextRecognition(
                    cgImage: cgImage,
                    recognitionLevel: .fast,
                    retryWithFastOnFailure: false,
                    completionHandler: completionHandler)
                return
            }
            completionHandler(request, error)
        }

        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            if retryWithFastOnFailure {
                performTextRecognition(
                    cgImage: cgImage,
                    recognitionLevel: .fast,
                    retryWithFastOnFailure: false,
                    completionHandler: completionHandler)
            } else {
                completionHandler(request, error)
            }
        }
    }

    private static func makeTextRecognitionRequest(
        recognitionLevel: VNRequestTextRecognitionLevel,
        completionHandler: @escaping (VNRequest, Error?) -> Void
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest(completionHandler: completionHandler)
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }
        return request
    }

}
