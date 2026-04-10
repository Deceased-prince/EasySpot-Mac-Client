//
//  easyspotApp.swift
//  easyspot
//
//  Created by Joshua Mendoza on 4/5/26.
//

import SwiftUI
import ServiceManagement
import AppKit
import Security
import Foundation

@main
struct EasySpotTriggerApp: App {
    @StateObject var bleManager = BLEManager()
    @StateObject var networkManager = NetworkManager()
    
    // NEW: We only use AppStorage for a harmless True/False flag so the UI knows what to display without touching the Keychain on launch.
    @AppStorage("isPasswordSaved") private var isPasswordSaved = false
    @AppStorage("isManualSSID") private var isManualSSID = false
    
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isTransitioning = false

    // NEW: Safely store the timer so we can destroy it if the user clicks rapidly
    @State private var hotspotConnectionTimer: Timer?
    
    // Dynamic icon reflects the true Wi-Fi connection state
    var menuBarIcon: String {
        if networkManager.isConnectedToHotspot {
            return "personalhotspot"
        } else if isTransitioning {
            return "antenna.radiowaves.left.and.right.circle"
        } else {
            return "antenna.radiowaves.left.and.right"
        }
    }

    var body: some Scene {
        MenuBarExtra("EasySpot", systemImage: menuBarIcon) {
            
            VStack {
                // Main Trigger Button
                Button(action: {
                    toggleHotspotFlow()
                }) {
                    if isTransitioning {
                        Text("Connecting...")
                    } else if networkManager.isConnectedToHotspot {
                        Text("Turn Hotspot OFF")
                    } else {
                        Text("Turn Hotspot ON")
                    }
                }
                .disabled(isTransitioning || networkManager.targetSSID.isEmpty)
                
                Divider()
                
                // --- THE DYNAMIC UI ---
                if isManualSSID {
                    // Manual Mode View
                    Text("Target: \(networkManager.targetSSID)")
                        .font(.caption)
                        .foregroundColor(.gray)
                                    
                    Button("Switch back to Auto-Scan") {
                        isManualSSID = false
                        networkManager.targetSSID = "" // Clear it so the trigger button disables
                        networkManager.scanForNetworks()
                    }
                } else {
                    // Scanner Mode View
                    if networkManager.availableNetworks.isEmpty {
                        Text("Scanning for active networks...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    } else {
                        Picker("Target Hotspot:", selection: $networkManager.targetSSID) {
                            Text("Select...").tag("")
                            ForEach(networkManager.availableNetworks, id: \.self) { network in
                                Text(network).tag(network)
                            }
                        }
                    }
                                    
                    Button("Refresh Network List") {
                        networkManager.scanForNetworks()
                    }
                                    
                    Button("Enter Network Name Manually...") {
                        promptForSSID()
                    }
                }
                                
                Divider()
                
                // --- THE NEW MENU OPTIONS ---
                Button(action: {
                    promptForPassword()
                }) {
                    Image(systemName: "key")
                    // The UI now reads the harmless boolean flag instead of the Keychain!
                    Text(isPasswordSaved ? "Update Saved Password..." : "Set Hotspot Password...")
                }
                                
                Button(action: {
                    toggleLaunchAtLogin()
                }) {
                    Image(systemName: launchAtLogin ? "checkmark.square" : "square")
                    Text("Launch at Login")
                }
                                
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .onAppear {
                networkManager.checkWiFiState()
            }
        }
    }
    
    // MARK: - Native AppKit SSID Popup
        
    func promptForSSID() {
        NSApp.activate(ignoringOtherApps: true)
            
        let alert = NSAlert()
        alert.messageText = "Manual Hotspot Configuration"
        alert.informativeText = "Enter the exact name (SSID) of your Android hotspot."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
            
        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        inputField.placeholderString = "e.g. Pixel_10_Pro"
        alert.accessoryView = inputField
            
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            let enteredSSID = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !enteredSSID.isEmpty {
                networkManager.targetSSID = enteredSSID
                isManualSSID = true
            }
        }
    }
    
    // MARK: - Native AppKit Password Popup
    
    func promptForPassword() {
        // 1. Force the app to the front so the popup doesn't spawn invisibly behind other windows
        NSApp.activate(ignoringOtherApps: true)
            
        // 2. Build a native macOS alert window
        let alert = NSAlert()
        alert.messageText = "EasySpot Wi-Fi Password"
        alert.informativeText = "Please enter the password for your Android hotspot. This is required to force the Mac to auto-join the network."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
            
        // 3. Create a secure password field (dots instead of text)
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        passwordField.placeholderString = "Hotspot Password"
        alert.accessoryView = passwordField
            
        // 4. Show the window and wait for the user
        let response = alert.runModal()
            
        // 5. If they clicked "Save", store the password
        guard response == .alertFirstButtonReturn else {
            return
        }
        
        let newPassword = passwordField.stringValue
        let keychainService = "\(Bundle.main.bundleIdentifier ?? "com.Unknown.EasySpot").HotspotPassword"
            
        // Save the password and handle Result
        let result = KeychainHelper.savePassword(newPassword, for: keychainService)
            
        switch result {
        case .success(_):
            print("✅ Password successfully saved to Keychain.")
            isPasswordSaved = !newPassword.isEmpty
        case .failure(let error):
            print("❌ Keychain Save Failed: \(error.localizedDescription)")
                    
            // Show an error popup to the user!
            let errorAlert = NSAlert()
            errorAlert.messageText = "Failed to Save Password"
            errorAlert.informativeText = "macOS denied access to the Keychain. Please check your Mac's security settings."
            errorAlert.alertStyle = .critical
            errorAlert.runModal()
        }
    }

    /// Handles the hybrid Bluetooth/Wi-Fi handshake
    func toggleHotspotFlow() {
        if networkManager.isConnectedToHotspot {
            bleManager.triggerHotspot(turnOn: false)
        } else {
                
            // Create the dynamic string ONCE at the top
            let keychainService = "\(Bundle.main.bundleIdentifier ?? "com.Unknown.EasySpot").HotspotPassword"
                
            // Load using the correct dynamic string
            var currentPassword = KeychainHelper.loadPassword(for: keychainService) ?? ""
                
            if currentPassword.isEmpty {
                promptForPassword()
                    
                // Re-check after the popup
                currentPassword = KeychainHelper.loadPassword(for: keychainService) ?? ""
                    
                if currentPassword.isEmpty {
                    print("Connection aborted: No password provided.")
                    return
                }
            }
                
            bleManager.triggerHotspot(turnOn: true)
            isTransitioning = true
                
            hotspotConnectionTimer?.invalidate()
                
            var attempts = 0
                
            // FIXED: We assign the timer to our variable so it can be tracked!
            hotspotConnectionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { timer in
                attempts += 1
                    
                networkManager.forceConnect(to: networkManager.targetSSID, password: currentPassword)
                    
                if networkManager.isConnectedToHotspot {
                    isTransitioning = false
                    timer.invalidate()
                    hotspotConnectionTimer = nil
                } else if attempts >= 12 {
                    isTransitioning = false
                    timer.invalidate()
                    hotspotConnectionTimer = nil
                }
            }
        }
    }
    
    func toggleLaunchAtLogin() {
        let newValue = !launchAtLogin
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = newValue
        } catch {
            print("Failed to update login item: \(error)")
        }
    }
}
