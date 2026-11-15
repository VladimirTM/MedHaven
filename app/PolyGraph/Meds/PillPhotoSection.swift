import OSLog
import SwiftUI
import UIKit

/// E5: textele și regulile pozei pastilei, în afara view-urilor (testate în `PillPhotoTests`).
/// Pastila o fotografiază familia; nu se recunoaște și nu se desenează: fără poză, nu apare nimic în locul ei.
nonisolated enum PillPhoto {
    static let hint = "Puneți o pastilă pe o suprafață deschisă la culoare, lângă cutie."
    static let boxCaption = "Cutia"
    static let pillCaption = "Pastila"

    static func accessibilityLabel(brand: String) -> String {
        "Pastila de \(brand)"
    }

    /// Latura lungă ≤ 1600 px, JPEG 0.8 (ca la /scan): o poză de 48 MP nu trece altfel de limita de 5 MB.
    static func jpeg(_ image: UIImage) -> Data? {
        ImageUpload.jpeg(image)
    }
}

/// Secțiunea „Pastila” din detaliul medicamentului (doar aparținătorul): poza, „Fotografiați o pastilă”, „Șterge poza”.
struct PillPhotoSection: View {
    let med: MedicationItem

    @Environment(AppStore.self) private var store
    @State private var isTaking = false
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        Section {
            if let url = store.api.mediaURL(med.pillPhotourl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    case .failure:
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    default:
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 240)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .accessibilityLabel(PillPhoto.accessibilityLabel(brand: med.product.brand))
                .accessibilityIdentifier("medDetail.pillPhoto")
            }
            Button {
                errorText = nil
                isTaking = true
            } label: {
                Label(med.pillPhotourl == nil ? "Fotografiați o pastilă" : "Fotografiați din nou", systemImage: "camera")
            }
            .disabled(isWorking)
            .accessibilityIdentifier("medDetail.pillPhotoButton")
            // pe buton, nu pe Section: modificatorii de pe o secțiune din List se aplică fiecărui rând
            .sensoryFeedback(.error, trigger: errorText) { _, new in new != nil }
            .fullScreenCover(isPresented: $isTaking) {
                PillCameraView { image in
                    isTaking = false
                    if let image {
                        Task { await upload(image) }
                    }
                }
                .ignoresSafeArea()
            }
            if med.pillPhotourl != nil {
                Button("Șterge poza", systemImage: "trash", role: .destructive) {
                    Task { await deletePhoto() }
                }
                .disabled(isWorking)
                .accessibilityIdentifier("medDetail.pillPhotoDeleteButton")
            }
            if isWorking {
                HStack(spacing: Spacing.s) {
                    ProgressView()
                    Text("Trimit poza…")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("medDetail.pillPhotoWorking")
            }
            if let errorText {
                Text(errorText)
                    .foregroundStyle(PgColor.error)
                    .accessibilityIdentifier("medDetail.pillPhotoError")
            }
        } header: {
            Text(PillPhoto.pillCaption)
        } footer: {
            Text(PillPhoto.hint)
                .accessibilityIdentifier("medDetail.pillPhotoHint")
        }
    }

    private func upload(_ image: UIImage) async {
        guard let jpeg = PillPhoto.jpeg(image) else {
            errorText = "Nu am putut pregăti poza. Încercați din nou."
            return
        }
        await run { try await store.setPillPhoto(medID: med.id, jpeg: jpeg) }
    }

    private func deletePhoto() async {
        await run { try await store.deletePillPhoto(medID: med.id) }
    }

    private func run(_ work: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            errorText = nil
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "Nu am putut salva poza. Încercați din nou."
            Log.app.error("Poza pastilei: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Camera de sistem pentru poza pastilei; pe simulator (fără cameră) se deschide galeria.
struct PillCameraView: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void

    static var sourceType: UIImagePickerController.SourceType {
        UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = Self.sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: PillCameraView

        init(parent: PillCameraView) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.onFinish(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onFinish(nil)
        }
    }
}
