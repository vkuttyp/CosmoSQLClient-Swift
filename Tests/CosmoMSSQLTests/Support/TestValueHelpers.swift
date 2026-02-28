import CosmoSQLCore
import Foundation

// ── Test-only widening helpers for SQLValue ───────────────────────────────────
//
// The built-in as*() methods require an exact type match.
// These to*() helpers accept any compatible integer/float case.

extension SQLValue {
    /// Converts any integer variant (int, int8, int16, int32, int64) to Int.
    func toInt() -> Int? {
        switch self {
        case .int(let v):   return v
        case .int8(let v):  return Int(v)
        case .int16(let v): return Int(v)
        case .int32(let v): return Int(v)
        case .int64(let v): return Int(exactly: v)
        default:            return nil
        }
    }

    /// Converts any integer variant to Int64.
    func toInt64() -> Int64? {
        switch self {
        case .int64(let v):  return v
        case .int32(let v):  return Int64(v)
        case .int16(let v):  return Int64(v)
        case .int8(let v):   return Int64(v)
        case .int(let v):    return Int64(v)
        default:             return nil
        }
    }

    /// Converts any numeric variant (int*, float, double, decimal) to Double.
    func toDouble() -> Double? {
        switch self {
        case .double(let v):  return v
        case .float(let v):   return Double(v)
        case .decimal(let v): return NSDecimalNumber(decimal: v).doubleValue
        case .int(let v):     return Double(v)
        case .int32(let v):   return Double(v)
        case .int64(let v):   return Double(v)
        default:              return nil
        }
    }
}
