import SwiftUI

/// Bifa mare de după „Am luat” și punctul momentului din cronologie au același id,
/// așa că `matchedGeometryEffect` o duce pe una în cealaltă.
enum CheckFlight {
    static func id(_ time: String) -> String { "check.\(time)" }
}

/// Rândul de sus: un punct per moment al zilei, plin cu bifă când e luat, cu ora dedesubt
/// (fără ore, cele cinci cercuri nu spuneau ce sunt). La textul de accesibilitate orele dispar, ca rândul să încapă.
struct TimelineDots: View {
    let moments: [Moment]
    let current: String?
    /// momentul a cărui bifă încă zboară: punctul lui rămâne gol până aterizează
    let flying: String?
    let namespace: Namespace.ID
    var showsTimes = true
    let status: (Moment) -> MomentStatus

    @ScaledMetric(relativeTo: .title2) private var size: CGFloat = 28
    @ScaledMetric(relativeTo: .body) private var timeSize: CGFloat = 15

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            ForEach(moments) { moment in
                VStack(spacing: Spacing.xxs) {
                    dot(moment)
                    if showsTimes {
                        Text(moment.time)
                            .font(.system(size: timeSize, weight: moment.time == current ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(moment.time == current ? PgColor.accent : PgColor.textSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
        .accessibilityIdentifier("now.timeline")
    }

    private func dot(_ moment: Moment) -> some View {
        let state = status(moment)
        let isCurrent = moment.time == current
        return ZStack {
            Circle()
                .strokeBorder(isCurrent ? PgColor.accent : PgColor.textSecondary, lineWidth: isCurrent ? 3 : 2)
            if state == .taken && flying != moment.time {
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .foregroundStyle(PgColor.accent)
                    .matchedGeometryEffect(id: CheckFlight.id(moment.time), in: namespace)
            } else if state == .skipped {
                Image(systemName: "minus")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(PgColor.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityIdentifier("now.timeline.\(moment.time)")
    }

    private var summary: String {
        let done = moments.filter { status($0) != .open }.count
        return "Ziua de azi: \(done) din \(moments.count) momente confirmate"
    }
}

/// Cantitatea ca pictogramă: un cerc plin per pastilă întreagă, jumătate de cerc pentru jumătate.
struct QuantityIcon: View {
    let qty: Double

    var body: some View {
        let whole = min(Int(qty.rounded(.down)), 4)
        let half = qty - qty.rounded(.down) >= 0.25
        HStack(spacing: Spacing.xxs) {
            ForEach(0..<whole, id: \.self) { _ in
                Image(systemName: "circle.fill")
            }
            if half {
                Image(systemName: "circle.lefthalf.filled")
            }
        }
        .foregroundStyle(PgColor.accent)
        .accessibilityHidden(true)
    }
}

/// Un medicament din moment. Un singur element VoiceOver.
/// Cutia sus, mare: eticheta e ce citește pacientul. Cu poza pastilei (E5), pastila stă mică lângă nume.
/// Cutia e mai scundă decât înainte, ca numele și doza să încapă fără derulare.
/// Pozele se văd întregi (`scaledToFit`), nu tăiate: o capsulă lungă sau o cutie lată nu-și pierd capetele.
/// La textul de accesibilitate numele vine înaintea pozei, iar miniatura pastilei dispare (Q3-02).
struct DoseCard: View {
    let dose: DoseElement
    let med: MedicationItem?
    let photoURL: URL?
    /// E5: nil = fără poza pastilei
    let pillPhotoURL: URL?

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title) private var nameSize: CGFloat = 28
    @ScaledMetric(relativeTo: .title2) private var textSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title) private var thumbSize: CGFloat = 72

    /// Explicit, ca apelurile vechi (fără poza pastilei) să rămână valide.
    init(dose: DoseElement, med: MedicationItem?, photoURL: URL?, pillPhotoURL: URL? = nil) {
        self.dose = dose
        self.med = med
        self.photoURL = photoURL
        self.pillPhotoURL = pillPhotoURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if typeSize.isAccessibilitySize {
                details
                hero
            } else {
                hero
                details
            }
        }
        .background(PgColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.seniorCard, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("now.dose.\(dose.medid)")
    }

    private var brand: String { med?.product.brand ?? "Medicament" }

    private var details: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .center, spacing: Spacing.s) {
                if let pillPhotoURL, !typeSize.isAccessibilitySize {
                    pillThumbnail(pillPhotoURL)
                }
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(brand)
                        .font(.system(size: nameSize, weight: .semibold))
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        QuantityIcon(qty: dose.qty)
                        Text(SeniorDay.quantityWords(dose.qty, form: med?.product.form))
                    }
                    .font(.system(size: textSize, weight: .medium))
                }
            }
            Text(SeniorDay.sentence(dose.instruction))
                .font(.system(size: textSize))
                .foregroundStyle(PgColor.textSecondary)
        }
        .foregroundStyle(PgColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Cutia, întreagă, pe fundalul cardului.
    private var hero: some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                AsyncImage(url: photoURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(Spacing.m)
                    } else {
                        Image(systemName: "pills")
                            .font(.system(size: 56))
                            .foregroundStyle(PgColor.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(PgColor.calmCard)
                    }
                }
            }
            .clipped()
            .accessibilityHidden(true)
    }

    /// Pastila, mică, lângă nume: ajută la recunoaștere, fără să acopere eticheta cutiei.
    /// Fără poză reușită, doar un pătrat liniștit: nu se desenează o pastilă în locul ei.
    private func pillThumbnail(_ url: URL) -> some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit().padding(Spacing.xxs)
            } else {
                Color.clear
            }
        }
        .frame(width: thumbSize, height: thumbSize)
        .background(PgColor.calmCard, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PillPhoto.accessibilityLabel(brand: med?.product.brand ?? "medicament"))
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("now.pillPhoto.\(dose.medid)")
    }
}

