import SwiftUI
import OSLog

/// Un pas pe ecran, butonul principal jos, progresul („Pasul 2 din 4”) sus. La final: POST /v1/patients.
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        /// prezentarea MedHaven: logo, fraza de pe pagina web, cele trei roluri, „Să începem”
        case intro = -1
        /// alegerea rolului
        case welcome, name, birthYear
        /// înălțimea, greutatea și afecțiunile, opționale
        case health
        case meals, bedtime

        /// pașii numărați în „Pasul n din 5” (prezentarea și alegerea rolului nu se numără)
        static let countedSteps = 5
    }

    @Environment(AppStore.self) private var store
    @Environment(\.pgReduceMotion) private var reduceMotion

    @State private var step: Step = .intro
    @State private var movingForward = true
    @State private var role: AppRole = .senior
    @State private var name = ""
    @State private var birthYear = 1948
    @State private var health = PatientProfile()
    @State private var wake = PgFormat.date(fromClock: "07:00") ?? .now
    @State private var breakfast = PgFormat.date(fromClock: "08:00") ?? .now
    @State private var lunch = PgFormat.date(fromClock: "13:00") ?? .now
    @State private var dinner = PgFormat.date(fromClock: "19:00") ?? .now
    @State private var bedtime = PgFormat.date(fromClock: "22:00") ?? .now
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var settingsPresented = false
    /// prezentarea apare o singură dată, în cascadă; la revenirea din „Pentru cine?” rămâne pe loc
    @State private var introShown = false
    @FocusState private var nameFocused: Bool

    @ScaledMetric(relativeTo: .title2) private var fieldSize: CGFloat = 22
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize: CGFloat = 112
    @ScaledMetric(relativeTo: .title3) private var featureIconSize: CGFloat = 48
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if step.rawValue > 0 {
                    progressHeader
                }
                // la mărimile de accesibilitate butoanele intră în scroll, după întrebare: fixate jos, o acopereau (Q3-22)
                ScrollView {
                    stepContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.m)
                        .id(step)
                        .transition(stepTransition)
                    if dynamicTypeSize.isAccessibilitySize {
                        bottomBar
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                if !dynamicTypeSize.isAccessibilitySize {
                    bottomBar
                }
            }
            .background(PgColor.background)
            .toolbar {
                if step != .intro {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            go(to: Step(rawValue: step.rawValue - 1) ?? .welcome)
                        } label: {
                            Label("Înapoi", systemImage: "chevron.backward")
                                .labelStyle(.titleAndIcon)
                        }
                        .accessibilityIdentifier("onboarding.backButton")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        settingsPresented = true
                    } label: {
                        Label("Setări", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settings.openButton")
                }
            }
            .sheet(isPresented: $settingsPresented) {
                SettingsView()
                    .environment(store)
            }
            .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        }
    }

    // MARK: - Părți

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Pasul \(step.rawValue) din \(Step.countedSteps)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PgColor.textSecondary)
            ProgressView(value: Double(step.rawValue), total: Double(Step.countedSteps))
                .tint(PgColor.accent)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.progress")
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .intro: introStep
        case .welcome: welcomeStep
        case .name: nameStep
        case .birthYear: birthYearStep
        case .health: healthStep
        case .meals: mealsStep
        case .bedtime: bedtimeStep
        }
    }

    // MARK: - Prezentarea

    private var introStep: some View {
        VStack(spacing: Spacing.l) {
            VStack(spacing: Spacing.m) {
                let side = min(logoSize, 160)
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: side * Radius.logoRatio, style: .continuous))
                    .accessibilityHidden(true)
                    .introReveal(introShown, order: 0, reduceMotion: reduceMotion)
                VStack(spacing: Spacing.xs) {
                    Text("MedHaven")
                        .font(.largeTitle.bold())
                        .foregroundStyle(PgColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Toate medicamentele, într-un singur loc.")
                        .font(.title3)
                        .foregroundStyle(PgColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .introReveal(introShown, order: 1, reduceMotion: reduceMotion)
            }
            .padding(.top, Spacing.l)

            VStack(alignment: .leading, spacing: Spacing.m) {
                featureRow(
                    "person", "Pentru pacient",
                    "Vedeți doar ce aveți de luat acum, cu poza cutiei.")
                    .introReveal(introShown, order: 2, reduceMotion: reduceMotion)
                featureRow(
                    "person.2", "Pentru familie",
                    "Scanați cutiile și rețetele și aflați când ceva grav are nevoie de atenție.")
                    .introReveal(introShown, order: 3, reduceMotion: reduceMotion)
                featureRow(
                    "stethoscope", "Pentru medicul de familie",
                    "Decide pe fiecare alertă și lasă o notă pentru familie.")
                    .introReveal(introShown, order: 4, reduceMotion: reduceMotion)
            }
            .frame(maxWidth: 480, alignment: .leading)

            Text("Nu înlocuiește sfatul medicului.")
                .font(.footnote)
                .foregroundStyle(PgColor.textSecondary)
                .introReveal(introShown, order: 5, reduceMotion: reduceMotion)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("onboarding.intro")
        .onAppear {
            guard !introShown else { return }
            introShown = true
        }
    }

    private func featureRow(_ systemImage: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: systemImage)
                .font(.title2.weight(.medium))
                .foregroundStyle(PgColor.accent)
                .frame(width: featureIconSize, height: featureIconSize)
                .background(Circle().fill(PgColor.accent.opacity(0.12)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PgColor.textPrimary)
                Text(detail)
                    .font(.body)
                    .foregroundStyle(PgColor.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pașii

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            stepTitle("Pentru cine folosiți aplicația?")
            Text("Pentru dumneavoastră: butoane mari și un singur ecran, cu pastilele de acum.")
                .font(.body)
                .foregroundStyle(PgColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pentru cineva drag: medicamentele, alertele și noutățile lui, de la distanță.")
                .font(.body)
                .foregroundStyle(PgColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            stepTitle(forRole("Cum vă numiți?", "Cum se numește persoana de care aveți grijă?"))
            TextField("Prenumele", text: $name)
                .font(.system(size: fieldSize))
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($nameFocused)
                .onSubmit { if canContinue { advance() } }
                .padding(Spacing.m)
                .frame(minHeight: ControlHeight.senior)
                .background(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .fill(PgColor.surface))
                .accessibilityIdentifier("onboarding.nameField")
            Text("Numele apare în mesajele aplicației.")
                .font(.body)
                .foregroundStyle(PgColor.textSecondary)
        }
        .onAppear { nameFocused = true }
    }

    private var birthYearStep: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            stepTitle(forRole("În ce an v-ați născut?", "În ce an s-a născut?"))
            Text("Unele medicamente au alte reguli după 65 de ani.")
                .font(.body)
                .foregroundStyle(PgColor.textSecondary)
            Picker("Anul nașterii", selection: $birthYear) {
                ForEach(Array((1920...2008).reversed()), id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .accessibilityIdentifier("onboarding.birthYearPicker")
        }
    }

    private var healthStep: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            stepTitle(forRole("Despre sănătatea dumneavoastră", "Despre sănătatea persoanei dragi"))
            Text("Opțional. Puteți completa și mai târziu, din Setări.")
                .font(.body)
                .foregroundStyle(PgColor.textSecondary)
            HealthProfileFields(profile: $health, idPrefix: "onboarding")
        }
    }

    private var mealsStep: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            stepTitle(forRole("Când vă treziți și când mâncați?", "Când se trezește și când mănâncă?"))
            Text("Potrivim orele medicamentelor după ziua obișnuită.")
                .font(.body)
                .foregroundStyle(PgColor.textSecondary)
            TimeRow(title: "Trezirea", selection: $wake, identifier: "onboarding.wakeTime")
            TimeRow(title: "Micul dejun", selection: $breakfast, identifier: "onboarding.breakfastTime")
            TimeRow(title: "Prânzul", selection: $lunch, identifier: "onboarding.lunchTime")
            TimeRow(title: "Cina", selection: $dinner, identifier: "onboarding.dinnerTime")
        }
    }

    private var bedtimeStep: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            stepTitle(forRole("Când vă culcați?", "Când se culcă?"))
            DatePicker("Culcarea", selection: $bedtime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .environment(\.locale, PgFormat.romanian)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("onboarding.bedTime")
        }
    }

    private var bottomBar: some View {
        VStack(spacing: Spacing.s) {
            if let errorMessage {
                Label(errorMessage, systemImage: "wifi.exclamationmark")
                    .font(.body)
                    .foregroundStyle(PgColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("onboarding.error")
            }
            switch step {
            case .intro:
                SeniorButton("Să începem", identifier: "onboarding.startButton") {
                    advance()
                }
                .introReveal(introShown, order: 5, reduceMotion: reduceMotion)
            case .welcome:
                SeniorButton("Pentru mine", systemImage: "person", identifier: "onboarding.role.senior") {
                    role = .senior
                    advance()
                }
                SeniorButton(
                    "Pentru cineva drag", systemImage: "person.2", prominence: .secondary,
                    identifier: "onboarding.role.caregiver"
                ) {
                    role = .caregiver
                    advance()
                }
                if store.settings.demoMode {
                    Button("Folosește pacientul demo") {
                        Task { await store.useDemoPatient() }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("onboarding.demoButton")
                }
            case .bedtime:
                SeniorButton(isSubmitting ? "Se salvează…" : "Gata", identifier: "onboarding.finishButton") {
                    Task { await submit() }
                }
                .disabled(isSubmitting)
            default:
                SeniorButton("Continuă", identifier: "onboarding.nextButton") {
                    advance()
                }
                .disabled(!canContinue)
            }
        }
        .padding(Spacing.m)
        .background(PgColor.background)
    }

    // MARK: - Logică

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canContinue: Bool {
        switch step {
        case .name: !trimmedName.isEmpty
        case .health: health.problem == nil
        default: true
        }
    }

    private var stepTransition: AnyTransition {
        let spatial: AnyTransition = .asymmetric(
            insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity))
        return PgMotion.transition(spatial, reduceMotion: reduceMotion)
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        go(to: next)
    }

    private func go(to target: Step) {
        movingForward = target.rawValue > step.rawValue
        errorMessage = nil
        withPgAnimation(.pgStandard, reduceMotion: reduceMotion) {
            step = target
        }
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        let anchors = Anchors(
            bed: PgFormat.clock(bedtime),
            breakfast: PgFormat.clock(breakfast),
            dinner: PgFormat.clock(dinner),
            lunch: PgFormat.clock(lunch),
            wake: PgFormat.clock(wake))
        let body = PatientCreate(
            anchors: anchors,
            birthYear: birthYear,
            caregiverName: nil,
            conditions: health.conditions.isEmpty ? nil : health.orderedConditions,
            conditionsNote: health.trimmedNote,
            heightCm: health.heightCm,
            name: trimmedName,
            weightKg: health.weightKg)
        do {
            try await store.createPatient(body, role: role)
        } catch {
            Log.onboarding.error("createPatient: \(String(describing: error), privacy: .public)")
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Nu am putut salva. Încercați din nou."
        }
    }

    private func forRole(_ senior: String, _ caregiver: String) -> String {
        role == .senior ? senior : caregiver
    }

    private func stepTitle(_ text: String) -> some View {
        Text(text)
            .font(.largeTitle.bold())
            .foregroundStyle(PgColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

private extension View {
    /// Apariția în cascadă din prezentare: fiecare element urcă puțin și apare, la 60 ms după cel dinainte.
    /// Cu Reduce Motion, doar opacitate.
    func introReveal(_ shown: Bool, order: Int, reduceMotion: Bool) -> some View {
        self
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : Spacing.s)
            .animation(
                PgMotion.resolve(.pgStandard, reduceMotion: reduceMotion).delay(Double(order) * 0.06),
                value: shown)
    }
}
