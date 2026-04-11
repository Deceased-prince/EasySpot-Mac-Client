//
//  KeychainHelper.swift
//  easyspot
//
//  Created by Joshua Mendoza on 4/8/26.
//

import Foundation
import Security

// MARK: - KeychainHelper

/// A pure static utility namespace for reading and writing passwords to the macOS Keychain.
///
/// ## Why the Keychain?
/// The Wi-Fi hotspot password is sensitive — storing it in `UserDefaults` would leave it
/// as plain text in the app's `.plist` file. The Keychain encrypts the value at rest
/// and ties it to the app's code signature, so only EasySpot can read it back.
///
/// ## Why an `enum` instead of a `class`?
/// Declaring this as a caseless `enum` (rather than a `class` or `struct`) signals that it
/// is a pure utility namespace and cannot be instantiated. This prevents accidental object
/// creation and misuse across the codebase.
///
/// ## Keychain Item Identity
/// A `kSecClassGenericPassword` item is uniquely identified by the combination of
/// `kSecAttrService` **and** `kSecAttrAccount`. Using only `kSecAttrService` risks
/// a duplicate-item error (`errSecDuplicateItem`) on macOS versions that apply strict
/// primary-key validation. The account is fixed to `"HotspotUser"` since EasySpot only
/// ever stores a single password per bundle.
enum KeychainHelper {

    // MARK: - Save

    /// Saves a password to the Keychain for the given service identifier.
    ///
    /// Uses a **delete-then-add** strategy to handle both new entries and updates cleanly.
    /// The Keychain does not support an atomic "upsert", so we must delete any existing item
    /// before adding the new one. An `errSecItemNotFound` result on the delete is treated
    /// as success — it simply means there was no prior password to remove.
    ///
    /// - Parameters:
    ///   - password: The plaintext password string to store.
    ///   - service: The service identifier (typically the app's bundle ID + a suffix).
    /// - Returns: `.success(service)` on success, or `.failure(error)` with a descriptive error.
    static func savePassword(_ password: String, for service: String) -> Result<String, Error> {
        // Convert the password string to raw bytes for Keychain storage.
        guard let data = password.data(using: .utf8) else {
            return .failure(NSError(
                domain: "KeychainHelper",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid password encoding"]
            ))
        }

        // The query dictionary doubles as both the search predicate (for delete) and
        // the item attributes (for add), since both operations target the same item.
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "HotspotUser",   // Fixed account name — see header comment.
            kSecAttrService as String: service,
            kSecValueData   as String: data
        ]

        // Step 1: Delete any existing entry — SecItemAdd will fail with errSecDuplicateItem
        // if an item with the same service + account already exists.
        let deleteStatus = SecItemDelete(query as CFDictionary)
        if deleteStatus != errSecItemNotFound && deleteStatus != noErr {
            return .failure(NSError(
                domain: "KeychainHelper",
                code: Int(deleteStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to delete old password (OSStatus \(deleteStatus))"]
            ))
        }

        // Step 2: Add the new item.
        var newResult: CFTypeRef?
        let addStatus = SecItemAdd(query as CFDictionary, &newResult)
        if addStatus != noErr {
            return .failure(NSError(
                domain: "KeychainHelper",
                code: Int(addStatus),
                userInfo: [NSLocalizedDescriptionKey: "Failed to save to Keychain (OSStatus \(addStatus))"]
            ))
        }

        return .success(service)
    }

    // MARK: - Load

    /// Loads a password from the Keychain for the given service identifier.
    ///
    /// - Parameter service: The service identifier used when the password was saved.
    /// - Returns: The stored password string, or `nil` if no matching item exists or
    ///   if the stored bytes cannot be decoded as UTF-8.
    static func loadPassword(for service: String) -> String? {
        let query: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "HotspotUser",   // Must match the account used in savePassword.
            kSecAttrService as String: service,
            kSecReturnData  as String: true,             // Ask the Keychain to return the raw data blob.
            kSecMatchLimit  as String: kSecMatchLimitOne // Return at most one result.
        ]

        var result: CFTypeRef?
        SecItemCopyMatching(query as CFDictionary, &result)

        // Cast the opaque CFTypeRef result to Data, then decode as UTF-8.
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
