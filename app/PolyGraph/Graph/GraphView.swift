import Foundation
import OSLog
import SwiftUI
import UIKit
import WebKit

/// Graful terapeutic (aparținător). Până la B6, pagina e `graph.html` din bundle (cu `cytoscape.min.js`
/// local, fără internet) și primește graful din `/analysis`; după B6, `{baseURL}/share/{token}/graph?embed=1`.
/// Atingerea unei muchii colorate deschide alerta; a unui medicament, detaliul lui.
struct GraphView: View {
    /// Se trece pe `true` când pagina lui B6 e în `main`.
    static let usesSharePage = false

    let open: (CaregiverRoute) -> Void

    @Environment(AppStore.self) private var store
    @State private var remoteURL: URL?
    /// crește la fiecare „Recentrează”; pagina revine la tot graful, centrat
    @State private var resetCount = 0
    @Environment(\.pgReduceMotion) private var reduceMotion
    /// înălțimea textului din „Pe scurt”, măsurată
    @State private var summaryHeight: CGFloat = 0
    /// cât poate ocupa „Pe scurt”; restul rămâne pentru graf
    @ScaledMetric(relativeTo: .body) private var summaryMaxHeight: CGFloat = 250

    var body: some View {
        content
            .navigationTitle("Graf")
            .navigationBarTitleDisplayMode(.inline)
            .pgSettingsToolbar()
    }

    @ViewBuilder
    private var content: some View {
        if store.analysis != nil && store.visibleMeds.isEmpty {
            // fără medicamente graful ar fi doar nodul pacientului, un cerc uriaș (Q3-38)
            ContentUnavailableView {
                Label("Graful apare după primul medicament", systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text("Adăugați medicamentele din tab-ul Medicamente; legăturile dintre ele apar aici.")
            }
            .accessibilityIdentifier("graph.empty")
        } else if let graph = store.analysis?.graph {
            GraphWebView(
                source: source(graph), resetCount: resetCount, animateReset: !reduceMotion, onMessage: handle
            )
                .background(PgColor.background)
                .accessibilityIdentifier("graph.web")
                .safeAreaInset(edge: .top, spacing: 0) {
                    // graful de pe ecran e cel vechi: îl lăsăm, dar spunem că nu e actualizat (Q3-14)
                    if store.lastError != nil && !store.isLoading {
                        StaleBanner(identifier: "graph", retryIdentifier: "graph.retryButton") { await store.refreshAll() }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        summaryPanel
                        bottomBar
                    }
                    .background(.bar)
                }
                .task(id: Self.usesSharePage) {
                    guard Self.usesSharePage, remoteURL == nil else { return }
                    do {
                        let token = try await store.ensureShareToken()
                        remoteURL = store.api.shareGraphURL(token: token)
                    } catch {
                        Log.graph.error("share token: \(String(describing: error), privacy: .public)")
                    }
                }
        } else if store.isLoading {
            ProgressView("Se încarcă graful…")
                .accessibilityIdentifier("graph.loading")
        } else {
            ContentUnavailableView {
                Label(
                    store.lastError == nil ? "Graful apare aici" : "Nu am putut încărca graful",
                    systemImage: store.lastError == nil ? "point.3.connected.trianglepath.dotted" : "wifi.exclamationmark")
            } description: {
                Text(store.lastError ?? "Legăturile dintre medicamente, desenate ca o hartă.")
            } actions: {
                if store.lastError != nil {
                    Button("Încearcă din nou") {
                        Task { await store.refreshAll() }
                    }
                    .pgProminentButton()
                    .accessibilityIdentifier("graph.retryButton")
                }
            }
            .accessibilityIdentifier(store.lastError == nil ? "graph.empty" : "graph.error")
        }
    }

    private func source(_ graph: Graph) -> GraphWebView.Source {
        if Self.usesSharePage, let remoteURL { return .remote(remoteURL) }
        return .bundled(graph)
    }

    private func handle(_ message: GraphWebView.Message) {
        switch message {
        case .alert(let id) where store.alert(id: id) != nil:
            open(.alert(id: id, zoom: false))
        case .med(let id) where store.med(id: id) != nil:
            open(.med(id: id))
        default:
            break
        }
    }

    // MARK: - „Pe scurt”: graful explicat în cuvinte

    private var summary: GraphSummary {
        GraphSummary(alerts: store.analysis?.alerts ?? [], graph: store.analysis?.graph, meds: store.visibleMeds)
    }

    private var legend: GraphLegend {
        GraphLegend(graph: store.analysis?.graph)
    }

    /// numele din nodul din centru („Maria”); fără el, „pacientul”
    private var patientName: String {
        store.analysis?.graph.nodes.first { $0.data.type == .patient }?.data.label
            ?? store.patient?.name ?? "pacientul"
    }

    /// Sub graf, ce înseamnă desenul, pe înțelesul oricui, apoi legenda substanțelor numerotate. Panoul crește
    /// cât textul, până la `summaryMaxHeight`; peste, se derulează, ca graful să rămână vizibil.
    private var summaryPanel: some View {
        let summary = summary
        let legend = legend
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Pe scurt")
                    .font(.headline)
                    .foregroundStyle(PgColor.textPrimary)
                    .accessibilityAddTraits(.isHeader)

                summaryRow(.icon("info.circle", PgColor.textSecondary), "graph.summary.howTo",
                    "În centru e **\(patientName)**. Pătratele sunt medicamentele, iar cercurile cu număr sunt "
                        + "substanțele active din ele (lista de mai jos). O linie colorată între două cercuri "
                        + "înseamnă că acele substanțe nu se potrivesc bine; atingeți linia ca să vedeți de ce.")

                if summary.isEmpty {
                    summaryRow(.icon("checkmark.circle", PgColor.accent), "graph.summary.none",
                        "Nu am găsit combinații de discutat între medicamentele de pe listă. Liniile gri, dacă "
                            + "există, sunt legături fără un risc stabilit.")
                }

                if !summary.serious.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        summaryRow(.line(Severity.major.color), "graph.summary.serious",
                            "**\(GraphSummary.combinations(summary.serious.count, "gravă", "grave").capitalizedFirst)**, "
                                + "de discutat cu medicul cât mai curând (liniile groase din graf):")
                        ForEach(summary.serious, id: \.alertID) { pair in
                            pairButton(pair, identifier: "graph.summary.serious.\(pair.alertID)", advice: true)
                        }
                    }
                }

