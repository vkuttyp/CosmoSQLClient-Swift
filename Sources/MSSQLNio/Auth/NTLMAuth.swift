import Foundation

// ── NTLMv2 Authentication ─────────────────────────────────────────────────────
//
// Implements the NTLMv2 authentication protocol used by Windows domain auth.
// Reference: MS-NLMP (https://docs.microsoft.com/en-us/openspecs/windows_protocols/ms-nlmp)
//
// Flow (within TDS Login7 exchange):
//  1. Client → Server: Login7 with SSPI = NTLM_NEGOTIATE (type 1)
//  2. Server → Client: SSPI token (0xED) containing NTLM_CHALLENGE (type 2)
//  3. Client → Server: SSPI packet (type 0x11) with NTLM_AUTHENTICATE (type 3)

enum NTLMAuth {

    // NTLMSSP negotiate flags: Unicode + NTLM + extended session security + 128-bit + key exchange
    private static let negotiateFlags: UInt32 = 0x62_08_82_35

    // MARK: - Step 1: NTLM_NEGOTIATE

    /// Build the NTLM NEGOTIATE message (type 1) to embed in Login7 SSPI field.
    static func buildNegotiate() -> [UInt8] {
        var msg = [UInt8]()
        msg.append(contentsOf: ntlmSignature)
        msg.append(contentsOf: uint32LE(1))               // MessageType = 1
        msg.append(contentsOf: uint32LE(negotiateFlags))  // NegotiateFlags
        // DomainNameFields (len=0, maxLen=0, offset=0)
        msg.append(contentsOf: [0,0, 0,0, 0,0,0,0])
        // WorkstationFields (len=0, maxLen=0, offset=0)
        msg.append(contentsOf: [0,0, 0,0, 0,0,0,0])
        // Version (8 bytes: Windows 10 marker)
        msg.append(contentsOf: [0x0A, 0x00, 0x3F, 0x00, 0x00, 0x00, 0x00, 0x0F])
        return msg
    }

    // MARK: - Step 2: Parse NTLM_CHALLENGE

    struct NTLMChallenge {
        let serverChallenge: [UInt8]   // 8 bytes
        let targetInfo:      [UInt8]   // MsvAvPair blob from server
        let negotiateFlags:  UInt32
    }

    /// Parse the NTLM CHALLENGE message (type 2) received from the server.
    static func parseChallenge(_ data: [UInt8]) throws -> NTLMChallenge {
        guard data.count >= 56 else { throw NTLMError.invalidChallenge }
        guard Array(data.prefix(8)) == ntlmSignature,
              uint32(data, at: 8) == 2 else { throw NTLMError.invalidChallenge }
        let flags     = uint32(data, at: 20)
        let challenge = Array(data[24..<32])
        // TargetInfoFields at offset 40: len(2) + maxLen(2) + offset(4)
        let tiLen    = Int(uint16(data, at: 40))
        let tiOffset = Int(uint32(data, at: 44))
        var targetInfo = [UInt8]()
        if tiLen > 0, tiOffset + tiLen <= data.count {
            targetInfo = Array(data[tiOffset..<(tiOffset + tiLen)])
        }
        return NTLMChallenge(serverChallenge: challenge, targetInfo: targetInfo, negotiateFlags: flags)
    }

    // MARK: - Step 3: NTLM_AUTHENTICATE

