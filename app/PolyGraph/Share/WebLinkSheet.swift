import OSLog
import SwiftUI
import UIKit

/// E2: „Deschide pe web”. Linkul către pagina familiei (Azi, Medicamentele mele, De verificat, Orele zilei), ca QR
/// de scanat cu alt dispozitiv sau copiat. Merge o singură dată și 10 minute; după aceea browserul ține minte
/// pacientul 30 de zile.
struct WebLinkSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading
    @State private var copied = 0
    private let qrSide: CGFloat = 240

    private enum Phase {
        case loading
        case ready(url: URL, image: UIImage, expiresAt: Date)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.m) {
                    switch phase {
                    case .loading:
                        ProgressView("Pregătesc linkul…")
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, minHeight: qrSide)
                            .accessibilityIdentifier("web.loading")
                    case let .ready(url, image, expiresAt):
                        ready(url: url, image: image, expiresAt: expiresAt)
                    case .failed(let message):
                        ContentUnavailableView {
                            Label("Nu am putut pregăti linkul", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(message)
                        } actions: {
                            Button("Încearcă din nou") { Task { await load() } }
                                .pgProminentButton()
                                .accessibilityIdentifier("web.retryButton")
                        }
                        .accessibilityIdentifier("web.error")
                    }
                }
                .padding(Spacing.m)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Deschide pe web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gata") { dismiss() }
                        .pgBarButton()
                        .accessibilityIdentifier("web.doneButton")
                }
            }
            .sensoryFeedback(.success, trigger: copied)
        }
        .task { await load() }
    }

    private func ready(url: URL, image: UIImage, expiresAt: Date) -> some View {
        VStack(spacing: Spacing.m) {
            Text("Scanați codul cu telefonul, tableta sau laptopul pe care vreți să vedeți programul.")
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: qrSide, height: qrSide)
                .padding(Spacing.m)
                // alb și în dark mode: camerele citesc codul doar pe fundal deschis
                .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .accessibilityLabel("Cod QR pentru pagina familiei")
                .accessibilityIdentifier("web.qr")
            Text("Linkul merge o singură dată, \(PgFormat.validUntil(expiresAt, now: Date()).lowercased()).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("web.expiry")
            Button {
                UIPasteboard.general.url = url
                copied += 1
            } label: {
                Label(copied > 0 ? "Copiat" : "Copiază linkul", systemImage: copied > 0 ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityIdentifier("web.copyButton")
            Button("Alt link") { Task { await load() } }
                .frame(minHeight: 44)
                .accessibilityIdentifier("web.newLinkButton")
        }
    }

    private func load() async {
        phase = .loading
        copied = 0
        do {
            let link = try await store.createWebLink()
            guard let url = store.api.webPageURL(link.url), let image = QRCode.image(for: url.absoluteString)
            else { throw Failure.qrCode }
            withPgAnimation(.pgStandard) {
                phase = .ready(url: url, image: image, expiresAt: link.expiresAt)
            }
        } catch {
            Log.share.error("web-link: \(String(describing: error), privacy: .public)")
            phase = .failed((error as? LocalizedError)?.errorDescription ?? "Verificați legătura cu serverul și încercați din nou.")
        }
    }

    private enum Failure: LocalizedError {
        case qrCode
        var errorDescription: String? { "Nu am putut desena codul. Încercați din nou." }
    }
}
