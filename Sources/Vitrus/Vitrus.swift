import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Cookie-free, privacy-first analytics for Swift apps.
///
/// ```swift
/// Vitrus.shared.configure(site: "SITE_ID")
/// Vitrus.shared.screen("Invoices")
/// Vitrus.shared.track("invoice_sent", ["items": 3])
/// Vitrus.shared.identify(user.id)          // hashed on device, never sent raw
/// Vitrus.shared.plan("pro")
/// ```
///
/// What leaves the device: screen and event names, their properties (personal
/// fields removed), a SHA-256 of your user id if you call `identify`, the app
/// version, the OS and the device class. What does not: the raw user id, the
/// IDFA, any persistent device identifier — the visitor value is random and
/// regenerated every UTC day.
public final class Vitrus: @unchecked Sendable {
    public static let shared = Vitrus()

    private var client: VitrusClient?
    private let lock = NSLock()

    public init() {}

    /// Start Vitrus. Call once, early (e.g. in `App.init` or `application(_:didFinishLaunchingWithOptions:)`).
    /// - Parameters:
    ///   - site: the site id from the Vitrus dashboard (Install).
    ///   - host: your Vitrus server; the cloud by default, your own for self-hosted.
    ///   - trackAppOpen: send `app_open` when the app becomes active.
    public func configure(
        site: String,
        host: URL = URL(string: "https://app.vitrus.dev")!,
        trackAppOpen: Bool = true,
        flushInterval: TimeInterval = 15
    ) {
        configure(VitrusConfig(site: site, host: host, trackAppOpen: trackAppOpen, flushInterval: flushInterval))
    }

    /// For tests and advanced setups: inject the transport, storage and clock.
    public func configure(_ config: VitrusConfig, environment: VitrusEnvironment = .live) {
        let c = VitrusClient(config: config, env: environment)
        lock.lock(); client = c; lock.unlock()
        Task { await c.start() }
    }

    private func current() -> VitrusClient? {
        lock.lock(); defer { lock.unlock() }
        return client
    }

    private func with(_ body: @escaping @Sendable (VitrusClient) async -> Void) {
        guard let c = current() else { return }
        Task { await body(c) }
    }

    /// A screen view — the app's page view. Reported as the path `/screen/<name>`.
    public func screen(_ name: String, _ props: VitrusProps = [:]) { with { await $0.screen(name, props) } }

    /// A custom event: what people do in your app (`invoice_sent`, `lesson_created`).
    public func track(_ name: String, _ props: VitrusProps = [:]) { with { await $0.track(name, props) } }

    /// The signed-in user, so retention, lifecycle and the Users page can count them.
    /// The id is hashed on device (`sha256(site + "|" + id)`); pass `nil` on sign-out.
    public func identify(_ userId: String?, traits: VitrusProps = [:]) { with { await $0.identify(userId, traits) } }

    /// The user's plan changed (`free`, `pro`, `cancelled` — your own labels).
    public func plan(_ plan: String) { with { await $0.track("plan", ["plan": .string(plan)]) } }

    /// A payment: amount in the currency's main unit (dollars, not cents) and an ISO 4217 code.
    public func revenue(_ amount: Double, currency: String, event: String = "purchase", _ props: VitrusProps = [:]) {
        var p = props
        p["revenue"] = .number(amount)
        p["currency"] = .string(currency.uppercased())
        let props = p
        with { await $0.track(event, props) }
    }

    /// Send what is queued now (normally automatic: every few seconds, and when the app goes to the background).
    public func flush() async {
        await current()?.flush()
    }
}

public struct VitrusConfig: Sendable {
    public var site: String
    public var host: URL
    public var trackAppOpen: Bool
    public var flushInterval: TimeInterval
    /// Shown as the release tag (deploy correlation); defaults to CFBundleShortVersionString.
    public var appVersion: String?

    public init(site: String, host: URL = URL(string: "https://app.vitrus.dev")!, trackAppOpen: Bool = true, flushInterval: TimeInterval = 15, appVersion: String? = nil) {
        self.site = site
        self.host = host
        self.trackAppOpen = trackAppOpen
        self.flushInterval = flushInterval
        self.appVersion = appVersion
    }
}

/// The outside world, injectable for tests.
public struct VitrusEnvironment: Sendable {
    /// POSTs a body and returns the HTTP status; throws on a network failure.
    public var send: @Sendable (_ url: URL, _ body: Data, _ userAgent: String) async throws -> Int
    public var defaults: @Sendable () -> UserDefaults
    /// Monotonic seconds (not wall time) — measures how long ago an event happened.
    public var uptime: @Sendable () -> TimeInterval
    /// Wall-clock milliseconds — used ONLY for events queued in an earlier launch, and for the UTC day.
    public var wallMs: @Sendable () -> Double
    public var randomBytes: @Sendable (Int) -> [UInt8]
    public var observeLifecycle: Bool

