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
        let saltedPassword = try hi(password: password,
                                    salt: Array(saltBytes),
                                    iterations: iterations)

        // ClientKey = HMAC(SaltedPassword, "Client Key")
        let clientKey = hmacSHA256(key: saltedPassword, data: [UInt8]("Client Key".utf8))

        // StoredKey = H(ClientKey)
        let storedKey = Array(SHA256.hash(data: clientKey))

        // AuthMessage = client-first-message-bare + "," + server-first-message + "," + client-final-message-without-proof
        let channelBinding = "c=" + Data("n,,".utf8).base64EncodedString()
        let clientFinalWithoutProof = "\(channelBinding),r=\(combinedNonce)"
        let authMessage = "\(clientFirstMessageBare),\(serverFirstMessage),\(clientFinalWithoutProof)"

        // ClientSignature = HMAC(StoredKey, AuthMessage)
        let clientSignature = hmacSHA256(key: storedKey, data: [UInt8](authMessage.utf8))

        // ClientProof = ClientKey XOR ClientSignature
        let clientProof = zip(clientKey, clientSignature).map { $0 ^ $1 }

        // ServerKey = HMAC(SaltedPassword, "Server Key")
        let serverKey = hmacSHA256(key: saltedPassword, data: [UInt8]("Server Key".utf8))

        // ServerSignature = HMAC(ServerKey, AuthMessage)
        let serverSignature = hmacSHA256(key: serverKey, data: [UInt8](authMessage.utf8))

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

    // PBKDF2-HMAC-SHA256: Hi(str, salt, i)
    private static func hi(password: String, salt: [UInt8], iterations: Int) throws -> [UInt8] {
        let passwordBytes = [UInt8](password.utf8)

        // U1 = HMAC(password, salt + INT(1))
        var saltPlusOne = salt
        saltPlusOne.append(contentsOf: [0, 0, 0, 1])
        var u = hmacSHA256(key: passwordBytes, data: saltPlusOne)
        var result = u

        for _ in 1..<iterations {
            u = hmacSHA256(key: passwordBytes, data: u)
            result = zip(result, u).map { $0 ^ $1 }
        }
        return result
    }

    // HMAC-SHA-256
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