    /// Build the NTLM AUTHENTICATE message (type 3) with NTLMv2 response.
    static func buildAuthenticate(
        challenge:   [UInt8],
        username:    String,
        password:    String,
        domain:      String,
        workstation: String
    ) throws -> [UInt8] {
        let parsed = try parseChallenge(challenge)

        // Derive NTLMv2 key: HMAC-MD5(MD4(UTF-16LE(password)), UTF-16LE(UPPER(user) + domain))
        // Per MS-NLMP spec: only username is uppercased, domain keeps original case.
        let ntHash    = md4(utf16le(password))
        let ntlmv2Key = hmacMD5(key: ntHash, data: utf16le(username.uppercased() + domain))

        // NTLMv2 blob
        let clientChallenge = randomBytes(8)
        let timestamp       = windowsTimestamp()
        let blob            = buildBlob(timestamp: timestamp,
                                        clientChallenge: clientChallenge,
                                        targetInfo: parsed.targetInfo)

        // NT response = HMAC-MD5(ntlmv2Key, serverChallenge + blob) + blob
        let ntProofStr = hmacMD5(key: ntlmv2Key, data: parsed.serverChallenge + blob)
        let ntResponse = ntProofStr + blob

        // LM response = HMAC-MD5(ntlmv2Key, serverChallenge + clientChallenge) + clientChallenge
        let lmResponse = hmacMD5(key: ntlmv2Key, data: parsed.serverChallenge + clientChallenge)
                       + clientChallenge

        // Encode UTF-16LE field data
        let domainBytes = utf16le(domain)
        let userBytes   = utf16le(username)
        let wsBytes     = utf16le(workstation)

        // Type-3 header is 72 bytes (fixed fields before payload)
        let headerSize = 72
        var payload    = [UInt8]()

        // Returns SecurityBuffer fields (len, maxLen, offset) and appends data to payload
        func fields(for bytes: [UInt8]) -> (UInt16, UInt16, UInt32) {
            let off = UInt32(headerSize + payload.count)
            payload.append(contentsOf: bytes)
            return (UInt16(bytes.count), UInt16(bytes.count), off)
        }

        let lmF  = fields(for: lmResponse)
        let ntF  = fields(for: ntResponse)
        let domF = fields(for: domainBytes)
        let usrF = fields(for: userBytes)
        let wsF  = fields(for: wsBytes)

        var msg = [UInt8]()
        msg.append(contentsOf: ntlmSignature)
        msg.append(contentsOf: uint32LE(3))               // MessageType = 3
        msg.append(contentsOf: secBuf(lmF))               // LmChallengeResponseFields
        msg.append(contentsOf: secBuf(ntF))               // NtChallengeResponseFields
        msg.append(contentsOf: secBuf(domF))              // DomainNameFields
        msg.append(contentsOf: secBuf(usrF))              // UserNameFields
        msg.append(contentsOf: secBuf(wsF))               // WorkstationFields
        msg.append(contentsOf: [0,0, 0,0, 0,0,0,0])      // EncryptedRandomSessionKey (empty)
        msg.append(contentsOf: uint32LE(negotiateFlags))  // NegotiateFlags
        msg.append(contentsOf: payload)
        return msg
    }

    // MARK: - Helpers

    private static let ntlmSignature: [UInt8] = [0x4E,0x54,0x4C,0x4D,0x53,0x53,0x50,0x00]

    private static func buildBlob(timestamp: [UInt8], clientChallenge: [UInt8],
                                  targetInfo: [UInt8]) -> [UInt8] {
        var b = [UInt8]()
        b.append(contentsOf: [0x01,0x01,0x00,0x00])   // Blob signature (RespType + HiRespType)
        b.append(contentsOf: [0x00,0x00,0x00,0x00])   // Reserved
        b.append(contentsOf: timestamp)                 // FILETIME (8 bytes)
        b.append(contentsOf: clientChallenge)           // ClientChallenge (8 bytes)
        b.append(contentsOf: [0x00,0x00,0x00,0x00])   // Reserved
        b.append(contentsOf: targetInfo)                // AvPairs from server
        b.append(contentsOf: [0x00,0x00,0x00,0x00])   // MsvAvEOL terminator
        return b
    }

    private static func secBuf(_ t: (UInt16, UInt16, UInt32)) -> [UInt8] {
        uint16LE(t.0) + uint16LE(t.1) + uint32LE(t.2)
    }

    private static func utf16le(_ s: String) -> [UInt8] {
        var r = [UInt8](); r.reserveCapacity(s.utf16.count * 2)
        for u in s.utf16 { r.append(UInt8(u & 0xFF)); r.append(UInt8(u >> 8)) }
        return r
    }

    private static func windowsTimestamp() -> [UInt8] {
        // 100-nanosecond intervals since 1601-01-01 UTC
        let offset: UInt64 = 116_444_736_000_000_000
        let now = UInt64(Date().timeIntervalSince1970 * 10_000_000) + offset
        return uint64LE(now)
    }

    private static func randomBytes(_ n: Int) -> [UInt8] {
        (0..<n).map { _ in UInt8.random(in: 0...255) }
    }

