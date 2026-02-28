import NIOCore

// ── TDS Token Types ───────────────────────────────────────────────────────────
//
// Tabular Results stream: the server sends a stream of tokens inside
// TDS_TABULAR packets. Key tokens:
//   0x81 COLMETADATA   – column definitions
//   0xD1 ROW           – a single data row
//   0xFD DONE          – end of result set / statement
//   0xFE DONEPROC      – end of stored procedure
//   0xFF DONEINPROC    – end of in-proc execution
//   0xAA ERROR         – server error
//   0xAB INFO          – informational message
//   0xE3 ENVCHANGE     – environment change (e.g. database change)

enum TDSTokenType: UInt8 {
    case colMetadata  = 0x81
    case row          = 0xD1
    case nbcRow       = 0xD2   // NullBitmap Row (TDS 7.3+)
    case done         = 0xFD
    case doneProc     = 0xFE
    case doneInProc   = 0xFF
    case error        = 0xAA
    case info         = 0xAB
    case envChange    = 0xE3
    case loginAck     = 0xAD
    case returnStatus = 0x79
    case returnValue  = 0xAC
    case orderBy      = 0xA9
    case featureExtAck = 0xAE
    case colInfo      = 0x61   // Column information (sent with TEXT/NTEXT queries)
    case tabName      = 0xA4   // Table name token (sent with TEXT/NTEXT queries)
    case sspi         = 0xED   // SSPI token (NTLM challenge data from server)
}

// MARK: - DONE token flags

struct TDSDoneStatus: OptionSet {
    let rawValue: UInt16
    static let more        = TDSDoneStatus(rawValue: 0x0001)
    static let error       = TDSDoneStatus(rawValue: 0x0002)
    static let inTransaction = TDSDoneStatus(rawValue: 0x0004)
    static let count       = TDSDoneStatus(rawValue: 0x0010)
    static let attention   = TDSDoneStatus(rawValue: 0x0020)
    static let rpcInBatch  = TDSDoneStatus(rawValue: 0x0080)
}

// MARK: - Column type identifiers (subset of TDS data types)

enum TDSDataType: UInt8 {
    // Fixed-length
    case null          = 0x1F
    case bit           = 0x32
    case int1          = 0x30
    case int2          = 0x34
    case int4          = 0x38
    case int8          = 0x7F
    case float4        = 0x3B
    case float8        = 0x3E
    case datetime      = 0x3D
    case datetime4     = 0x3A
    case money         = 0x3C
    case money4        = 0x7A
    case uniqueIdentifier = 0x24

    // Variable-length
    case bitN          = 0x68
    case intN          = 0x26
    case floatN        = 0x6D
    case moneyN        = 0x6E
    case dateTimeN     = 0x6F
    case charN         = 0x2F   // char / varchar (legacy)
    case varChar       = 0xA7   // varchar(n) (TDS 7.x)
    case nVarChar      = 0xE7   // nvarchar(n)
    case text          = 0x23
    case nText         = 0x63
    case image         = 0x22
    case bigChar       = 0xAF
    case bigVarBinary  = 0xA5
    case bigBinary     = 0xAD
    case xml           = 0xF1
    case udt           = 0xF0
    case tvp           = 0xF3
    case date          = 0x28
    case time          = 0x29
    case dateTime2     = 0x2A
    case dateTimeOffset = 0x2B
    case decimal       = 0x6A
    case numeric       = 0x6C
}