    public init(
        send: @escaping @Sendable (URL, Data, String) async throws -> Int,
        defaults: @escaping @Sendable () -> UserDefaults,
        uptime: @escaping @Sendable () -> TimeInterval,
        wallMs: @escaping @Sendable () -> Double,
        randomBytes: @escaping @Sendable (Int) -> [UInt8],
        observeLifecycle: Bool
    ) {
        self.send = send
        self.defaults = defaults
        self.uptime = uptime
        self.wallMs = wallMs
        self.randomBytes = randomBytes
        self.observeLifecycle = observeLifecycle
    }

    public static let live = VitrusEnvironment(
        send: { url, body, ua in
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 20
            let (_, res) = try await URLSession.shared.data(for: req)
            return (res as? HTTPURLResponse)?.statusCode ?? 0
        },
        defaults: { UserDefaults.standard },
        uptime: { ProcessInfo.processInfo.systemUptime },
        wallMs: { Date().timeIntervalSince1970 * 1000 },
        randomBytes: { n in (0..<n).map { _ in UInt8.random(in: 0...255) } },
        observeLifecycle: true
    )
}

/// One queued event, with what is needed to say how long ago it happened.
struct Queued: Codable, Equatable {
    var payload: Data
    /// The launch it was recorded in; within it, `uptime` is the clock.
    var launch: String
    var uptime: TimeInterval
    var wallMs: Double
}

