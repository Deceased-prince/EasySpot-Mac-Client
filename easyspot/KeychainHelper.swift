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
    
    static func savePassword(_ password: String, for service: String) -> Result<String, Error> {
        guard let data = password.data(using: .utf8) else {
            return .failure(NSError(domain: "KeychainHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid password encoding"]))
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data
        ]
        
        // Delete existing password
        let deleteError = SecItemDelete(query as CFDictionary)
        if deleteError != errSecItemNotFound && deleteError != noErr {
            return .failure(NSError(domain: "KeychainHelper", code: Int(deleteError), userInfo: [NSLocalizedDescriptionKey: "Failed to delete old password"]))
        }
        
        // Save new password
        let addError = SecItemAdd(query as CFDictionary, nil)
        if addError != noErr {
            return .failure(NSError(domain: "KeychainHelper", code: Int(addError), userInfo: [NSLocalizedDescriptionKey: "Failed to save to keychain"]))
        }
        
        return .success(service)
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
