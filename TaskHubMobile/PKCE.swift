//
//  PKCE.swift
//  TaskHubMobile
//
//  Created by tim on 2/20/26.
//

import Foundation
import CryptoKit

enum PKCE {
    static func generateVerifier(length: Int = 64) -> String {
        precondition((43...128).contains(length))
        var bytes = [UInt8](repeating: 0, count: length)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result != errSecSuccess {
            for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        }
        let data = Data(bytes)
        return base64url(data)
    }

    static func challengeS256(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return base64url(Data(hash))
    }

    private static func base64url(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
             .replacingOccurrences(of: "/", with: "_")
             .replacingOccurrences(of: "=", with: "")
        return s
    }
}
