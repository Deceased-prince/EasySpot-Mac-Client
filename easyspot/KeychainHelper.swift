//
//  KeychainHelper.swift
//  easyspot
//
//  Created by Joshua Mendoza on 4/8/26.
//


import Foundation
import Security

/// Securely stores and retrieves passwords using macOS's native encrypted Keychain.
class KeychainHelper {
    
    static func savePassword(_ password: String, for service: String) {
        guard let data = password.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data
        ]
        
        // Always delete any old password before saving a new one to prevent duplicates
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
    
    static func loadPassword(for service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: CFTypeRef?
        SecItemCopyMatching(query as CFDictionary, &result)
        
        if let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}