    private static func uint16(_ d: [UInt8], at i: Int) -> UInt16 {
        UInt16(d[i]) | UInt16(d[i+1]) << 8
    }
    private static func uint32(_ d: [UInt8], at i: Int) -> UInt32 {
        UInt32(d[i]) | UInt32(d[i+1])<<8 | UInt32(d[i+2])<<16 | UInt32(d[i+3])<<24
    }
    private static func uint16LE(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8(v >> 8)]
    }
    private static func uint32LE(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v>>8)&0xFF), UInt8((v>>16)&0xFF), UInt8((v>>24)&0xFF)]
    }
    private static func uint64LE(_ v: UInt64) -> [UInt8] {
        (0..<8).map { UInt8((v >> ($0*8)) & 0xFF) }
    }
}

// MARK: - MD4 (RFC 1320) — needed for NT hash

/// Pure Swift MD4 hash. Required for NTLMv2 NT password hash computation.
func md4(_ input: [UInt8]) -> [UInt8] {
    var A: UInt32 = 0x67452301
    var B: UInt32 = 0xEFCDAB89
    var C: UInt32 = 0x98BADCFE
    var D: UInt32 = 0x10325476

    // Padding
    var data = input
    let originalLen = data.count
    data.append(0x80)
    while data.count % 64 != 56 { data.append(0x00) }
    let bitLen = UInt64(originalLen) * 8
    for i in 0..<8 { data.append(UInt8((bitLen >> (i*8)) & 0xFF)) }

    func F(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (~x & z) }
    func G(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { (x & y) | (x & z) | (y & z) }
    func H(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 { x ^ y ^ z }
    func rol(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    for blk in stride(from: 0, to: data.count, by: 64) {
        var X = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            let o = blk + i*4
            X[i] = UInt32(data[o]) | UInt32(data[o+1])<<8 | UInt32(data[o+2])<<16 | UInt32(data[o+3])<<24
        }
        var a = A, b = B, c = C, d = D

        // Round 1 (constant = 0)
        for (i, s): (Int, UInt32) in zip([0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],
                                          [3,7,11,19,3,7,11,19,3,7,11,19,3,7,11,19]) {
            a = rol(a &+ F(b,c,d) &+ X[i], s); (a,b,c,d) = (d,a,b,c)
        }
        // Round 2 (constant = 0x5A827999)
        for (i, s): (Int, UInt32) in zip([0,4,8,12,1,5,9,13,2,6,10,14,3,7,11,15],
                                          [3,5,9,13,3,5,9,13,3,5,9,13,3,5,9,13]) {
            a = rol(a &+ G(b,c,d) &+ X[i] &+ 0x5A827999, s); (a,b,c,d) = (d,a,b,c)
        }
        // Round 3 (constant = 0x6ED9EBA1)
        for (i, s): (Int, UInt32) in zip([0,8,4,12,2,10,6,14,1,9,5,13,3,11,7,15],
                                          [3,9,11,15,3,9,11,15,3,9,11,15,3,9,11,15]) {
            a = rol(a &+ H(b,c,d) &+ X[i] &+ 0x6ED9EBA1, s); (a,b,c,d) = (d,a,b,c)
        }

        A = A &+ a; B = B &+ b; C = C &+ c; D = D &+ d
    }

    var result = [UInt8](repeating: 0, count: 16)
    for (i, v) in [A,B,C,D].enumerated() {
        result[i*4+0] = UInt8(v & 0xFF)
        result[i*4+1] = UInt8((v>>8) & 0xFF)
        result[i*4+2] = UInt8((v>>16) & 0xFF)
        result[i*4+3] = UInt8((v>>24) & 0xFF)
    }
    return result
}

// MARK: - MD5 (RFC 1321) — needed for HMAC-MD5

/// Pure Swift MD5 hash using explicit if/else (avoids Swift switch-range-pattern issue).
func md5(_ input: [UInt8]) -> [UInt8] {
    // Per-round left-rotation amounts
    let s: [UInt32] = [
        7,12,17,22, 7,12,17,22, 7,12,17,22, 7,12,17,22,
        5, 9,14,20, 5, 9,14,20, 5, 9,14,20, 5, 9,14,20,
        4,11,16,23, 4,11,16,23, 4,11,16,23, 4,11,16,23,
        6,10,15,21, 6,10,15,21, 6,10,15,21, 6,10,15,21,
    ]
    let K: [UInt32] = [
        0xd76aa478,0xe8c7b756,0x242070db,0xc1bdceee,0xf57c0faf,0x4787c62a,0xa8304613,0xfd469501,
        0x698098d8,0x8b44f7af,0xffff5bb1,0x895cd7be,0x6b901122,0xfd987193,0xa679438e,0x49b40821,
        0xf61e2562,0xc040b340,0x265e5a51,0xe9b6c7aa,0xd62f105d,0x02441453,0xd8a1e681,0xe7d3fbc8,
        0x21e1cde6,0xc33707d6,0xf4d50d87,0x455a14ed,0xa9e3e905,0xfcefa3f8,0x676f02d9,0x8d2a4c8a,
        0xfffa3942,0x8771f681,0x6d9d6122,0xfde5380c,0xa4beea44,0x4bdecfa9,0xf6bb4b60,0xbebfbc70,
        0x289b7ec6,0xeaa127fa,0xd4ef3085,0x04881d05,0xd9d4d039,0xe6db99e5,0x1fa27cf8,0xc4ac5665,
        0xf4292244,0x432aff97,0xab9423a7,0xfc93a039,0x655b59c3,0x8f0ccc92,0xffeff47d,0x85845dd1,
        0x6fa87e4f,0xfe2ce6e0,0xa3014314,0x4e0811a1,0xf7537e82,0xbd3af235,0x2ad7d2bb,0xeb86d391,
    ]

    var a0: UInt32 = 0x67452301
    var b0: UInt32 = 0xEFCDAB89
    var c0: UInt32 = 0x98BADCFE
    var d0: UInt32 = 0x10325476

    // Pad message
    var data = input
    let originalLen = data.count
    data.append(0x80)
    while data.count % 64 != 56 { data.append(0x00) }
    let bitLen = UInt64(originalLen) * 8
    for i in 0..<8 { data.append(UInt8((bitLen >> (i*8)) & 0xFF)) }

    func rol(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }

    for blk in stride(from: 0, to: data.count, by: 64) {
        var M = [UInt32](repeating: 0, count: 16)
        for j in 0..<16 {
            let o = blk + j * 4
            M[j] = UInt32(data[o]) | UInt32(data[o+1])<<8 | UInt32(data[o+2])<<16 | UInt32(data[o+3])<<24
        }
        var A = a0, B = b0, C = c0, D = d0

        // Unrolled into explicit if/else to avoid Swift switch-range-pattern edge cases
        for i in 0..<64 {
            let f: UInt32
            let g: Int
            if i < 16 {
                f = (B & C) | (~B & D)
                g = i
            } else if i < 32 {
                f = (D & B) | (~D & C)
                g = (5 * i + 1) % 16
            } else if i < 48 {
                f = B ^ C ^ D
                g = (3 * i + 5) % 16
            } else {
                f = C ^ (B | ~D)
                g = (7 * i) % 16
            }
            let temp = D
            D = C
            C = B
            B = B &+ rol(f &+ A &+ K[i] &+ M[g], s[i])
            A = temp
        }
        a0 = a0 &+ A; b0 = b0 &+ B; c0 = c0 &+ C; d0 = d0 &+ D
    }

    var result = [UInt8](repeating: 0, count: 16)
    for (i, v) in [a0, b0, c0, d0].enumerated() {
        result[i*4+0] = UInt8(v & 0xFF)
        result[i*4+1] = UInt8((v>>8) & 0xFF)
        result[i*4+2] = UInt8((v>>16) & 0xFF)
        result[i*4+3] = UInt8((v>>24) & 0xFF)
    }
    return result
}

// MARK: - HMAC-MD5

/// HMAC-MD5 per RFC 2104, built on the pure Swift MD5 above.
func hmacMD5(key: [UInt8], data: [UInt8]) -> [UInt8] {
    let blockSize = 64
    var k = key.count > blockSize ? md5(key) : key
    k += [UInt8](repeating: 0, count: max(0, blockSize - k.count))
    return md5(k.map { $0 ^ 0x5C } + md5(k.map { $0 ^ 0x36 } + data))
}

// MARK: - NTLM Errors

enum NTLMError: Error {
    case invalidChallenge
}
