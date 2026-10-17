import CryptoKit
import XCTest
@testable import Vitrus

/// A fake world: captured requests, a settable clock, deterministic randomness.
final class World: @unchecked Sendable {
    var sent: [[String: Any]] = []
    var agents: [String] = []
    var status = 200
    var fail = false
    var uptime: TimeInterval = 1000
    var wall: Double = 1_792_231_200_000 // 2026-10-17 12:00 UTC
    var seed: UInt8 = 1
    let defaults: UserDefaults

    init() {
        let name = "vitrus.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    var env: VitrusEnvironment {
        VitrusEnvironment(
            send: { [unowned self] _, body, ua in
                if self.fail { throw URLError(.notConnectedToInternet) }
                let o = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                self.sent.append(contentsOf: o["events"] as! [[String: Any]])
                self.agents.append(ua)
                return self.status
            },
            defaults: { [unowned self] in self.defaults },
            uptime: { [unowned self] in self.uptime },
            wallMs: { [unowned self] in self.wall },
            randomBytes: { [unowned self] n in self.seed &+= 1; return [UInt8](repeating: self.seed, count: n) },
            observeLifecycle: false
        )
    }
}

final class VitrusTests: XCTestCase {
    func client(_ w: World, appOpen: Bool = false) -> VitrusClient {
        VitrusClient(config: VitrusConfig(site: "site_1", host: URL(string: "https://example.test")!, trackAppOpen: appOpen, flushInterval: 3600, appVersion: "2.3.0"), env: w.env)
    }

    func testScreenAndEventPayloads() async {
        let w = World(); let c = client(w)
        await c.screen("Invoices", [:])
        await c.track("invoice_sent", ["items": 3, "paid": true])
        await c.flush()
        XCTAssertEqual(w.sent.count, 2)
        XCTAssertEqual(w.sent[0]["type"] as? String, "pageview")
        XCTAssertEqual(w.sent[0]["url"] as? String, "/screen/Invoices")
        XCTAssertEqual(w.sent[0]["tag"] as? String, "2.3.0")
        XCTAssertEqual(w.sent[1]["name"] as? String, "invoice_sent")
        XCTAssertEqual((w.sent[1]["props"] as? [String: Any])?["items"] as? Double, 3)
        XCTAssertTrue(w.agents[0].hasPrefix("Vitrus-"))
        let empty = await c.snapshot()
        XCTAssertTrue(empty.isEmpty)
    }

