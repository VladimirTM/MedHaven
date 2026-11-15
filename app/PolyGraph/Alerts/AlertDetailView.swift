import Foundation
import SwiftUI

/// Detaliul unei alerte: ce înseamnă, ce puteți face, medicamentele, sursa, statusul.
/// Deschis din card, crește din el (zoom); închiderea interactivă o face sistemul.
struct AlertDetailView: View {
    let alertID: String

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = 0
    @State private var explanation: AlertExplanation?
    @State private var explaining = false
    @State private var explainFailed = false

    var body: some View {
        Group {
            if let alert = store.alert(id: alertID) {
                content(alert)
            } else {
                ContentUnavailableView(
                    "Alerta nu mai există",
                    systemImage: "checkmark.circle",
                    description: Text("Lista de medicamente s-a schimbat și alerta nu mai e valabilă."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: acknowledged)
        .accessibilityIdentifier("alertDetail")
    }

    private func content(_ alert: Alert) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(spacing: Spacing.xs) {
                        SeverityDot(severity: alert.severity)
                        Text(alert.severity.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(alert.severity.color)
                        if alert.isByAnalogy {
                            Text("· prin analogie")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(alert.title)
                        .font(.title2.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("alertDetail.header")
            }

            Section("Ce înseamnă") {
                Text(alert.detail)
                    .accessibilityIdentifier("alertDetail.detail")
            }

            explainSection(alert)

            Section("Ce puteți face") {
                Text(alert.recommendation)
                    .accessibilityIdentifier("alertDetail.recommendation")
            }

            // analogia de clasă e spusă o singură dată, la sfârșitul lui `detail` (vine așa de la server);
            // antetul are deja „· prin analogie” (Q3-33)

            let meds = alert.medids.compactMap { store.med(id: $0) }
            if !meds.isEmpty {
                Section("Medicamentele") {
                    ForEach(meds) { med in
                        NavigationLink(value: CaregiverRoute.med(id: med.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(med.displayName)
                                if !med.substanceNames.isEmpty {
                                    Text(med.substanceNames)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("alertDetail.med.\(med.id)")
                    }
                }
            }

            Section {
                LabeledContent("Status", value: statusText(alert))
                    .accessibilityIdentifier("alertDetail.status")
                if let resolution = alert.resolution, resolution.decision != nil || !resolution.note.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(resolution.by == .doctor ? "Decizia medicului de familie" : "Nota")
                            .font(.subheadline.weight(.semibold))
                        if let decision = resolution.decision {
                            Text(decision.label)
                        }
                        if !resolution.note.isEmpty {
                            Text(resolution.note)
                        }
                        Text(resolution.at.formatted(.dateTime.day().month(.wide).hour().minute().locale(PgFormat.romanian)))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("alertDetail.doctorNote")
                }
            } footer: {
                sourceFooter(alert.source)
            }

            Section {
                Button {
                    store.acknowledge(alertID: alert.id)
                    acknowledged += 1
                    dismiss()
                } label: {
                    Text("Am înțeles")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: ControlHeight.caregiver)
                }
                .pgProminentButton()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("alertDetail.understoodButton")
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func explainSection(_ alert: Alert) -> some View {
        Section {
            if let explanation {
                Text(explanation.text)
                    .accessibilityIdentifier("alertDetail.aiText")
            } else {
                Button {
                    Task { await explain(alert) }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if explaining {
                            ProgressView()
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text(explaining ? "Pregătesc explicația…" : "Explică pe înțeles")
                    }
                }
                .disabled(explaining)
                .accessibilityIdentifier("alertDetail.explainButton")
                if explainFailed {
                    Text("Nu am putut pregăti explicația. Încercați din nou.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Pe înțeles")
        } footer: {
            if let explanation {
                Text(explanation.ai
                    ? "Reformulat de AI (Gemini) doar din datele alertei. Decizia vine din baza de date de mai jos."
                    : "Textul aplicației, fără AI.")
            }
        }
    }

    private func explain(_ alert: Alert) async {
        guard let id = store.settings.patientID else { return }
        explaining = true
        explainFailed = false
        defer { explaining = false }
        do {
            let result = try await store.api.explainAlert(patientID: id, alertID: alert.id)
            withPgAnimation(.pgStandard) { explanation = result }
        } catch {
            explainFailed = true
        }
    }

    private func statusText(_ alert: Alert) -> String {
        if alert.status == .statusOpen && store.acknowledgedAlertIDs.contains(alert.id) {
            return "Văzută de dumneavoastră"
        }
        return alert.status.label
    }

    @ViewBuilder
    private func sourceFooter(_ source: Source) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Sursa: \(source.displayName)")
            if let link = source.url.flatMap(URL.init(string:)) {
                Link("Deschide sursa", destination: link)
            }
        }
        .font(.footnote)
        .accessibilityIdentifier("alertDetail.source")
    }
}
