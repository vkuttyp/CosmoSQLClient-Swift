import XCTest
@testable import CosmoMSSQL

// ── NTLM Unit Tests ───────────────────────────────────────────────────────────
//
// Verifies the pure-Swift NTLMv2 implementation using official test vectors
// from MS-NLMP specification §4.2 (https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-nlmp)
//
// Integration test setup options:
//   • Windows SQL Server with Windows Authentication enabled (local or domain user)
//   • Azure SQL Managed Instance with AD
//   • Linux SQL Server joined to Active Directory via SSSD/PAM
//
// Example integration test invocation (Windows SQL Server):
//   MSSQL_NTLM_HOST=winserver MSSQL_NTLM_USER=testuser MSSQL_NTLM_PASS=secret
//   MSSQL_NTLM_DOMAIN=CONTOSO swift test --filter NTLMTests.testNTLMConnection

final class NTLMTests: XCTestCase, @unchecked Sendable {

    // MARK: - MD4 tests (RFC 1320 §A.5 test vectors)

    func testMD4EmptyString() {
        let result = md4([])
        XCTAssertEqual(result.hex, "31d6cfe0d16ae931b73c59d7e0c089c0")
    }

    func testMD4Message() {
        // MD4("a") = bde52cb31de33e46245e05fbdbd6fb24
        let result = md4([0x61])
        XCTAssertEqual(result.hex, "bde52cb31de33e46245e05fbdbd6fb24")
    }

    func testMD4ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789() {
        let input = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
        let result = md4(input)
        XCTAssertEqual(result.hex, "043f8582f241db351ce627e153e7f0e4")
    }

    // MARK: - MD5 tests (RFC 1321 §A.5 test vectors)

    func testMD5EmptyString() {
        let result = md5([])
        XCTAssertEqual(result.hex, "d41d8cd98f00b204e9800998ecf8427e")
    }

    func testMD5ABCString() {
        let result = md5(Array("abc".utf8))
        XCTAssertEqual(result.hex, "900150983cd24fb0d6963f7d28e17f72")
    }