    func testIdentifyIsHashedOnDeviceAndMatchesTheBrowser() async {
        let w = World(); let c = client(w)
        await c.identify("ayse@example.com", ["plan": "pro", "email": "ayse@example.com"])
        await c.screen("Home", [:])
        await c.flush()
        let expected = SHA256.hash(data: Data("site_1|ayse@example.com".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(w.sent.count, 2)
        for e in w.sent { XCTAssertEqual(e["identity"] as? String, expected) }
        let all = String(data: try! JSONSerialization.data(withJSONObject: w.sent), encoding: .utf8)!
        XCTAssertFalse(all.contains("ayse"), "the raw id and the email trait never leave the device")
        XCTAssertEqual((w.sent[0]["props"] as? [String: Any])?["plan"] as? String, "pro")
        await c.identify(nil, [:])
        let id = await c.currentIdentity()
        XCTAssertNil(id)
    }

    func testPersonalPropertiesAreDropped() {
        let p = Privacy.clean(["Email": "a@b.co", "phone_number": "x", "contact": "+90 532 111 22 33", "note": "a@b.co", "plan": "pro", "seats": 3])
        XCTAssertEqual(p, ["plan": "pro", "seats": 3])
    }

    func testAgoUsesTheMonotonicClockWithinALaunch() async {
        let w = World(); let c = client(w)
        await c.track("offline_thing", [:])
        w.uptime += 90          // 90 s offline
        w.wall += 5_000_000     // the wall clock jumped; it must not matter
        await c.flush()
        XCTAssertEqual(w.sent.first?["ago"] as? Double, 90_000)
    }

    func testEventsFromAnEarlierLaunchUseTheWallClock() async {
        let w = World()
        let first = client(w)
        await first.track("before_restart", [:])
        await first.persist()
        w.wall += 60_000
        let second = client(w)
        await second.start()
        w.fail = false
        await second.flush()
        XCTAssertEqual(w.sent.first?["name"] as? String, "before_restart")
        XCTAssertEqual(w.sent.first?["ago"] as? Double, 60_000)
    }

    func testNonceIsRandomAndRotatesAtUtcMidnight() async {
        let w = World(); let c = client(w)
        let a = await c.nonce()
        let again = await c.nonce()
        XCTAssertEqual(a, again)
        XCTAssertGreaterThanOrEqual(a.count, 16)
        XCTAssertNotNil(a.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression))
        w.wall += 86_400_000
        let tomorrow = await c.nonce()
        XCTAssertNotEqual(a, tomorrow)
    }

    func testBatchesOfFiftyAndRetryRules() async {
        let w = World(); let c = client(w)
        for i in 0..<120 { await c.track("e\(i)", [:]) }
        await c.flush()
        XCTAssertEqual(w.sent.count, 120)
        XCTAssertEqual(w.agents.count, 3, "50 + 50 + 20")

        // Offline: kept for later.
        w.sent = []; w.fail = true
        await c.track("kept", [:])
        await c.flush()
        let kept = await c.snapshot()
        XCTAssertEqual(kept.count, 1)
        // 503: kept. 400: dropped — retrying would not fix it.
        w.fail = false; w.status = 503
        await c.flush()
        let still = await c.snapshot()
        XCTAssertEqual(still.count, 1)
        w.status = 400
        await c.flush()
        let gone = await c.snapshot()
        XCTAssertEqual(gone.count, 0)
    }

    func testEventsOlderThanADayAreDroppedNotSent() async {
        let w = World(); let c = client(w)
        await c.track("ancient", [:])
        w.uptime += 86_401
        await c.flush()
        XCTAssertTrue(w.sent.isEmpty)
    }

    func testInvalidEventNamesAreIgnored() async {
        let w = World(); let c = client(w)
        await c.track("has spaces", [:])
        await c.track("", [:])
        let q = await c.snapshot()
        XCTAssertTrue(q.isEmpty)
    }

    func testPrivacyManifestShipsWithThePackage() {
        let url = VitrusClient.privacyManifestURL
        XCTAssertNotNil(url)
        let text = try! String(contentsOf: url!, encoding: .utf8)
        XCTAssertTrue(text.contains("<key>NSPrivacyTracking</key>\n\t<false/>"))
    }
}

/// Against a real Vitrus server, only when asked: VITRUS_E2E_HOST=http://localhost:3077 VITRUS_E2E_SITE=… swift test
final class LiveServerTests: XCTestCase {
    func testEventsReachARealServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VITRUS_E2E_HOST"], let site = env["VITRUS_E2E_SITE"] else { throw XCTSkip("set VITRUS_E2E_HOST and VITRUS_E2E_SITE") }
        let name = "vitrus.e2e.\(UUID().uuidString)"
        var live = VitrusEnvironment.live
        live.defaults = { UserDefaults(suiteName: name)! }
        live.observeLifecycle = false
        final class Box: @unchecked Sendable { var statuses: [Int] = [] }
        let box = Box()
        let send = live.send
        live.send = { url, body, ua in let s = try await send(url, body, ua); box.statuses.append(s); return s }
        let c = VitrusClient(config: VitrusConfig(site: site, host: URL(string: host)!, trackAppOpen: true, flushInterval: 3600, appVersion: "0.1.0-e2e"), env: live)
        await c.start()
        await c.identify("e2e-user-1", ["plan": "pro"])
        await c.screen("E2E", [:])
        await c.track("e2e_action", ["n": 1])
        await c.flush()
        XCTAssertEqual(box.statuses, [200])
        let left = await c.snapshot()
        XCTAssertTrue(left.isEmpty)
    }
}