actor VitrusClient {
    static let sdkVersion = "0.1.1"
    static let batchMax = 50
    static let queueMax = 1000
    /// The server refuses events older than a day (validate.ts AGO_MAX).
    static let maxAgeMs: Double = 86_400_000

    let config: VitrusConfig
    let env: VitrusEnvironment
    let launch = UUID().uuidString
    private(set) var queue: [Queued] = []
    private var identity: String?
    private var inFlight: Task<Void, Never>?
    private var failures = 0
    private var timer: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    /// Read once on the main actor at start (UIDevice is main-actor isolated).
    private var ua = VitrusClient.userAgent(pad: false)
    nonisolated func setUserAgent(_ value: String) { Task { await self.storeUserAgent(value) } }
    private func storeUserAgent(_ value: String) { ua = value }

    init(config: VitrusConfig, env: VitrusEnvironment) {
        self.config = config
        self.env = env
    }

    private var queueKey: String { "vitrus.queue.\(config.site)" }

    func start() {
        if let data = env.defaults().data(forKey: queueKey), let saved = try? JSONDecoder().decode([Queued].self, from: data) {
            queue = saved + queue
        }
        if config.trackAppOpen { enqueue(event(type: "event", name: "app_open", url: "/screen/app", props: [:])) }
        let interval = max(1, config.flushInterval)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.flush()
            }
        }
        #if os(iOS)
        // An actor is Sendable: hand the closures the reference itself rather
        // than a captured `weak self` var. The client lives as long as the app.
        let me = self
        Task { @MainActor in
            me.setUserAgent(Self.userAgent(pad: UIDevice.current.userInterfaceIdiom == .pad))
        }
        if env.observeLifecycle {
            Task { @MainActor in
                let nc = NotificationCenter.default
                let bg = nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
                    Task { await me.persist(); await me.flush() }
                }
                let fg = nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { _ in
                    Task { await me.appOpened() }
                }
                await me.keep([bg, fg])
            }
        }
        #endif
    }

    private func keep(_ o: [NSObjectProtocol]) { observers.append(contentsOf: o) }
    private func appOpened() { if config.trackAppOpen { enqueue(event(type: "event", name: "app_open", url: "/screen/app", props: [:])) } }

    func screen(_ name: String, _ props: VitrusProps) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        let path = "/screen/" + (clean.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? clean)
        enqueue(event(type: "pageview", name: nil, url: path, props: props, title: clean))
    }

    func track(_ name: String, _ props: VitrusProps) {
        guard name.range(of: "^[A-Za-z0-9_.:-]{1,80}$", options: .regularExpression) != nil else { return }
        enqueue(event(type: "event", name: name, url: "/screen/app", props: props))
    }

    func identify(_ userId: String?, _ traits: VitrusProps) {
        let raw = userId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        identity = raw.isEmpty ? nil : Privacy.preHash(site: config.site, id: raw)
        if identity != nil && !traits.isEmpty { enqueue(event(type: "event", name: "identify", url: "/screen/app", props: traits)) }
    }

    /// The daily device value: random, regenerated when the UTC day changes, never derived from the device.
    func nonce() -> String {
        let day = Self.utcDay(env.wallMs())
        let d = env.defaults()
        if d.string(forKey: "vitrus.nonce.day") == day, let n = d.string(forKey: "vitrus.nonce"), !n.isEmpty { return n }
        let n = Data(env.randomBytes(18)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        d.set(n, forKey: "vitrus.nonce")
        d.set(day, forKey: "vitrus.nonce.day")
        return n
    }

    static func utcDay(_ ms: Double) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    private func event(type: String, name: String?, url: String, props: VitrusProps, title: String? = nil) -> [String: Any] {
        var e: [String: Any] = ["site": config.site, "type": type, "url": url, "nonce": nonce()]
        if let name { e["name"] = name }
        if let title { e["title"] = title }
        if let identity { e["identity"] = identity }
        if let host = Bundle.main.bundleIdentifier?.lowercased(), host.range(of: "^[a-z0-9.-]{1,253}$", options: .regularExpression) != nil { e["hostname"] = host }
        if let v = config.appVersion ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) { e["tag"] = String(v.prefix(40)) }
        if let lang = Locale.preferredLanguages.first, lang.range(of: "^[A-Za-z-]{2,35}$", options: .regularExpression) != nil { e["lang"] = lang.lowercased() }
        let clean = Privacy.clean(props)
        if !clean.isEmpty { e["props"] = clean.mapValues { $0.json } }
        return e
    }

    private func enqueue(_ e: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: e) else { return }
        queue.append(Queued(payload: data, launch: launch, uptime: env.uptime(), wallMs: env.wallMs()))
        if queue.count > Self.queueMax { queue.removeFirst(queue.count - Self.queueMax) }
        // A full batch goes out at once; anything smaller waits for the timer or the background.
        if queue.count >= Self.batchMax && inFlight == nil { Task { await self.flush(fullBatchesOnly: true) } }
    }

    /// How long ago, in ms: the monotonic clock within this launch; the wall clock across launches.
    func ago(_ q: Queued) -> Double {
        let ms = q.launch == launch ? (env.uptime() - q.uptime) * 1000 : env.wallMs() - q.wallMs
        return max(0, ms.rounded())
    }

    func persist() {
        if let data = try? JSONEncoder().encode(queue) { env.defaults().set(data, forKey: queueKey) }
    }

    /// Sends the queue. A call made while a send is running waits for it, then sends what is left.
    func flush(fullBatchesOnly: Bool = false) async {
        if let running = inFlight { await running.value }
        // The send that just finished cleared `inFlight` itself (drain's defer),
        // so a waiter never spins on a finished task; if another waiter already
        // started the next send, wait for that one instead of starting a second.
        if let running = inFlight { await running.value; return }
        guard !queue.isEmpty else { return }
        let t = Task { await self.drain(fullBatchesOnly: fullBatchesOnly) }
        inFlight = t
        await t.value
    }

    private func drain(fullBatchesOnly: Bool) async {
        defer { persist(); inFlight = nil }
        // Events past the server's one-day limit would be refused; drop them here.
        queue.removeAll { ago($0) > Self.maxAgeMs }
        while !queue.isEmpty && (!fullBatchesOnly || queue.count >= Self.batchMax) {
            let chunk = Array(queue.prefix(Self.batchMax))
            let events: [Any] = chunk.compactMap { q in
                guard var e = (try? JSONSerialization.jsonObject(with: q.payload)) as? [String: Any] else { return nil }
                let a = ago(q)
                if a > 0 { e["ago"] = a }
                return e
            }
            guard let body = try? JSONSerialization.data(withJSONObject: ["events": events]) else { queue.removeFirst(chunk.count); continue }
            do {
                let status = try await env.send(config.host.appendingPathComponent("api/batch"), body, ua)
                if status == 200 || (400..<500).contains(status) && status != 429 {
                    // 200: sent. A 4xx other than 429 will not get better by retrying — drop it.
                    queue.removeFirst(min(chunk.count, queue.count))
                    failures = 0
                } else {
                    failures += 1
                    return
                }
            } catch {
                failures += 1
                return
            }
        }
    }

    /// `Vitrus-iOS/0.1.0 (iPhone; iOS 18.0) MyApp/2.3` — the server buckets it as an app.
    static func userAgent(pad: Bool) -> String {
        let app = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "App").replacingOccurrences(of: " ", with: "")
        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let v = "\(osv.majorVersion).\(osv.minorVersion)"
        #if os(iOS)
        return "Vitrus-iOS/\(sdkVersion) (\(pad ? "iPad" : "iPhone"); iOS \(v)) \(app)/\(ver)"
        #else
        return "Vitrus-Swift/\(sdkVersion) (Mac; macOS \(v)) \(app)/\(ver)"
        #endif
    }

    /// The Apple privacy manifest that ships in the package (tests read it).
    static var privacyManifestURL: URL? { Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") }

    // Test hooks
    func snapshot() -> [Queued] { queue }
    func currentIdentity() -> String? { identity }
}