                if let hub = summary.hub {
                    Button {
                        open(.med(id: hub.medID))
                    } label: {
                        summaryRow(.icon("point.3.connected.trianglepath.dotted", PgColor.accent), "graph.summary.hub",
                            hubText(hub))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Deschide medicamentul")
                }

                if !summary.moderate.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        summaryRow(.line(Severity.moderate.color), "graph.summary.moderate",
                            "**\(GraphSummary.combinations(summary.moderateCount, "de discutat", "de discutat").capitalizedFirst)** "
                                + "la următoarea vizită la medicul de familie (liniile subțiri)"
                                + (summary.moderateCount > Self.moderateShown ? ". Cele mai importante:" : ":"))
                        ForEach(summary.moderate.prefix(Self.moderateShown), id: \.alertID) { pair in
                            pairButton(pair, identifier: "graph.summary.moderate.\(pair.alertID)", advice: false)
                        }
                        if summary.moderateCount > Self.moderateShown {
                            Text("Celelalte \(summary.moderateCount - Self.moderateShown) sunt în tab-ul Alerte.")
                                .font(.footnote)
                                .foregroundStyle(PgColor.textSecondary)
                                .padding(.leading, 18 + Spacing.s)
                                .accessibilityIdentifier("graph.summary.moderate.more")
                        }
                    }
                }

                if !summary.foods.isEmpty {
                    summaryRow(.icon("fork.knife", PgColor.textSecondary), "graph.summary.food", foodText(summary.foods))
                }

                if !legend.isEmpty {
                    legendSection(legend)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { summaryHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(summaryHeight, summaryMaxHeight))
        .accessibilityIdentifier("graph.summary")
    }

    /// câte combinații „de discutat” se explică una câte una; restul sunt în tab-ul Alerte
    private static let moderateShown = 3

    private func hubText(_ hub: GraphSummary.Hub) -> String {
        var text = "Cele mai multe legături le are **\(hub.name)**: "
            + GraphSummary.combinations(hub.count, "cu alte medicamente", "cu alte medicamente")
        if hub.serious > 0 {
            text += hub.serious == hub.count
                ? ", toate grave"
                : ", dintre care " + GraphSummary.combinations(hub.serious, "gravă", "grave")
        }
        return text + ". E un bun punct de pornire în discuția cu medicul."
    }

    private func foodText(_ foods: [GraphSummary.Food]) -> String {
        let shown = foods.prefix(4)
        var text = "**Atenție la mâncare și băutură** (liniile punctate, spre etichetele verzi): "
            + shown.map { "\($0.label.firstLowercased) (cu \($0.meds))" }.joined(separator: "; ")
            + (foods.count > 4 ? "; și altele, în tab-ul Alerte." : ".")
        // pentru cele grave, și ce e de făcut
        for food in shown where food.severity == .critical || food.severity == .major {
            text += " \(food.label): \(food.advice.firstLowercased)"
        }
        return text
    }

    /// o combinație: perechea îngroșată, ce se întâmplă și, pentru cele grave, ce e de făcut; atingerea deschide alerta
    private func pairButton(_ pair: GraphSummary.Pair, identifier: String, advice: Bool) -> some View {
        Button {
            open(.alert(id: pair.alertID, zoom: false))
        } label: {
            Text(LocalizedStringKey(
                "**\(pair.text).** \(pair.explanation)" + (advice ? " \(pair.recommendation)" : "")))
                .font(.subheadline)
                .foregroundStyle(PgColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 18 + Spacing.s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Deschide alerta")
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Legenda substanțelor

    @ScaledMetric(relativeTo: .caption) private var badgeSize: CGFloat = 22

    /// Numerele din cercurile grafului, cu numele substanței, medicamentul și clasa ei.
    private func legendSection(_ legend: GraphLegend) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Substanțele din graf")
                .font(.headline)
                .foregroundStyle(PgColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, Spacing.xxs)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.s, alignment: .topLeading)],
                alignment: .leading, spacing: Spacing.xs
            ) {
                ForEach(legend.items) { item in
                    legendItem(item)
                }
            }
        }
        .accessibilityIdentifier("graph.substances")
    }

    private func legendItem(_ item: GraphLegend.Item) -> some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            Text("\(item.number)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(PgColor.textPrimary)
                .frame(width: badgeSize, height: badgeSize)
                .background(Circle().fill(PgColor.surface))
                .overlay(Circle().strokeBorder(item.severity.map(\.color) ?? PgColor.textSecondary, lineWidth: 1.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PgColor.textPrimary)
                Text(legendDetail(item))
                    .font(.caption)
                    .foregroundStyle(PgColor.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cercul \(item.number): \(item.name), \(legendDetail(item))")
        .accessibilityIdentifier("graph.substance.\(item.number)")
    }

    /// „din Sintrom 4 mg · antagoniști ai vitaminei K”
    private func legendDetail(_ item: GraphLegend.Item) -> String {
        let from = item.products.isEmpty ? nil : "din " + item.products.joined(separator: ", ")
        return [from, item.classes.first].compactMap { $0 }.joined(separator: " · ")
    }

    private enum SummaryMark {
        /// linia colorată din graf, ca legătura dintre desen și text să fie evidentă
        case line(Color)
        case icon(String, Color)
    }

    /// `text` e Markdown: doar `**…**` pentru cuvintele care contează
    private func summaryRow(_ mark: SummaryMark, _ identifier: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Group {
                switch mark {
                case .line(let color):
                    Capsule()
                        .fill(color)
                        .frame(width: 18, height: 4)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                case .icon(let name, let tint):
                    Image(systemName: name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 18)
                }
            }
            .accessibilityHidden(true)
            Text(LocalizedStringKey(text))
                .font(.subheadline)
                .foregroundStyle(PgColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    /// Legenda (severitatea spusă în cuvinte, nu doar prin culoare) și „Recentrează”, sub graf, ca să nu-l acopere.
    private var bottomBar: some View {
        HStack(alignment: .center, spacing: Spacing.s) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.s) { legendRows }
                VStack(alignment: .leading, spacing: Spacing.xxs) { legendRows }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("graph.legend")
            Spacer(minLength: 0)
            Button {
                resetCount += 1
            } label: {
                Label("Recentrează", systemImage: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left")
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Recentrează graful")
            .accessibilityIdentifier("graph.resetButton")
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
    }

    @ViewBuilder
    private var legendRows: some View {
        legendRow(.major, "Grav")
        legendRow(.moderate, "De discutat")
        legendRow(.minor, "Fără risc stabilit")
    }

    private func legendRow(_ severity: Severity, _ text: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Capsule()
                .fill(severity.color)
                .frame(width: 18, height: 4)
            Text(text)
                .font(.caption)
        }
    }
}

// MARK: - WKWebView

struct GraphWebView: UIViewRepresentable {
    enum Source: Equatable {
        case bundled(Graph)
        case remote(URL)

        static func == (lhs: Source, rhs: Source) -> Bool {
            switch (lhs, rhs) {
            case let (.remote(a), .remote(b)): a == b
            case let (.bundled(a), .bundled(b)): GraphWebView.json(a) == GraphWebView.json(b)
            default: false
            }
        }
    }

    enum Message {
        case alert(String)
        case med(String)
    }

    /// numele handler-elor din pagină (aceleași în `graph.html` și în pagina lui B6)
    static let handlerNames = ["alert", "med", "ready"]

    let source: Source
    var resetCount = 0
    var animateReset = true
    let onMessage: (Message) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMessage: onMessage)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        for name in Self.handlerNames {
            configuration.userContentController.add(context.coordinator, name: name)
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        // Cytoscape face singur pan și zoom
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.load(source)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onMessage = onMessage
        context.coordinator.load(source)
        context.coordinator.reset(to: resetCount, animated: animateReset)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        for name in handlerNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }

    static func json(_ graph: Graph) -> String {
        (try? JSONCoding.encoder.encode(graph)).map { String(decoding: $0, as: UTF8.self) } ?? "{\"nodes\":[],\"edges\":[]}"
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onMessage: (Message) -> Void
        weak var webView: WKWebView?
        private var loaded: Source?
        private var pageReady = false
        private var pendingJSON: String?
        private var startedAt = Date()
        private var lastReset = 0

        init(onMessage: @escaping (Message) -> Void) {
            self.onMessage = onMessage
        }

        func load(_ source: Source) {
            guard source != loaded, let webView else { return }
            switch (source, loaded) {
            case (.bundled(let graph), .some(.bundled)) where pageReady:
                // aceeași pagină, alt graf: doar se redesenează
                loaded = source
                render(GraphWebView.json(graph))
            case (.bundled(let graph), _):
                loaded = source
                pendingJSON = GraphWebView.json(graph)
                pageReady = false
                startedAt = Date()
                guard let url = Bundle.main.url(forResource: "graph", withExtension: "html") else {
                    Log.graph.error("graph.html lipsește din bundle")
                    return
                }
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            case (.remote(let url), _):
                loaded = source
                pendingJSON = nil
                startedAt = Date()
                webView.load(URLRequest(url: url))
            }
        }

        func reset(to count: Int, animated: Bool) {
            guard count != lastReset else { return }
            lastReset = count
            webView?.evaluateJavaScript("window.pgResetView && window.pgResetView(\(animated))")
        }

        private func render(_ json: String) {
            webView?.evaluateJavaScript("window.pgRender(\(json))") { _, error in
                if let error {
                    Log.graph.error("pgRender: \(String(describing: error), privacy: .public)")
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageReady = true
            if let json = pendingJSON {
                pendingJSON = nil
                render(json)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            Log.graph.error("graful nu s-a încărcat: \(String(describing: error), privacy: .public)")
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "alert":
                if let id = message.body as? String { onMessage(.alert(id)) }
            case "med":
                if let id = message.body as? String { onMessage(.med(id)) }
            case "ready":
                let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
                Log.graph.info("graf desenat în \(ms, privacy: .public) ms")
            default:
                break
            }
        }
    }
}

private extension String {
    /// „2 combinații grave” → „2 combinații grave”; „o combinație” → „O combinație”
    var capitalizedFirst: String {
        prefix(1).uppercased(with: PgFormat.romanian) + dropFirst()
    }

    /// „Evitați grepfrutul.” → „evitați grepfrutul.”
    var firstLowercased: String {
        prefix(1).lowercased(with: PgFormat.romanian) + dropFirst()
    }
}
