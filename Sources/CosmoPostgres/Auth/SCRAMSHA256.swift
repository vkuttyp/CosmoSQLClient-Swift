// SCRAMSHA256.swift
//
// SCRAM-SHA-256 authentication for PostgreSQL wire protocol.
// Implements RFC 5802 / RFC 7677 SCRAM-SHA-256 (without channel binding).
//
// Flow:
//   Client → SASLInitialResponse  (contains client-first-message)
//   Server → AuthSASLContinue      (contains server-first-message)
//   Client → SASLResponse          (contains client-final-message)
//   Server → AuthSASLFinal         (contains server-final-message with v=...)

import Foundation
import Crypto

// MARK: - SaltedPassword cache
//
// PostgreSQL stores a fixed salt per user in pg_authid (it only changes when the user
// resets their password). Every connection by the same user sees the same server-first
// salt string.  Caching SaltedPassword = Hi(password, salt, iterations) eliminates
// 4096 HMAC-SHA256 rounds on every cold connect after the first one.
//
// Cache key: "<iterations>:<saltB64>:<password>" → [UInt8] SaltedPassword
// Invalidation: automatic — password change produces a new salt from the server.

private let _scramCacheLock = NSLock()
private nonisolated(unsafe) var _scramCache: [String: [UInt8]] = [:]

// MARK: - SCRAM-SHA-256 authenticator

struct SCRAMSHA256 {

    // Call this once after receiving authRequestSASL.
    // Returns the initial client message payload (to send as SASLInitialResponse).
    static func clientFirstMessage(
        username: String,
        nonce: String
    ) -> (payload: String, clientFirstMessageBare: String) {
        // gs2-header: no channel binding ("n,,")
        let clientFirstMessageBare = "n=\(username),r=\(nonce)"
        let payload = "n,," + clientFirstMessageBare
        return (payload, clientFirstMessageBare)
    }

    // Call this after receiving authSASLContinue.
    // Returns (clientFinalMessage, expectedServerSignature).
    static func clientFinalMessage(
        password: String,
        clientFirstMessageBare: String,
        serverFirstMessage: String,
        nonce: String
    ) throws -> (clientFinal: String, serverSignature: [UInt8]) {

        // Parse server-first-message: r=<nonce>,s=<salt>,i=<iterations>
        let serverParts = parse(serverFirstMessage)
        guard let combinedNonce = serverParts["r"],
              let saltB64        = serverParts["s"],
              let iterStr        = serverParts["i"],
              let iterations     = Int(iterStr)
        else {
            throw SCRAMError.invalidServerMessage
        }
        guard combinedNonce.hasPrefix(nonce) else {
            throw SCRAMError.nonceMismatch
        }
        guard let saltBytes = Data(base64Encoded: saltB64) else {
            throw SCRAMError.invalidServerMessage
        }

        // SaltedPassword = Hi(Normalize(password), salt, i)
        // Cached: same password+salt+iterations always produces the same result.
        let saltedPassword = try cachedHi(password: password,
                                           saltB64: saltB64,
                                           salt: Array(saltBytes),
                                           iterations: iterations)

        // Reuse a single SymmetricKey for all derivations from SaltedPassword
        let spKey = SymmetricKey(data: saltedPassword)

        // ClientKey = HMAC(SaltedPassword, "Client Key")
        let clientKey = Array(HMAC<SHA256>.authenticationCode(
            for: [UInt8]("Client Key".utf8), using: spKey))

        // StoredKey = H(ClientKey)
        let storedKey = Array(SHA256.hash(data: clientKey))

        // AuthMessage = client-first-message-bare + "," + server-first-message + "," + client-final-message-without-proof
        let channelBinding = "c=" + Data("n,,".utf8).base64EncodedString()
        let clientFinalWithoutProof = "\(channelBinding),r=\(combinedNonce)"
        let authMessage = "\(clientFirstMessageBare),\(serverFirstMessage),\(clientFinalWithoutProof)"
        let authBytes = [UInt8](authMessage.utf8)

        // ClientSignature = HMAC(StoredKey, AuthMessage)
        let storedKey_ = SymmetricKey(data: storedKey)
        let clientSignature = Array(HMAC<SHA256>.authenticationCode(for: authBytes, using: storedKey_))

        // ClientProof = ClientKey XOR ClientSignature  (in-place)
        var clientProof = clientKey
        for i in 0..<clientProof.count { clientProof[i] ^= clientSignature[i] }

        // ServerKey = HMAC(SaltedPassword, "Server Key")
        let serverKey = Array(HMAC<SHA256>.authenticationCode(
            for: [UInt8]("Server Key".utf8), using: spKey))

        // ServerSignature = HMAC(ServerKey, AuthMessage)
        let serverKey_ = SymmetricKey(data: serverKey)
        let serverSignature = Array(HMAC<SHA256>.authenticationCode(for: authBytes, using: serverKey_))

        let clientFinal = "\(clientFinalWithoutProof),p=\(Data(clientProof).base64EncodedString())"
        return (clientFinal, serverSignature)
    }

