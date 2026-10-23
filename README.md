# Vitrus for Swift

Cookie-free, privacy-first analytics for iOS, iPadOS and macOS apps — the native SDK for
[Vitrus](https://vitrus.dev), the open-source analytics where every number opens the query that counted it.

- **Zero dependencies** — Foundation and CryptoKit.
- **Your users' ids never leave the device**: `identify` sends a SHA-256, hashed again on the server.
- **No IDFA, no persistent device id, no tracking** — no App Tracking Transparency prompt. A privacy manifest ships in the package.
- **Offline queue** with batching, and honest timestamps for events sent later.
- Your app shows up next to your website in the same workspace: **Portfolio, Users, Lifecycle**.

## Install

Swift Package Manager — in Xcode, *File → Add Package Dependencies…* and paste:

```
https://github.com/Vitrus-Dev/vitrus-swift
```

or in `Package.swift`:

```swift
.package(url: "https://github.com/Vitrus-Dev/vitrus-swift", from: "0.1.1")
```

## Use

```swift
import Vitrus

// once, at launch — the site id is on the dashboard's Install page
Vitrus.shared.configure(site: "SITE_ID")

// screens and what people do
Vitrus.shared.screen("Invoices")
Vitrus.shared.track("invoice_sent", ["items": 3])

// the signed-in user: on every launch while signed in, nil on sign-out
Vitrus.shared.identify(user.id)
Vitrus.shared.identify(nil)

// plans and money
Vitrus.shared.plan("pro")
Vitrus.shared.revenue(4.99, currency: "USD")
```

SwiftUI: call `screen` from `.onAppear` of each top-level view. Self-hosted:
`configure(site: "SITE_ID", host: URL(string: "https://analytics.example.com")!)`.

## What is sent

| Sent | Not sent |
|---|---|
| Screen and event names, their properties (personal fields removed) | Your user's raw id, email, name or phone |
| `sha256(site + "\|" + userId)` when you call `identify` | IDFA, IDFV, any persistent device identifier |
| App version, OS and version, iPhone / iPad / Mac | Location, contacts, anything from other apps |
| A random value regenerated every UTC day (counts visitors without following anyone) | Precise timestamps from the device clock |

Properties whose key names personal data (`email`, `phone`, `first_name`, `address`, `password`, `token`, `ip`, …) and
values shaped like an email address or an international phone number are dropped on the device — and again on the server.

**How times work.** The server's clock is the clock. An event sent later carries how long ago it happened, measured with
the monotonic clock; only events queued in an earlier launch fall back to the wall clock. Events older than a day are
dropped, as the server would refuse them.

**Sending.** Events go to `/api/batch` in batches of up to 50: when 50 are waiting, every 15 seconds, and when the app goes
to the background. Offline or a 5xx: kept and retried. A 4xx other than 429: dropped — retrying would not change it.

## App Store

The package includes `PrivacyInfo.xcprivacy`: no tracking; *Product Interaction* (not linked) and, only if you call
`identify`, *User ID* (linked, hashed) — both for *Analytics*; UserDefaults (`CA92.1`) for the daily value and the queue,
system boot time (`35F9.1`) to measure how long ago an event happened. In App Store Connect's privacy questions answer the
same, and *No* to tracking.

## License

Apache-2.0. The server and dashboard: [Vitrus-Dev/vitrus](https://github.com/Vitrus-Dev/vitrus).
