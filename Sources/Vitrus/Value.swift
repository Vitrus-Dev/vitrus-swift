import Foundation

/// A property value. Vitrus accepts scalars only — nested objects are refused
/// by the server (bloat and personal-data risk), so they cannot be built here.
public enum VitrusValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    var json: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }
}

extension VitrusValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
}

public typealias VitrusProps = [String: VitrusValue]
