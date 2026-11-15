import XCTest

/// Turul agresiv (Q3): apăsări repetate, anulări la limită, scanări ciudate, ore la marginea zilei,
/// backend oprit în timpul fluxului, check-in-uri limită, multe Noutăți, accesibilitate dură.
/// Rulează cu infrastructura turului de review: `make review Q=Q3e TOUR=EdgeCaseTour CONFIGS="Light AX DarkAX" NO_VIDEO=1`.
/// Ca `ReviewTour`, testele nu pică: ce nu apare e notat „absent”, iar judecata se face din capturi și JSON.
@MainActor
final class EdgeCaseTour: ReviewTestCase {
    override class var darkAXTests: Set<String> { ["testSeniorHugeTextDark"] }

    // MARK: - Ajutătoare

    /// Apăsări rapide pe același punct (2–5 în < 300 ms): XCUITest le trimite ca un singur gest cu mai multe atingeri.
    private func burst(_ identifier: String, taps: Int) {
        guard let target = expect(identifier, timeout: 10) else { return }
        let deadline = Date().addingTimeInterval(3)
        while target.frame.isEmpty && Date() < deadline { pause(0.2) }
        target.tap(withNumberOfTaps: taps, numberOfTouches: 1)
    }

    /// Cereri directe la backend-ul turului (din runner), ca pacientul demo să primească date înainte de capturi.
    @discardableResult
    private func api(_ method: String, _ path: String, json: Any? = nil) -> (Int, Data) {
        var request = URLRequest(url: URL(string: Self.baseURL + path)!)
        request.httpMethod = method
        request.setValue("demo-token", forHTTPHeaderField: "X-Patient-Token")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Int, Data) = (0, Data())
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        return result
    }

    private func setBaseURL(_ url: String) {
        guard tap("settings.openButton") else { return }
        openAdvancedSettings()
        guard let field = expect("settings.baseURLField") else { return }
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 5))
        }
        field.typeText(url)
        tap("settings.checkConnectionButton")
        expect("settings.connectionStatus", timeout: 8)
        step("settings-\(url.hasSuffix(":9") ? "down" : "up")")
        tap("settings.doneButton")
    }

    private func deleteRow(_ row: XCUIElement, id: String) {
        row.swipeLeft()
        let button = element("meds.deleteButton.\(id)")
        if button.waitForExistence(timeout: 1) { button.tap() }
    }

    // MARK: - Apăsări repetate (modul senior)

    func testRapidTaken() {
        launch("rapidTaken", role: .senior, now: Self.today(at: "07:05"))
        expect("now.takenButton", timeout: 10)
        step("before")
        burst("now.takenButton", taps: 2)
        pause(0.5)
        step("afterDoubleTap", audit: true)
        // a doua apăsare putea ateriza pe „Anulează”, care ia locul butonului
        if element("now.undoBanner").exists {
            burst("now.undoButton", taps: 3)
            pause(0.8)
            step("afterTripleUndo")
        }
        burst("now.takenButton", taps: 5)
        pause(0.8)
        step("afterFiveTaps")
    }

    func testRapidLaterAndSkipped() {
        launch("rapidLater", role: .senior, now: Self.today(at: "13:05"))
        burst("now.laterButton", taps: 3)
        pause(0.8)
        step("afterLater", audit: true)
        burst("now.skippedButton", taps: 3)
        pause(0.8)
        // Q3-03: atingerile 2 și 3 cad pe „Anulează” abia apărut și sunt ignorate
        expect("now.undoBanner", timeout: 2)
        step("afterSkipped")
    }

    func testTakenUndoTakenAndExpiry() {
        launch("undoCycle", role: .senior, now: Self.today(at: "07:05"))
        tap("now.takenButton", timeout: 10)
        // „Anulează” ignoră atingerile din primele 800 ms (Q3-03)
        pause(1)
        tap("now.undoButton", timeout: 3)
        pause(0.6)
        step("undone")
        // la 1 s după, al doilea „Am luat” nu e blocat de gardă
        pause(1.2)
        tap("now.takenButton", timeout: 3)
        pause(0.5)
        step("takenAgain")
        // după 5 s „Anulează” trebuie să fi dispărut
        pause(6)
        step("afterUndoWindow", audit: true)
        if element("now.undoButton").exists {
            tap("now.undoButton")
            step("lateUndo")
        }
    }

    // MARK: - Medicamente: ștergere, anulare, totul șters

    func testDeleteUndoAndDeleteAll() {
        launch("deleteAll", role: .caregiver)
        expect("meds.list", timeout: 10)
        // Sintrom (med_01) din fixture, dacă e în listă: T-Q3F6-02 verifică că „Anulează” îl readuce
        let sintrom = element("meds.row.med_01")
        guard let row = sintrom.waitForExistence(timeout: 5)
            ? Optional(sintrom) : first(prefix: "meds.row.", excludingSuffix: ".alert")
        else { return markAbsent("meds.row.*") }
        let id = String(row.identifier.dropFirst("meds.row.".count))
        deleteRow(row, id: id)
        expect("meds.undoBanner", timeout: 3)
        // fără audit aici: durează câteva secunde, iar „Anulează” trebuie atins în fereastra de 5 s
        step("deleted")
        burst("meds.undoButton", taps: 3)
        pause(0.8)
        expect("meds.row.\(id)", timeout: 3)
        step("undone", audit: true)
        if let again = first(prefix: "meds.row.\(id)", excludingSuffix: ".alert") { deleteRow(again, id: id) }
        pause(0.5)
        step("deletedAgain")
        // toate celelalte, una după alta (fiecare ștergere o confirmă pe cea dinainte)
        for _ in 0..<12 {
            guard let next = first(prefix: "meds.row.", excludingSuffix: ".alert") else { break }
            deleteRow(next, id: String(next.identifier.dropFirst("meds.row.".count)))
            pause(0.4)
        }
        pause(6.5)
        expect("meds.empty", timeout: 5)
        step("emptyMeds", audit: true)
        tapTab("Alerte")
        pause(1.5)
        step("emptyAlerts", audit: true)
        tapTab("Graf")
        pause(2.5)
        step("emptyGraph", audit: true)
        tapTab("Noutăți")
        pause(1.5)
        step("emptyFeed")
        app.terminate()
        launch("deleteAllSenior", role: .senior, reset: false, now: Self.today(at: "07:05"))
        pause(2)
        expect("now.empty", timeout: 5)
        step("emptyNow", audit: true)
        if tap("now.dayButton", timeout: 5) {
            pause(1)
            expect("day.empty", timeout: 3)
            step("emptyDay", audit: true)
        }
    }

    // MARK: - Modul demo

    func testRapidDemoButtons() {
        launch("rapidDemo", role: .caregiver, defaults: ["pg.demoMode": "YES"])
        expect("meds.list", timeout: 10)
        guard tap("settings.openButton") else { return }
        if scrollTo("settings.addRxButton") != nil {
            burst("settings.addRxButton", taps: 4)
            pause(4)
            step("rxBurst", audit: true)
            burst("settings.missedDoseButton", taps: 3)
            pause(3)
            step("missedBurst")
        }
        if scrollTo("settings.useDemoPatientButton") != nil {
            burst("settings.useDemoPatientButton", taps: 3)
            pause(4)
            step("resetBurst")
        }
        tap("settings.doneButton")
        pause(1)
        app.swipeUp()
        step("medsAfter")
        tapTab("Noutăți")
        pause(2)
        step("feedAfter")
    }

    // MARK: - Scanări

    private func scan(_ name: String, flow: String, prescription: Bool = false, reset: Bool = true) {
        launch(flow, role: .caregiver, reset: reset, env: ["PG_FAKE_SCAN": name])
        expect("meds.list", timeout: 10)
        guard tap("meds.addButton") || tap("meds.emptyScanButton", timeout: 1) else { return }
        if prescription {
            let rx = app.buttons["Rețetă"]
            if rx.waitForExistence(timeout: 3) { rx.tap() }
            tapFakeUsePage()
        } else {
            pause(2)
            tap("scan.shutter")
        }
        if expect("confirm.saveButton", timeout: 30) == nil { expect("scan.error", timeout: 1) }
        step("result", audit: true)
    }

    func testScanVariants() {
        for name in ["nurofen", "expired", "aspirin"] {
            scan(name, flow: "scan-\(name)")
            app.swipeUp()
            step("scrolled")
            app.terminate()
        }
    }

    func testScanSameBoxTwice() {
        scan("sintrom", flow: "scanTwice")
        tap("confirm.saveButton")
        expect("meds.savedBanner", timeout: 10)
        step("firstSaved")
        guard tap("meds.addButton") else { return }
        pause(2)
        tap("scan.shutter")
        expect("confirm.saveButton", timeout: 30)
        step("second", audit: true)
        burst("confirm.saveButton", taps: 3)
        pause(3)
        step("secondSavedBurst")
        app.swipeUp()
        step("listAfter")
    }

    /// Rețeta cu trei medicamente: pagina falsă e textul numelui, cu rânduri noi.
    func testScanMultiPrescription() {
        scan("Aspirin 500 mg\nParacetamol 500 mg\nAlgocalmin 500 mg", flow: "scanMulti", prescription: true)
        tap("confirm.skipButton", timeout: 2)
        pause(0.8)
        step("second")
        tap("confirm.cancelButton")
        pause(1)
        step("cancelHalf")
    }

    func testConfirmFieldLimits() {
        scan("sintrom", flow: "confirmFields")
        guard let brand = expect("confirm.brandField") else { return }
        let values = [
            ("empty", ""),
            ("oneChar", "S"),
            ("long", String(repeating: "Sintrom ", count: 15)),
            ("emoji", "Sintrom 💊😀"),
            ("diacritics", "Ăâîșț ĂÂÎȘȚ"),
        ]
        for (label, value) in values {
            brand.tap()
            if let current = brand.value as? String {
                brand.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
            }
            brand.typeText(value)
            step("brand-\(label)")
        }
        if let strength = expect("confirm.strengthField") {
            for value in ["0 mg", "-5 mg", "9999 mg"] {
                strength.tap()
                if let current = strength.value as? String {
                    strength.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
                }
                strength.typeText(value)
                step("strength-\(value.replacingOccurrences(of: " ", with: ""))")
            }
        }
        // posologia e din steppere 0–4: apăsăm „+” de 12 ori pe dimineață
        if let stepper = scrollTo("confirm.dose.morning") {
            let plus = stepper.buttons.element(boundBy: 1)
            for _ in 0..<12 where plus.exists { plus.tap() }
            step("doseMax", audit: true)
        }
        tap("confirm.saveButton")
        pause(3)
        step("saved")
    }

    // MARK: - Timpul

    func testClockEdges() {
        let times: [(String, String)] = [
            ("midnight", Self.today(at: "00:00")),
            ("three", Self.today(at: "03:00")),
            ("exact1300", Self.today(at: "13:00")),
            ("lateNight", Self.today(at: "23:59")),
            ("dstSpring", "2026-03-29T03:30:00"),
            ("dstAutumn", "2026-10-25T04:00:00"),
            ("nextYear", "2027-11-14T08:00:00"),
        ]
        for (label, now) in times {
            launch("clock-\(label)", role: .senior, now: now)
            expect("now.clock", timeout: 10)
            step("now", audit: label == "lateNight")
            app.terminate()
        }
        launch("clock-yearCaregiver", role: .caregiver, now: "2027-11-14T08:00:00")
        tapTab("Alerte")
        pause(2)
        step("alerts")
    }

    func testUnconfirmedDayAtNight() {
        // nimic confirmat azi, iar seara târziu: ce vede pacientul?
        launch("nightUnconfirmed", role: .senior, now: Self.today(at: "23:30"))
        pause(2)
        step("now", audit: true)
        if tap("now.dayButton", timeout: 5) {
            pause(1)
            step("day")
        }
    }

    // MARK: - Rețeaua

    func testBackendDropsMidFlowCaregiver() {
        launch("netCaregiver", role: .caregiver)
        expect("meds.list", timeout: 10)
        step("online")
        setBaseURL("http://127.0.0.1:9")
        app.swipeDown()
        pause(2)
        step("medsOffline", audit: true)
        tapTab("Graf")
        pause(3)
        step("graphOffline")
        tapTab("Noutăți")
        pause(2)
        app.swipeDown()
        pause(2)
        step("feedOffline")
        tapTab("Medicamente")
        if tap("meds.addButton", timeout: 2) {
            pause(1)
            step("scanOffline")
            tap("scan.closeButton", timeout: 2)
        }
        setBaseURL(Self.baseURL)
        pause(1)
        step("backOnline")
        tap("meds.retryButton", timeout: 2)
        pause(3)
        step("recovered", audit: true)
        tapTab("Graf")
        pause(3)
        step("graphRecovered")
    }

    func testBackendDropsMidFlowSenior() {
        launch("netSenior", role: .senior, now: Self.today(at: "07:05"))
        expect("now.takenButton", timeout: 10)
        setBaseURL("http://127.0.0.1:9")
        tap("now.takenButton")
        pause(1)
        // Q3-07: confirmarea rămâne de trimis și se spune, calm
        expect("now.pendingSync", timeout: 5)
        step("takenOffline", audit: true)
        pause(6)
        step("afterUndoWindowOffline")
        if tap("now.checkInButton", timeout: 3) {
            app.swipeUp()
            step("checkinOffline")
            app.navigationBars.buttons.firstMatch.tap()
        }
        setBaseURL(Self.baseURL)
        app.swipeDown()
        pause(3)
        if element("now.pendingSync").exists { markAbsent("now.pendingSync dispărut după revenire") }
        step("recovered")
    }

    func testBackendDownSeniorScreens() {
        let down = ["PG_BASE_URL": "http://127.0.0.1:9"]
        launch("downSenior", role: .senior, reset: false, now: Self.today(at: "07:05"), env: down)
        pause(4)
        // Q3-05: eroarea se repară cu un buton, nu cu un gest
        expect("now.retryButton", timeout: 3)
        step("now")
        if tap("now.dayButton", timeout: 3) {
            pause(2)
            expect("day.retryButton", timeout: 3)
            step("day", audit: true)
            tap("day.backButton", timeout: 3)
        }
        if tap("now.checkInButton", timeout: 3) {
            step("checkin")
        }
        app.terminate()
        launch("downCaregiver", role: .caregiver, reset: false, env: down)
        tapTab("Graf")
        pause(4)
        step("graph", audit: true)
        tapTab("Noutăți")
        pause(4)
        step("feed", audit: true)
        tapTab("Medicamente")
        if tap("meds.shareButton", timeout: 3) {
            pause(3)
            step("share", audit: true)
        }
    }

    // MARK: - Check-in vocal

    private static let transcripts: [(String, String)] = [
        ("blank", "   "),
        ("oneWord", "bine"),
        ("long", String(repeating: "Mă doare puțin capul și sunt obosită de câteva zile. ", count: 12)),
        ("chestPain", "Am o durere în piept de azi dimineață."),
        ("many", "Am amețeli, greață, mă dor mușchii și am vânătăi pe mâini și scaun negru."),
        ("english", "I feel dizzy and I have a headache."),
        ("sindrom", "Pot să iau sindromul seara cu mâncare?"),
        ("negated", "Nu am amețeli și nu mă doare nimic."),
        ("aspirin", "Pot să iau o aspirină?"),
        ("algocalmin", "Pot să iau Algocalmin?"),
        ("paracetamol", "Pot să iau Paracetamol?"),
        ("onList", "Pot să iau Nurofen pentru genunchi?"),
    ]

    /// Câte patru transcrieri pe test: fiecare pornește aplicația, iar un test are 3 minute.
    private func voiceCases(_ cases: ArraySlice<(String, String)>) {
        // pacientul demo se reface doar la primul caz, ca Noutățile să adune toate întrebările
        for (index, (label, text)) in cases.enumerated() {
            launch("voice-\(label)", role: .senior, reset: index == 0, now: Self.today(at: "10:00"),
                   env: ["PG_FAKE_TRANSCRIPT": text])
            guard tap("now.checkInButton", timeout: 10) else { continue }
            if tap("checkin.micButton", timeout: 3) {
                if expect("checkin.reply", timeout: 45) == nil { expect("checkin.error", timeout: 1) }
            }
            step("reply", audit: label == "long" || label == "aspirin")
            app.swipeUp()
            step("replyScrolled")
            app.terminate()
        }
    }

    func testVoiceSymptoms() { voiceCases(Self.transcripts[0..<4]) }

    func testVoiceMixed() { voiceCases(Self.transcripts[4..<8]) }

    func testVoiceCanITake() {
        voiceCases(Self.transcripts[8..<12])
        // la aparținător: ce a ajuns în Noutăți din întrebările de mai sus (fără reset)
        launch("voice-feed", role: .caregiver, reset: false)
        tapTab("Noutăți")
        pause(2)
        step("feed", audit: true)
        if let event = first(prefix: "feed.event.") {
            tapElement(event)
            pause(1)
            step("event")
        }
    }

    // MARK: - Noutăți

    func testFeedFloodAndPolling() {
        launch("feedFlood", role: .caregiver)
        // 32 de check-in-uri escaladate (o cădere e semn de alarmă), înainte de prima încărcare a tab-ului
        for i in 0..<32 {
            api("POST", "/v1/patients/pat_demo/checkins", json: ["text": "Am căzut azi \(i) și mă doare șoldul."])
        }
        tapTab("Noutăți")
        pause(3)
        step("flood", audit: true)
        app.swipeUp()
        app.swipeUp()
        step("scrolled")
        // evenimente noi cât lista e derulată: pastila „noutăți ↑”, lista nu se mișcă
        api("POST", "/v1/patients/pat_demo/checkins", json: ["text": "Am scaun negru de ieri."])
        api("POST", "/demo/missed-dose")
        pause(12)
        step("pendingWhileScrolled")
        if tap("feed.newPill", timeout: 2) {
            pause(1)
            step("afterPill")
        }
        // comutare rapidă între tab-uri
        for label in ["Medicamente", "Alerte", "Graf", "Noutăți", "Alerte", "Medicamente", "Noutăți"] {
            app.tabBars.buttons[label].tap()
        }
        pause(1)
        step("afterTabStorm")
    }

    // MARK: - Alerta „unverified” (QA-03)

    /// Un medicament fără substanțe primește alerta `unverified` (moderate, doar pentru aparținător): stă în cardul
    /// moderat, iar la pacient nu apare deloc, deci nici ca alarmă.
    func testUnverifiedAlert() {
        launch("unverified", role: .caregiver)
        let (_, data) = api("GET", "/v1/patients/pat_demo/meds")
        if var med = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first,
           var product = med["product"] as? [String: Any] {
            product["brand"] = "Necunoscutin"
            med["product"] = product
            med["id"] = "med_unverified"
            med["substances"] = [Any]()
            api("POST", "/v1/patients/pat_demo/meds", json: med)
        }
        // fără reset, ca medicamentul adăugat să rămână; analiza se încarcă la pornire
        app.terminate()
        launch("unverified", role: .caregiver, reset: false)
        tapTab("Alerte")
        pause(2)
        step("list")
        // rândurile din cardul restrâns poartă identificatorul cardului (`alerts.moderateGroup`), nu pe al lor
        let row = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ AND label BEGINSWITH %@", "alerts.moderateGroup", "Nu am putut verifica Necunoscutin"
        )).firstMatch
        // în AX, cardul moderat e sub ecran, iar LazyVStack nu-l creează până nu se derulează
        for _ in 0..<8 where !element("alerts.moderateGroup").exists { app.swipeUp() }
        if tap("alerts.moderateGroup", timeout: 10) {
            pause(1)
            if !row.waitForExistence(timeout: 5) {
                markAbsent("„Nu am putut verifica Necunoscutin” în alerts.moderateGroup")
            }
            // deasupra tab bar-ului, ca rândul să se vadă în captură
            let visible = app.windows.firstMatch.frame.insetBy(dx: 0, dy: 160)
            for _ in 0..<6 where !visible.contains(row.frame) { app.swipeUp() }
            step("moderateOpen", audit: true)
            if row.exists {
                tapElement(row, name: "unverified row")
                expect("alertDetail")
                pause(1)
                step("detail", audit: true)
            }
        }
        app.terminate()
        launch("unverified", role: .senior, reset: false, now: Self.today(at: "07:05"))
        pause(2)
        // cardul liniștit din „Acum” vine de la interacțiunile grave ale pacientului demo; `unverified` nu ajunge la pacient
        let leaked = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Nu am putut verifica")).firstMatch
        if leaked.exists { markAbsent("senior fără „Nu am putut verifica”") }
        step("senior", audit: true)
    }

    // MARK: - Partajare

    func testShareTwice() {
        launch("shareTwice", role: .caregiver)
        expect("meds.list", timeout: 10)
        for round in 1...2 {
            if tap("meds.shareButton") {
                expect("share.qr", timeout: 10)
                step("qr\(round)")
                tap("share.doneButton")
            }
        }
        burst("meds.shareButton", taps: 3)
        pause(2)
        step("burst")
    }

    // MARK: - Accesibilitate dură

    /// Dark și textul maxim vin din configurația DarkAX (Dark prin `set_ui` din run.sh, Q3F6).
    func testSeniorHugeTextDark() {
        launch("hugeDark", role: .senior, now: Self.today(at: "07:05"),
               env: [:], defaults: ["pg.remindersAsked": "NO"])
        pause(3)
        step("now", audit: true)
        app.swipeUp()
        step("nowScrolled")
        app.swipeUp()
        step("nowBottom")
        tap("now.takenButton", timeout: 3)
        pause(0.8)
        step("taken", audit: true)
        if tap("now.dayButton", timeout: 3) {
            pause(1)
            step("day", audit: true)
            if tap("day.shareButton", timeout: 3) {
                expect("share.qr", timeout: 10)
                step("share", audit: true)
            }
        }
    }

    // MARK: - Moduri și reset cu detaliul deschis

    func testRoleSwitchAndResetWithDetailOpen() {
        launch("modeSwitch", role: .caregiver, defaults: ["pg.demoMode": "YES"])
        tapTab("Alerte")
        if let card = first(prefix: "alerts.card.") {
            tapElement(card)
            expect("alertDetail")
        }
        // Setările sunt pe ecranele rădăcină: trecem în Medicamente, lăsând detaliul deschis în Alerte
        tapTab("Medicamente")
        if let row = first(prefix: "meds.row.", excludingSuffix: ".alert") { tapElement(row) }
        expect("medDetail")
        step("detailOpen")
        app.navigationBars.buttons.firstMatch.tap()
        if tap("settings.openButton") {
            if let reset = scrollTo("settings.useDemoPatientButton") {
                reset.tap()
                pause(3)
            }
            if let rx = scrollTo("settings.addRxButton") {
                rx.tap()
                pause(3)
            }
            step("settingsAfterReset")
            tap("settings.doneButton")
        }
        tapTab("Alerte")
        pause(1)
        step("alertsDetailAfterReset")
        app.navigationBars.buttons.firstMatch.tap()
        pause(1)
        step("alertsListAfterReset")
        // modul senior din Setări, cu stiva aparținătorului încă plină
        tapTab("Medicamente")
        if tap("settings.openButton") {
            let picker = element("settings.rolePicker")
            if picker.waitForExistence(timeout: 3) {
                picker.buttons.element(boundBy: 0).tap()
            }
            step("rolePicked")
            tap("settings.doneButton")
        }
        pause(2)
        step("afterRoleSwitch", audit: true)
    }

    // MARK: - Sincronizarea cu pagina familiei și portalul (14.7: testele „manuale” de pe iPhone, pe simulator)
    //
    // Runner-ul joacă rolul browserului: intră pe /acasa cu linkul din aplicație și în portal cu codul medicului,
    // cu cookie-urile din URLSession.shared. Aplicația vede schimbările prin polling (modul senior la 30 s,
    // Noutăți la 10 s), deci așteptările merg până la 45 s.

    /// O cerere „de browser” (formular sau JSON), cu redirecturile urmate; întoarce codul final și HTML-ul.
    @discardableResult
    private func web(_ method: String, _ path: String, form: [String: String]? = nil, json: Any? = nil)
        -> (Int, String)
    {
        var request = URLRequest(url: URL(string: Self.baseURL + path)!)
        request.httpMethod = method
        if let form {
            var items = URLComponents()
            items.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = items.percentEncodedQuery?.data(using: .utf8)
        } else if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Int, String) = (0, "")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data ?? Data(), as: UTF8.self))
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 30)
        return result
    }

    /// Intrarea pe pagina familiei, ca „Deschide pe web”: linkul de unică folosință, cerut cu tokenul pacientului.
    /// Linkul are adresa din rețea a Mac-ului; se păstrează doar calea, ca cookie-ul să fie pe adresa turului.
    private func enterFamilyPage() -> Bool {
        let (status, data) = api("POST", "/v1/patients/pat_demo/web-link")
        guard status == 201,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = (body["url"] as? String).flatMap(URL.init(string:))
        else {
            XCTFail("web-link a răspuns \(status)")
            return false
        }
        let (code, html) = web("GET", url.path)
        XCTAssertEqual(code, 200, "intrarea pe /acasa a dat \(code)")
        return code == 200 && !html.contains("Deschideți linkul din aplicație")
    }

    /// Cardul unui moment din „Azi” (/acasa), de la `id="m-0700"` până la următorul moment.
    private func familyMoment(_ time: String) -> String {
        let html = web("GET", "/acasa").1
        guard let start = html.range(of: "id=\"m-\(time.replacingOccurrences(of: ":", with: ""))\"") else { return "" }
        let rest = html[start.upperBound...]
        return String(rest[..<(rest.range(of: "id=\"m-")?.lowerBound ?? rest.endIndex)])
    }

    private func portalLogin() -> Bool {
        let (code, _) = web("POST", "/portal/login", form: ["code": "medic-demo", "next": "/portal"])
        XCTAssertEqual(code, 200, "login-ul în portal a dat \(code)")
        return code == 200
    }

    /// Așteaptă până când `condition` e adevărată (polling-ul aplicației), cel mult `timeout` secunde.
    private func waitUntil(_ timeout: TimeInterval = 45, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pause(2)
        }
        return condition()
    }

    private func analyzedAt() -> String {
        let (_, data) = api("GET", "/v1/patients/pat_demo/analysis")
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return body?["analyzed_at"] as? String ?? ""
    }

    /// T-E0-03: Sintrom (cu medic prescriptor) și Nurofen (fără) editați din detaliu și salvați din prima;
    /// după salvare, analiza e refăcută (alt `analyzed_at`, același număr de alerte).
    func testSyncEditBothMeds() {
        launch("syncEdit", role: .caregiver)
        expect("meds.list", timeout: 10)
        for brand in ["Sintrom", "Nurofen"] {
            let before = analyzedAt()
            let row = app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH 'meds.row.' AND NOT identifier ENDSWITH '.alert' "
                    + "AND label CONTAINS[c] %@", brand)).firstMatch
            for _ in 0..<4 where !(row.exists && onScreen(row)) { app.swipeUp() }
            guard row.exists else { markAbsent("meds.row.* \(brand)"); continue }
            tapElement(row)
            guard tap("medDetail.editButton"), expect("confirm.saveButton", timeout: 5) != nil else { continue }
            pause(1.1)  // `analyzed_at` are secunde
            tap("confirm.saveButton")
            if !element("confirm.saveButton").waitForNonExistence(timeout: 10) {
                let error = element("confirm.error")
                XCTFail("E0: \(brand) nu s-a salvat: \(error.exists ? error.label : "foaia a rămas deschisă")")
                step("notSaved\(brand)", audit: false)
                tap("confirm.cancelButton")
                continue
            }
            step("saved\(brand)")
            XCTAssertNotEqual(analyzedAt(), before, "E0: după editarea \(brand), analiza nu s-a refăcut")
            app.navigationBars.buttons.firstMatch.tap()
            _ = expect("meds.list", timeout: 5)
            app.swipeDown()
        }
    }

    /// T-P-01: profilul schimbat din Setări (165 cm, 70 kg, + diabet) apare în fișa din portal și pe tipărire.
    func testSyncProfileToPortal() {
        launch("syncProfile", role: .caregiver)
        expect("meds.list", timeout: 10)
        guard tap("settings.openButton"), let open = scrollTo("settings.profileButton") else { return }
        open.tap()
        for (id, value) in [("profile.heightField", "165"), ("profile.weightField", "70")] {
            guard let field = expect(id) else { return }
            field.tap()
            let current = (field.value as? String) ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 3) + value)
        }
        let done = app.toolbars.buttons["Gata"]
        if done.exists { done.tap() }
        guard let diabetes = scrollTo("profile.condition.diabetes") else { return }
        if !diabetes.isSelected { diabetes.tap() }
        step("profileFilled")
        guard let save = scrollTo("profile.saveButton") else { return }
        save.tap()
        if !element("profile.saveButton").waitForNonExistence(timeout: 10) {
            let error = element("profile.error")
            XCTFail("P-01: profilul nu s-a salvat: \(error.exists ? error.label : "ecranul a rămas deschis")")
            return step("notSaved")
        }
        step("saved")
        guard portalLogin() else { return }
        for path in ["/portal/patients/pat_demo", "/portal/patients/pat_demo/print"] {
            let (code, html) = web("GET", path)
            XCTAssertEqual(code, 200, "\(path) a dat \(code)")
            for text in ["1,65 m", "70 kg", "Diabet zaharat", "Hipertensiune arterială"] {
                XCTAssertTrue(html.contains(text), "P-01: „\(text)” lipsește din \(path)")
            }
        }
    }

    /// T-E2-05: „Am luat” în modul senior apare pe /acasa; „Am luat” pe /acasa ajunge în „Ziua de azi”.
    func testSyncTakenWithWeb() {
        launch("syncTaken", role: .senior, now: Self.today(at: "07:05"))
        guard tap("now.takenButton", timeout: 10) else { return step("noDose") }
        pause(2)
        step("appTaken")
        guard enterFamilyPage() else { return }
        XCTAssertTrue(waitUntil(20) { familyMoment("07:00").contains("✓ Luat") },
                      "E2: „Am luat” de la 07:00 din aplicație nu apare pe /acasa")
        let (code, _) = web("POST", "/acasa/doze", form: ["moment": "07:30", "status": "taken"])
        XCTAssertEqual(code, 200, "„Am luat” pe /acasa a dat \(code)")
        guard tap("now.dayButton", timeout: 5), let row = expect("day.moment.07:30") else { return }
        XCTAssertTrue(waitUntil { row.label.contains("Luate") },
                      "E2: bifa de pe web nu a ajuns în „Ziua de azi”: „\(row.label)”")
        step("dayAfterWeb")
    }

    /// T-E1-04 (web → aplicație): cina mutată pe /acasa/ore (19:00 → 20:00) ajunge în modul senior;
    /// sensul aplicație → server e `ReviewTour.testDayHours`, iar /acasa citește aceleași ore (pytest, E1).
    func testSyncDayHoursFromWeb() {
        launch("syncHours", role: .senior, now: Self.today(at: "07:05"))
        guard tap("now.dayButton", timeout: 10), expect("day.moment.19:00") != nil else { return }
        guard enterFamilyPage() else { return }
        let (code, html) = web("POST", "/acasa/ore", form: [
            "wake": "07:00", "breakfast": "08:00", "lunch": "13:00", "dinner": "20:00", "bed": "22:30",
        ])
        XCTAssertEqual(code, 200, "/acasa/ore a dat \(code)")
        XCTAssertFalse(html.contains("ordinea zilei"), "/acasa/ore a respins orele")
        XCTAssertTrue(waitUntil { self.element("day.moment.20:00").exists },
                      "E1: cina mutată pe web (20:00) nu a ajuns în „Ziua de azi”")
        XCTAssertFalse(element("day.moment.19:00").exists, "E1: momentul vechi de la 19:00 a rămas")
        step("dayAfterWebHours")
    }

    /// T-QA4-06: decizia luată în portal și apoi schimbată ajunge la Ana, pe alertă și în Noutăți.
    func testSyncDoctorDecision() {
        launch("syncDecision", role: .caregiver)
        expect("meds.list", timeout: 10)
        guard portalLogin() else { return }
        let alert = "al_ddi_med_01_med_02"
        let review = "/portal/patients/pat_demo/alerts/\(alert)/review"
        XCTAssertEqual(web("POST", review, json: ["decision": "change_at_visit", "note": "Discutăm joi."]).0, 200)

        guard tapTab("Alerte") else { return }
        var decision = ""
        XCTAssertTrue(waitUntil(30) {
            decision = doctorNote(alert)
            return decision.contains("Discutăm joi")
        }, "QA4-06: nota medicului nu apare pe alertă („\(decision)”)")
        XCTAssertTrue(decision.contains("Îl modifică la consultație"), "QA4-06: decizia pe alertă e „\(decision)”")
        step("decision")

        XCTAssertEqual(web("POST", review, json: ["decision": "refer_specialist", "note": "Discutăm joi."]).0, 200)
        guard tapTab("Noutăți") else { return }
        let changed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'schimbat decizia'")).firstMatch
        XCTAssertTrue(waitUntil(30) { changed.exists }, "QA4-06: „a schimbat decizia” nu apare în Noutăți")
        step("feedChanged")
        guard tapTab("Alerte") else { return }
        XCTAssertTrue(waitUntil(30) {
            decision = doctorNote(alert)
            return decision.contains("Trimite la specialist")
        }, "QA4-06: decizia nouă nu apare pe alertă („\(decision)”)")
        step("decisionChanged")
    }

    /// Lista de alerte reîmprospătată (tras în jos), alerta deschisă și textul din „Decizia medicului de familie”.
    private func doctorNote(_ alert: String) -> String {
        if element("alertDetail").exists { app.navigationBars.buttons.firstMatch.tap() }
        guard let list = expect("alerts.list", timeout: 5) else { return "" }
        list.swipeDown()
        pause(1)
        let card = element("alerts.card.\(alert)")
        guard card.waitForExistence(timeout: 5) else { return "" }
        tapElement(card)
        guard expect("alertDetail", timeout: 5) != nil else { return "" }
        let note = element("alertDetail.doctorNote")
        if !note.exists { app.swipeUp() }
        return note.exists ? note.label : ""
    }
}