/// Un mesaj liniștit pentru pacient: pictogramă în cerc, textul, apoi butoanele. Fără roșu, fără avertizare.
private struct CalmNotice<Actions: View>: View {
    let systemImage: String
    let text: String
    let textIdentifier: String?
    @ViewBuilder let actions: Actions

    @ScaledMetric(relativeTo: .title2) private var textSize: CGFloat = 22
    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize * 0.45, weight: .semibold))
                    .foregroundStyle(PgColor.accent)
                    .frame(width: iconSize, height: iconSize)
                    .background(Circle().fill(PgColor.surface))
                    .accessibilityHidden(true)
                Text(text)
                    .font(.system(size: textSize, weight: .medium))
                    .foregroundStyle(PgColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(textIdentifier ?? "")
            }
            actions
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.seniorCard, style: .continuous)
                .fill(PgColor.calmCard))
    }
}

/// Cardul liniștit pentru o alertă trimisă și pacientului: fără roșu, fără pictogramă de avertizare.
struct PatientNoticeCard: View {
    let caregiverName: String?
    let onDismiss: () -> Void

    var body: some View {
        CalmNotice(systemImage: "phone.fill", text: message, textIdentifier: "now.patientNotice.text") {
            SeniorButton("Am înțeles", prominence: .secondary, identifier: "now.patientNotice.okButton", action: onDismiss)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now.patientNotice")
    }

    private var message: String {
        if let name = caregiverName, !name.isEmpty {
            return "Am anunțat-o pe \(name) despre pastile. Nu schimbați nimic până vă sună."
        }
        return "Am anunțat familia despre pastile. Nu schimbați nimic până vă sună cineva."
    }
}

/// Permisiunea pentru notificări, cerută o singură dată, cu motivul spus înainte.
/// Cele două butoane stau alături când încap, ca întrebarea să nu ocupe jumătate de ecran.
struct ReminderAskCard: View {
    let onAllow: () -> Void
    let onLater: () -> Void

    var body: some View {
        CalmNotice(
            systemImage: "bell.fill", text: "Vreți să sune telefonul la ora pastilelor, chiar dacă e închis?",
            textIdentifier: nil
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.s) { buttons }
                VStack(spacing: Spacing.s) { buttons }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now.reminders")
    }

    @ViewBuilder
    private var buttons: some View {
        SeniorButton("Da", systemImage: "bell", prominence: .secondary,
                     identifier: "now.reminders.allowButton", action: onAllow)
        SeniorButton("Nu acum", prominence: .secondary, identifier: "now.reminders.laterButton", action: onLater)
    }
}

/// Bannerul mare de după „Am luat” / „Am sărit”, cu „Anulează” 5 s.
/// „Anulează” apare exact unde era butonul apăsat, deci ignoră atingerile din primele 800 ms:
/// a doua atingere rapidă pe „Am sărit” nu mai anulează ce a făcut prima (Q3-03).
struct UndoBanner: View {
    static let armDelay: TimeInterval = 0.8

    let status: DoseStatus
    let onUndo: () -> Void

    @ScaledMetric(relativeTo: .title2) private var textSize: CGFloat = 22
    @State private var guarded = GuardedAction(interval: UndoBanner.armDelay)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(status == .taken ? "Am notat că le-ați luat." : "Am notat că le-ați sărit.",
                  systemImage: status == .taken ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: textSize, weight: .semibold))
                .foregroundStyle(PgColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            SeniorButton("Anulează", systemImage: "arrow.uturn.backward", prominence: .secondary,
                         identifier: "now.undoButton") { guarded(onUndo) }
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.seniorCard, style: .continuous)
                .fill(PgColor.calmCard))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now.undoBanner")
        .onAppear { guarded.arm() }
    }
}