    func testMD5LongMessage() {
        let result = md5(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8))
        XCTAssertEqual(result.hex, "d174ab98d277d9f5a5611c2c9f419d9f")
    }

    // MARK: - HMAC-MD5 tests (RFC 2202 §2 test vectors)

    func testHMACMD5Vector1() {
        // Key = 0x0b × 16, Data = "Hi There"
        let key  = [UInt8](repeating: 0x0b, count: 16)
        let data = Array("Hi There".utf8)
        let result = hmacMD5(key: key, data: data)
        XCTAssertEqual(result.hex, "9294727a3638bb1c13f48ef8158bfc9d")
    }

    func testHMACMD5Vector2() {
        // Key = "Jefe", Data = "what do ya want for nothing?"
        let key  = Array("Jefe".utf8)
        let data = Array("what do ya want for nothing?".utf8)
        let result = hmacMD5(key: key, data: data)
        XCTAssertEqual(result.hex, "750c783e6ab0b503eaa86e310a5db738")
    }

    // MARK: - NTLMv2 test vectors (MS-NLMP §4.2)
    //
    // These are the official Microsoft test vectors for NTLMv2.
    // Input values from MS-NLMP §4.2.4 (NTLMv2 Authentication):
    //   User    = "User"
    //   UserDom = "Domain"
    //   Passwd  = "Password"
    //   ServerChallenge = 0102030405060708

    private let ntlmUser      = "User"
    private let ntlmDomain    = "Domain"
    private let ntlmPassword  = "Password"
    private let serverChallenge: [UInt8] = [0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08]

    func testNTHashMD4() {
        // NT hash = MD4(UTF-16LE("Password"))
        // Expected: a4f49c406510bdcab6824ee7c30fd852
        let passwordUTF16 = Array("Password".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let ntHash = md4(passwordUTF16)
        XCTAssertEqual(ntHash.hex, "a4f49c406510bdcab6824ee7c30fd852")
    }

    func testNTLMv2Hash() {
        // NTLMv2Hash = HMAC-MD5(NT_HASH, UTF-16LE(UPPER(user) + domain))
        // Per MS-NLMP spec: only username is uppercased, domain keeps original case.
        // Expected from Python/Impacket reference: 0c868a403bfd7a93a3001ef22ef02e3f
        let passwordUTF16 = Array(ntlmPassword.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let ntHash = md4(passwordUTF16)
        let identity = (ntlmUser.uppercased() + ntlmDomain)
        let identityUTF16 = Array(identity.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        let ntlmv2Hash = hmacMD5(key: ntHash, data: identityUTF16)
        XCTAssertEqual(ntlmv2Hash.hex, "0c868a403bfd7a93a3001ef22ef02e3f")
    }

    // MARK: - NTLM message structure tests

    func testNegotiateMessageStructure() {
        let negotiate = NTLMAuth.buildNegotiate()
        // Must start with NTLMSSP\0
        XCTAssertEqual(Array(negotiate.prefix(8)),
                       [0x4E,0x54,0x4C,0x4D,0x53,0x53,0x50,0x00])
        // MessageType must be 1 (little-endian)
        XCTAssertEqual(negotiate[8], 0x01)
        XCTAssertEqual(negotiate[9], 0x00)
        XCTAssertEqual(negotiate[10], 0x00)
        XCTAssertEqual(negotiate[11], 0x00)
        // Must be at least 32 bytes
        XCTAssert(negotiate.count >= 32)
    }

    func testParseAndBuildChallenge() throws {
        // Construct a minimal synthetic NTLM_CHALLENGE to verify parser
        var challenge = [UInt8](repeating: 0, count: 56)
        // Signature
        let sig: [UInt8] = [0x4E,0x54,0x4C,0x4D,0x53,0x53,0x50,0x00]
        challenge[0..<8] = sig[...]
        // MessageType = 2
        challenge[8] = 0x02
        // NegotiateFlags at 20
        challenge[20] = 0x35; challenge[21] = 0x82; challenge[22] = 0x08; challenge[23] = 0x62
        // ServerChallenge at 24
        challenge[24..<32] = serverChallenge[...]
        // TargetInfoFields at 40: len=0, maxLen=0, offset=56
        challenge[40] = 0x00; challenge[41] = 0x00
        challenge[42] = 0x00; challenge[43] = 0x00
        challenge[44] = 0x38; challenge[45] = 0x00; challenge[46] = 0x00; challenge[47] = 0x00

        let parsed = try NTLMAuth.parseChallenge(challenge)
        XCTAssertEqual(parsed.serverChallenge, serverChallenge)
        XCTAssertTrue(parsed.targetInfo.isEmpty)
    }

    func testBuildAuthenticateProducesValidStructure() throws {
        // Build a synthetic challenge with known server challenge
        var challengeBytes = [UInt8](repeating: 0, count: 56)
        let sig: [UInt8] = [0x4E,0x54,0x4C,0x4D,0x53,0x53,0x50,0x00]
        challengeBytes[0..<8] = sig[...]
        challengeBytes[8] = 0x02   // type 2
        challengeBytes[20] = 0x35; challengeBytes[21] = 0x82
        challengeBytes[22] = 0x08; challengeBytes[23] = 0x62
        challengeBytes[24..<32] = serverChallenge[...]
        // TargetInfoFields: empty, offset 56
        challengeBytes[44] = 0x38

        let auth = try NTLMAuth.buildAuthenticate(
            challenge:   challengeBytes,
            username:    ntlmUser,
            password:    ntlmPassword,
            domain:      ntlmDomain,
            workstation: "WORKSTATION"
        )

        // Must start with NTLMSSP\0
        XCTAssertEqual(Array(auth.prefix(8)),
                       [0x4E,0x54,0x4C,0x4D,0x53,0x53,0x50,0x00])
        // MessageType must be 3
        XCTAssertEqual(auth[8], 0x03)
        XCTAssertEqual(auth[9], 0x00)
        XCTAssertEqual(auth[10], 0x00)
        XCTAssertEqual(auth[11], 0x00)
        // Must be at least 72 bytes (header) + response data
        XCTAssert(auth.count > 72)
    }

    // MARK: - Placeholder conversion test

    func testConvertPlaceholders() {
        let sql = "SELECT * FROM t WHERE a = ? AND b = ? AND c = ?"
        let converted = MSSQLConnection.convertPlaceholders(sql)
        XCTAssertEqual(converted, "SELECT * FROM t WHERE a = @p1 AND b = @p2 AND c = @p3")
    }

    func testConvertPlaceholdersNoChange() {
        let sql = "SELECT * FROM t WHERE a = @p1"
        let converted = MSSQLConnection.convertPlaceholders(sql)
        XCTAssertEqual(converted, sql)
    }

    // MARK: - Integration test (requires Windows SQL Server with Windows Auth)

    func testNTLMConnection() throws {
        // Run with:
        //   MSSQL_NTLM_HOST=winserver MSSQL_NTLM_DB=mydb
        //   MSSQL_NTLM_USER=testuser MSSQL_NTLM_PASS=secret MSSQL_NTLM_DOMAIN=CONTOSO
        //   swift test --filter NTLMTests.testNTLMConnection
        guard
            let host   = ProcessInfo.processInfo.environment["MSSQL_NTLM_HOST"],
            let db     = ProcessInfo.processInfo.environment["MSSQL_NTLM_DB"],
            let domain = ProcessInfo.processInfo.environment["MSSQL_NTLM_DOMAIN"]
        else {
            throw XCTSkip("Set MSSQL_NTLM_HOST, MSSQL_NTLM_DB, MSSQL_NTLM_DOMAIN to run this test")
        }
        let user = ProcessInfo.processInfo.environment["MSSQL_NTLM_USER"] ?? ""
        let pass = ProcessInfo.processInfo.environment["MSSQL_NTLM_PASS"] ?? ""

        runAsync {
            let config = MSSQLConnection.Configuration(
                host: host, database: db,
                domain: domain,
                username: user,
                password: pass
            )
            let conn = try await MSSQLConnection.connect(configuration: config)
            do {
                let rows = try await conn.query("SELECT SYSTEM_USER AS u, DB_NAME() AS db", [])
                try await conn.close()
                XCTAssertFalse(rows.isEmpty)
                print("NTLM login succeeded as: \(rows[0]["u"].asString() ?? "?")")
            } catch {
                try? await conn.close()
                throw error
            }
        }
    }
}

// MARK: - Helpers

private extension Array where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
