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
    private var pending:  String = ""   // partial JSON object buffered across chunks
    private var depth:    Int    = 0    // current `{` nesting depth
    private var inString: Bool   = false
    private var escaped:  Bool   = false

    public init() {}

    /// Feed a text chunk and return all complete JSON objects found.
    ///
    /// Each returned `Data` value is valid UTF-8 JSON representing one top-level object.
    public mutating func feed(_ chunk: String) -> [Data] {
        let combined = pending.isEmpty ? chunk : pending + chunk
        pending = ""

        var results:  [Data]   = []
        var objStart: String.Index? = nil
        var i = combined.startIndex

        while i < combined.endIndex {
            let ch = combined[i]

            if escaped {
                escaped = false
            } else if inString {
                switch ch {
                case "\\": escaped  = true
                case "\"": inString = false
                default:   break
                }
            } else {
                switch ch {
                case "{":
                    if depth == 0 { objStart = i }
                    depth += 1
                case "}":
                    depth -= 1
                    if depth == 0, let start = objStart {
                        let jsonStr = String(combined[start...i])
                        results.append(Data(jsonStr.utf8))
                        objStart = nil
                    }
                case "\"":
                    inString = true
                default:
                    break
                }
            }
            i = combined.index(after: i)
        }

        // Buffer any partial object for the next call
        if let start = objStart {
            pending = String(combined[start...])
        }

        return results
    }

    /// Returns true if there is a partial (incomplete) JSON object buffered.
    public var hasPartial: Bool { !pending.isEmpty }
}
