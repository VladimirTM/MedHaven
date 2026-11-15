import OSLog
import SwiftUI

/// Setări → „Profilul de sănătate”: înălțimea, greutatea și afecțiunile. „Salvează” trimite PATCH /patients cu tot
/// profilul (câmpurile golite devin `null`). Medicul de familie îl vede în portal și pe fișa tipărită.
struct PatientProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var profile = PatientProfile()
    @State private var original = PatientProfile()
    @State private var loaded = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var savedCount = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                HealthProfileFields(profile: $profile, idPrefix: "profile")
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.body)
                        .foregroundStyle(PgColor.error)
                        .accessibilityIdentifier("profile.error")
                }
                SeniorButton(isSaving ? "Se salvează…" : "Salvează", identifier: "profile.saveButton") {
                    Task { await save() }
                }
                .disabled(isSaving || profile == original || profile.problem != nil)
            }
            .padding(Spacing.m)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(PgColor.background)
        .navigationTitle("Profilul de sănătate")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: savedCount)
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded, let patient = store.patient else { return }
        loaded = true
        profile = PatientProfile(patient)
        original = profile
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            try await store.updateProfile(profile)
            savedCount += 1
            Log.settings.info("profilul de sănătate salvat")
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Nu am putut salva. Încercați din nou."
        }
    }
}
