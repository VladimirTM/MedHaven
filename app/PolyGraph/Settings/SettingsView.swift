import SwiftUI
import OSLog

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL = ""
    @State private var connectionStatus: String?
    @State private var isChecking = false
    @State private var isResettingDemo = false
    @State private var confirmSignOut = false
    /// rolul ales în foaie; se aplică abia la „Gata”, ca stiva deschisă să nu dispară sub deget (Q3-39)
    @State private var pendingRole: AppRole = .senior
    @State private var demoAction: DemoAction?
    @State private var demoStatus: String?
    /// mesajul de succes al rețetei ORL rămâne pe ecran și dacă butonul e apăsat din nou (Q3-20)
    @State private var prescriptionStatus: String?
    @State private var webLinkPresented = false
    /// „Avansat” (serverul, modul demo) e deschis singur doar cât telefonul nu e legat de un pacient
    @State private var advancedExpanded = false

    private enum DemoAction {
        case prescription
        case missedDose
    }

    var body: some View {
        @Bindable var settings = store.settings

        NavigationStack {
            Form {
                if settings.isSignedIn {
                    Section("Pacient") {
                        if let patient = store.patient {
                            LabeledContent("Nume", value: patient.name)
                            LabeledContent("Anul nașterii", value: String(patient.birthYear))
                        }
                        NavigationLink {
                            PatientProfileView()
                        } label: {
                            LabeledContent("Profilul de sănătate", value: profileSummary)
                        }
                        .accessibilityIdentifier("settings.profileButton")
                        if pendingRole == .caregiver {
                            NavigationLink {
                                DayHoursView()
                            } label: {
                                LabeledContent("Orele zilei", value: anchorsSummary)
                            }
                            .accessibilityIdentifier("settings.dayHoursButton")
                        }
                    }
                }

                Section {
                    Picker("Cine folosește telefonul", selection: $pendingRole) {
                        ForEach(AppRole.allCases) { role in
                            Text(role.title).tag(role)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.rolePicker")
                } header: {
                    Text("Cine folosește telefonul")
                } footer: {
                    Text(pendingRole == settings.role
                        ? "Pacient: un singur ecran, cu butoane mari. Aparținător: lista, alertele, graful și noutățile."
                        : "Modul se schimbă când apăsați „Gata”.")
                }

                if pendingRole == .senior {
                    Section {
                        Toggle("Citește cu voce tare la deschidere", isOn: $settings.speakOnOpen)
                            .accessibilityIdentifier("settings.speakOnOpenToggle")
                    } footer: {
                        Text("Ecranul „Acum” spune ce pastile urmează. Butonul cu difuzor le citește oricând.")
                    }
                }

                if settings.isSignedIn {
                    Section {
                        Button {
                            saveBaseURL()
                            webLinkPresented = true
                        } label: {
                            Label("Deschide pe web", systemImage: "safari")
                        }
                        .accessibilityIdentifier("settings.openWebButton")
                    } footer: {
                        Text("Programul de azi, medicamentele și ce e de verificat, pe alt telefon, pe o tabletă sau pe laptop.")
                    }
                }

                if settings.demoMode {
                    Section {
                        Button {
                            Task { await useDemoPatient() }
                        } label: {
                            HStack {
                                Text("Folosește pacientul demo")
                                Spacer()
                                if isResettingDemo { ProgressView() }
                            }
                        }
                        .disabled(isResettingDemo)
                        .accessibilityIdentifier("settings.useDemoPatientButton")
                        if settings.isSignedIn {
                            demoButton("Adaugă rețeta ORL (Fromilid)", action: .prescription)
                                .accessibilityIdentifier("settings.addRxButton")
                            demoButton("Simulează o doză ratată", action: .missedDose)
                                .accessibilityIdentifier("settings.missedDoseButton")
                        }
                        if let demoStatus {
                            Text(demoStatus)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("settings.demoStatus")
                        }
                    } header: {
                        Text("Demo")
                    } footer: {
                        Text("Pacientul demo e refăcut pe server cu lista inițială de medicamente. Rețeta ORL e medicul nou din scenariu; doza ratată apare la aparținător în Noutăți.")
                    }
                }

                if settings.isSignedIn {
                    Section {
                        Button("Deconectează telefonul", role: .destructive) {
                            confirmSignOut = true
                        }
                        .accessibilityIdentifier("settings.signOutButton")
                    }
                }

                // adresa serverului și modul demo țin de instalare, nu de folosirea zilnică: restrânse, la final
                Section {
                    DisclosureGroup(isExpanded: $advancedExpanded) {
                        TextField("http://192.168.1.10:8001", text: $baseURL)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(saveBaseURL)
                            .accessibilityLabel("Adresa serverului")
                            .accessibilityIdentifier("settings.baseURLField")
                        Button {
                            Task { await checkConnection() }
                        } label: {
                            HStack {
                                Text("Verifică legătura")
                                Spacer()
                                if isChecking { ProgressView() }
                            }
                        }
                        .disabled(isChecking)
                        .accessibilityIdentifier("settings.checkConnectionButton")
                        if let connectionStatus {
                            Text(connectionStatus)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("settings.connectionStatus")
                        }
                        Toggle("Mod demo", isOn: $settings.demoMode)
                            .accessibilityIdentifier("settings.demoModeToggle")
                    } label: {
                        // Q4-03: pe DisclosureGroup, identificatorul trecea și pe câmpurile din interior
                        Text("Avansat")
                            .accessibilityIdentifier("settings.advancedToggle")
                    }
                } footer: {
                    if advancedExpanded {
                        Text("Adresa serverului: pe telefon, adresa Mac-ului din aceeași rețea Wi-Fi, cu portul afișat de „make demo”; pe simulator, http://127.0.0.1 cu același port.")
                    }
                }
            }
            .navigationTitle("Setări")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Gata") {
                        saveBaseURL()
                        if store.settings.role != pendingRole { store.settings.role = pendingRole }
                        dismiss()
                    }
                    .pgBarButton()
                    .accessibilityIdentifier("settings.doneButton")
                }
            }
            .sheet(isPresented: $webLinkPresented) {
                WebLinkSheet()
                    .environment(store)
            }
            .confirmationDialog(
                "Deconectați telefonul?",
                isPresented: $confirmSignOut,
                titleVisibility: .visible
            ) {
                Button("Deconectează", role: .destructive) {
                    store.signOut()
                    dismiss()
                }
                .accessibilityIdentifier("settings.confirmSignOutButton")
            } message: {
                Text("Datele rămân pe server. Telefonul va porni din nou de la început.")
            }
        }
        .onAppear {
            baseURL = store.settings.baseURLString
            pendingRole = store.settings.role
            advancedExpanded = !store.settings.isSignedIn
        }
    }

    /// „1,65 m · 68 kg · 3 afecțiuni”; gol dacă nu e completat nimic
    private var profileSummary: String {
        guard let patient = store.patient else { return "" }
        return PatientProfile(patient).shortSummary
    }

    /// „07:00–22:30”: de la trezire la culcare
    private var anchorsSummary: String {
        guard let anchors = store.patient?.anchors else { return "" }
        return "\(anchors.wake)–\(anchors.bed)"
    }

    private func saveBaseURL() {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != store.settings.baseURLString else { return }
        store.settings.baseURLString = trimmed
        Log.settings.info("baseURL = \(trimmed, privacy: .public)")
    }

    private func checkConnection() async {
        saveBaseURL()
        isChecking = true
        defer { isChecking = false }
        do {
            let status = try await APIClient(baseURL: store.settings.baseURL, token: nil).health()
            connectionStatus = status.ok
                ? "Serverul răspunde\(status.mode.map { " (\($0))" } ?? "")."
                : "Serverul răspunde, dar nu e pregătit."
        } catch {
            connectionStatus = (error as? LocalizedError)?.errorDescription ?? "Nu pot ajunge la server."
        }
    }

    private func demoButton(_ title: String, action: DemoAction) -> some View {
        Button {
            // dezactivat sincron, înainte de Task: a doua atingere rapidă nu mai pornește nimic (Q3-20)
            guard demoAction == nil else { return }
            demoAction = action
            Task { await run(action) }
        } label: {
            HStack {
                Text(title)
                Spacer()
                if demoAction == action { ProgressView() }
            }
        }
        .disabled(demoAction != nil || isResettingDemo)
    }

    private func run(_ action: DemoAction) async {
        saveBaseURL()
        demoAction = action
        defer { demoAction = nil }
        do {
            switch action {
            case .prescription:
                if let newAlerts = try await store.addDemoPrescription() {
                    prescriptionStatus = Self.prescriptionText(newAlerts)
                    demoStatus = prescriptionStatus
                } else {
                    demoStatus = prescriptionStatus ?? "Fromilid e deja în listă."
                }
            case .missedDose:
                try await store.simulateMissedDose()
                demoStatus = "Am trimis o doză ratată. Apare în Noutăți în câteva secunde."
            }
        } catch {
            demoStatus = (error as? LocalizedError)?.errorDescription ?? "Nu a mers. Verificați serverul."
        }
    }

    /// „Am adăugat Fromilid. 2 alerte grave noi și 2 de discutat.” (numărate ca în portal, Q3-27)
    static func prescriptionText(_ newAlerts: NewAlerts) -> String {
        "Am adăugat Fromilid. \(newAlerts.sentence)."
    }

    private func useDemoPatient() async {
        prescriptionStatus = nil
        saveBaseURL()
        isResettingDemo = true
        defer { isResettingDemo = false }
        await store.useDemoPatient()
    }
}

private struct SettingsToolbar: ViewModifier {
    @Environment(AppStore.self) private var store
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresented = true
                    } label: {
                        Label("Setări", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settings.openButton")
                }
            }
            .sheet(isPresented: $isPresented) {
                SettingsView()
                    .environment(store)
            }
    }
}

extension View {
    /// Butonul de Setări din bara de navigare (rotița), cu foaia de setări.
    func pgSettingsToolbar() -> some View {
        modifier(SettingsToolbar())
    }
}
