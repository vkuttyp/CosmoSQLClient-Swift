import Foundation

/// Assembles complete JSON objects from a stream of arbitrary text chunks.
///
/// SQL Server's `FOR JSON PATH` fragments output at ~2033-character row boundaries
/// that do not align with JSON object boundaries. Feed each text chunk into `feed(_:)`
/// and receive zero or more complete JSON objects as `Data` values.
///
/// Also useful when streaming JSON from any source where the chunk boundaries are
/// not aligned with JSON object boundaries (e.g., Postgres `json_agg`, or any chunked
/// HTTP response containing a JSON array of objects).
///
/// Example:
/// ```swift
/// var assembler = JSONChunkAssembler()
/// // Each row from FOR JSON PATH is a text chunk
/// for row in rows {
///     if let text = row.values.first?.asString() {
///         for jsonData in assembler.feed(text) {
///             // jsonData is a complete JSON object (e.g. {"Id":1,"Name":"Alice"})
///             let obj = try JSONDecoder().decode(MyType.self, from: jsonData)
///         }
///     }
/// }
/// ```
public struct JSONChunkAssembler {
    // Working buffer — accumulated UTF-8 bytes across calls.
    // Using Data instead of String avoids per-chunk String concatenation and
    // the subsequent re-encoding when extracting found objects.
    private var pending:  Data = Data()
    private var depth:    Int  = 0      // current { nesting depth
    private var inString: Bool = false
    private var escaped:  Bool = false

    // ASCII byte constants — all single-byte, safe to scan in UTF-8.
    private static let openBrace:  UInt8 = 0x7B  // {
    private static let closeBrace: UInt8 = 0x7D  // }
    private static let quote:      UInt8 = 0x22  // "
    private static let backslash:  UInt8 = 0x5C  // \

    public init() {}

    /// Feed a text chunk and return all complete JSON objects found.
    ///
    /// Each returned `Data` value is valid UTF-8 JSON representing one top-level object.
    public mutating func feed(_ chunk: String) -> [Data] {
        // Append UTF-8 bytes directly — one allocation, no intermediate String copy.
        pending.append(contentsOf: chunk.utf8)

        var results:  [Data] = []
        var objStart: Int?   = nil

        for i in 0 ..< pending.count {
            let ch = pending[i]

            if escaped {
                escaped = false
                continue
            }
            if inString {
                if      ch == Self.backslash { escaped  = true  }
                else if ch == Self.quote     { inString = false }
                continue
            }
            switch ch {
            case Self.openBrace:
                if depth == 0 { objStart = i }
                depth += 1
            case Self.closeBrace:
                depth -= 1
                if depth == 0, let start = objStart {
                    // Zero-copy slice into the existing buffer — no re-encoding.
                    results.append(pending[start ... i])
                    objStart = nil
                }
            case Self.quote:
                inString = true
            default:
                break
            }
        }

        // Retain only the partial object (if any) for the next call.
        if let start = objStart {
            pending = Data(pending[start...])
        } else {
            pending = Data()
        }

        return results
    }

    /// Returns true if there is a partial (incomplete) JSON object buffered.
    public var hasPartial: Bool { !pending.isEmpty }
}
