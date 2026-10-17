import CryptoKit
import Foundation

/// Personal data never leaves the device in a property: keys that name it and
/// values shaped like an email or an international phone number are dropped.
/// The server applies the same list again (core/pii.ts), so in the normal case
/// the value never leaves the device at all.
enum Privacy {
    private static let personalKey = try! NSRegularExpression(
        // The server's full list (core/pii.ts KEY_DENY), matched on the folded key.
        pattern: "^(e?mail|emailaddress|(user|customer)email|phone(number)?|mobile(phone)?|tel(ephone)?|gsm|(first|last|full|given|family|display|real|sur)name|((street|home|billing|shipping)?address)|street|pass(wd|word)?|pwd|((access|refresh|id|auth|session)?token)|secret|api(key|secret)|((user|client)?ip(address)?)|dob|dateofbirth|birth(date|day)|card(number)?|creditcard|ccnumber|cv[vc]|iban|ssn|tckn|tckimlik(no)?|nationalid|passport(number)?|taxid)$",
        options: [.caseInsensitive]
    )
    private static let personalValue = try! NSRegularExpression(
        pattern: "^\\s*([^\\s@]+@[^\\s@]+\\.[a-z]{2,}|\\+[\\d\\s().-]{8,22})\\s*$",
        options: [.caseInsensitive]
    )

    static func isPersonalKey(_ key: String) -> Bool {
        let folded = key.replacingOccurrences(of: "[\\s_.-]", with: "", options: .regularExpression)
        return matches(personalKey, folded)
    }

    static func isPersonalValue(_ value: VitrusValue) -> Bool {
        guard case .string(let s) = value else { return false }
        return matches(personalValue, s)
    }

    static func clean(_ props: VitrusProps) -> VitrusProps {
        props.filter { !isPersonalKey($0.key) && !isPersonalValue($0.value) }
    }

    /// `sha256(site + "|" + id)`, lower-case hex — exactly what the browser
    /// tracker sends, so the same person seen on web and in the app is one
    /// person. The raw id never leaves the device.
    static func preHash(site: String, id: String) -> String {
        let digest = SHA256.hash(data: Data("\(site)|\(id)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
