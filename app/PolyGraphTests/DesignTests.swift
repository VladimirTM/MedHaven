import Foundation
import SwiftUI
import Testing
@testable import PolyGraph

@MainActor
struct GuardedActionTests {
    /// Ceas controlat de test (secunde de la pornire).
    private final class FakeUptime {
        var value: TimeInterval = 100
    }

    // T-A1-02
    @Test func secondTapWithin300msIsIgnored() {
        let clock = FakeUptime()
        let guarded = GuardedAction(interval: GuardedAction.seniorInterval) { clock.value }
        var runs = 0

        guarded { runs += 1 }
        clock.value += 0.3
        guarded { runs += 1 }

        #expect(runs == 1)
    }

    // T-A1-02
    @Test func secondTapAfter1200msRuns() {
        let clock = FakeUptime()
        let guarded = GuardedAction(interval: GuardedAction.seniorInterval) { clock.value }
        var runs = 0

        guarded { runs += 1 }
        clock.value += 1.2
        guarded { runs += 1 }

        #expect(runs == 2)
    }

    @Test func ignoredTapDoesNotExtendTheWindow() {
        let clock = FakeUptime()
        let guarded = GuardedAction(interval: 1.0) { clock.value }
        var runs = 0

        guarded { runs += 1 }  // t = 0
        clock.value += 0.6
        let second = guarded { runs += 1 }  // t = 0.6, ignorat
        clock.value += 0.6
        let third = guarded { runs += 1 }  // t = 1.2: fereastra se numără de la ultima execuție

        #expect(!second)
        #expect(third)

        #expect(runs == 2)
    }
}

@MainActor
struct MotionTests {
    // T-A1-03
    @Test func reduceMotionFallsBackToEaseInOut() {
        for animation in [Animation.pgStandard, .pgQuick, .pgMove, .pgFlick] {
            #expect(PgMotion.resolve(animation, reduceMotion: true) == .easeInOut(duration: 0.2))
        }
    }

    @Test func withoutReduceMotionTheTokenIsKept() {
        #expect(PgMotion.resolve(.pgMove, reduceMotion: false) == .pgMove)
        #expect(PgMotion.resolve(.pgMove, reduceMotion: false) != .pgReduced)
    }

    @Test func withPgAnimationRunsTheBody() {
        var ran = false
        withPgAnimation(.pgMove, reduceMotion: true) { ran = true }
        #expect(ran)
    }
}

@MainActor
struct DebugEnvironmentTests {
    @Test func readsReviewVariables() throws {
        let env = DebugEnvironment(environment: [
            "PG_BASE_URL": "http://127.0.0.1:8000",
            "PG_ROLE": "senior",
            "PG_SKIP_ONBOARDING": "1",
            "PG_REDUCE_MOTION": "1",
            "PG_NOW": "2026-11-14T08:05:00+02:00",
            "PG_FAKE_TRANSCRIPT": "mă ia cu amețeală",
        ])
        #expect(env.baseURL == "http://127.0.0.1:8000")
        #expect(env.role == .senior)
        #expect(env.skipOnboarding)
        #expect(env.reduceMotion)
        #expect(!env.resetDemo)
        #expect(env.fakeTranscript == "mă ia cu amețeală")
        let now = try #require(env.now)
        #expect(now == JSONCoding.parseISO8601("2026-11-14T06:05:00Z"))
    }

    @Test func emptyEnvironmentChangesNothing() {
        let env = DebugEnvironment(environment: [:])
        #expect(env.role == nil)
        #expect(env.now == nil)
        #expect(!env.reduceMotion)
        #expect(!env.skipOnboarding)
    }
}

@MainActor
struct APIHelpersTests {
    @Test func baseURLIsNormalized() {
        #expect(AppSettings.normalizedURL("192.168.1.10:8000/")?.absoluteString == "http://192.168.1.10:8000")
        #expect(AppSettings.normalizedURL(" http://127.0.0.1:8000 ")?.absoluteString == "http://127.0.0.1:8000")
        #expect(AppSettings.normalizedURL("") == nil)
    }

    @Test func multipartBodyHasFieldsAndClosingBoundary() {
        var form = MultipartForm(boundary: "B")
        form.addField("kind", "box")
        form.addFile("image", filename: "scan.jpg", mimeType: "image/jpeg", data: Data([0xFF, 0xD8]))
        let text = String(decoding: form.encoded(), as: UTF8.self)
        #expect(text.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"kind\"\r\n\r\nbox\r\n"))
        #expect(text.contains("name=\"image\"; filename=\"scan.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"))
        #expect(text.hasSuffix("--B--\r\n"))
        #expect(form.contentType == "multipart/form-data; boundary=B")
    }

    @Test func fastAPIErrorDetailIsReadable() {
        #expect(APIError.detail(from: Data(#"{"detail":"Pacientul nu există."}"#.utf8)) == "Pacientul nu există.")
        #expect(APIError.detail(from: Data(#"{"detail":[{"msg":"field required"}]}"#.utf8)) == "field required")
        #expect(APIError.http(status: 404, detail: nil).errorDescription != nil)
    }

    /// J-1: -1009 către o adresă din rețeaua locală înseamnă de obicei permisiunea Rețea locală refuzată, nu „offline”.
    @Test func offlineToLocalServerPointsToLocalNetworkPermission() throws {
        #expect(APIError.isLocalHost(URL(string: "http://172.20.10.4:8000/health")))
        #expect(APIError.isLocalHost(URL(string: "http://192.168.2.1:8000")))
        #expect(APIError.isLocalHost(URL(string: "http://mac.local:8000")))
        #expect(!APIError.isLocalHost(URL(string: "http://172.32.0.1:8000")))
        #expect(!APIError.isLocalHost(URL(string: "https://example.com")))
        let url = try #require(URL(string: "http://172.20.10.4:8000/health"))
        let local = APIError.network(URLError(.notConnectedToInternet, userInfo: [NSURLErrorFailingURLErrorKey: url]))
        #expect(local.errorDescription?.contains("Rețea locală") == true)
        #expect(APIError.network(URLError(.notConnectedToInternet)).errorDescription == "Telefonul nu e conectat la rețea.")
    }

    @Test func clockAndDayFormatsAreFixed() throws {
        let date = try #require(PgFormat.date(fromClock: "07:05"))
        #expect(PgFormat.clock(date) == "07:05")
        #expect(PgFormat.medicationCount(1) == "un medicament")
        #expect(PgFormat.medicationCount(3) == "3 medicamente")
        #expect(PgFormat.medicationCount(21) == "21 de medicamente")
    }
}