    // Verify server-final-message: must contain "v=<base64 server signature>"
    static func verifyServerFinal(
        _ serverFinal: String,
        expectedServerSignature: [UInt8]
    ) throws {
        let parts = parse(serverFinal)
        guard let vB64 = parts["v"],
              let sigBytes = Data(base64Encoded: vB64)
        else {
            throw SCRAMError.invalidServerMessage
        }
        guard Array(sigBytes) == expectedServerSignature else {
            throw SCRAMError.serverSignatureMismatch
        }
    }

    // MARK: - Crypto helpers

    // PBKDF2-HMAC-SHA256: Hi(str, salt, i) with SaltedPassword caching.
    // Cache hit: O(1) dictionary lookup — skips 4096 HMAC-SHA256 rounds.
    private static func cachedHi(password: String, saltB64: String,
                                  salt: [UInt8], iterations: Int) throws -> [UInt8] {
        let cacheKey = "\(iterations):\(saltB64):\(password)"
        _scramCacheLock.lock()
        if let cached = _scramCache[cacheKey] {
            _scramCacheLock.unlock()
            return cached
        }
        _scramCacheLock.unlock()

        let result = hi(password: password, salt: salt, iterations: iterations)

        _scramCacheLock.lock()
        _scramCache[cacheKey] = result
        _scramCacheLock.unlock()
        return result
    }

    // Pure PBKDF2-HMAC-SHA256 (no cache). Creates SymmetricKey once; XORs in-place.
    private static func hi(password: String, salt: [UInt8], iterations: Int) -> [UInt8] {
        let passwordKey = SymmetricKey(data: Data(password.utf8))   // created once

        // U1 = HMAC(password, salt + INT(1))
        var saltPlusOne = salt
        saltPlusOne.append(contentsOf: [0, 0, 0, 1])
        var u = Array(HMAC<SHA256>.authenticationCode(for: saltPlusOne, using: passwordKey))
        var result = u

        for _ in 1..<iterations {
            u = Array(HMAC<SHA256>.authenticationCode(for: u, using: passwordKey))
            // In-place XOR — avoids allocating a new [UInt8] per iteration
            for i in 0..<result.count { result[i] ^= u[i] }
        }
        return result
    }

    // HMAC-SHA-256 (used externally)
    private static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        let symmetricKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Array(mac)
    }

    // Parse "key=value,key=value,..." — values may contain '=' in base64
    private static func parse(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in s.split(separator: ",", omittingEmptySubsequences: false) {
            let idx = pair.firstIndex(of: "=") ?? pair.endIndex
            let key = String(pair[pair.startIndex..<idx])
            let val = idx < pair.endIndex
                ? String(pair[pair.index(after: idx)...])
                : ""
            result[key] = val
        }
        return result
    }

    static func generateNonce(length: Int = 24) -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<length).map { _ in chars.randomElement()! })
    }
}

enum SCRAMError: Error {
    case invalidServerMessage
    case nonceMismatch
    case serverSignatureMismatch
}
