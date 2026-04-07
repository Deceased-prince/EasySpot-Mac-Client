//
//  easyspotApp.swift
//  easyspot
//
//  Created by Joshua Mendoza on 4/5/26.
//

import SwiftUI
import ServiceManagement
import AppKit // <-- We need this for the native macOS popup window

@main
struct EasySpotTriggerApp: App {
    @StateObject var bleManager = BLEManager()
    @StateObject var networkManager = NetworkManager()
    
    // Hidden secure storage
    @AppStorage("hotspotPassword") private var hotspotPassword = ""
    @AppStorage("isManualSSID") private var isManualSSID = false
    
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var isTransitioning = false

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
                    Text(hotspotPassword.isEmpty ? "Set Hotspot Password..." : "Update Saved Password...")
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
    
    
    
    
    
    // MARK: - Native AppKit ssid pop up
        
    func promptForSSID() {
        NSApp.activate(ignoringOtherApps: true)
            
        let alert = NSAlert()
        alert.messageText = "Manual Hotspot Configuration"
        alert.informativeText = "Enter the exact name (SSID) of your Android hotspot."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
            
        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        inputField.placeholderString = "e.g. Pixel_7_Pro"
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
        if response == .alertFirstButtonReturn {
            hotspotPassword = passwordField.stringValue
        }
    }
    
    /// Handles the hybrid Bluetooth/Wi-Fi handshake
    func toggleHotspotFlow() {
        if networkManager.isConnectedToHotspot {
            bleManager.triggerHotspot(turnOn: false)
        } else {
            
            // SMART LOGIC: Check if we have a password before triggering!
            if hotspotPassword.isEmpty {
                promptForPassword()
                            
                // If they hit cancel on the popup, abort the connection attempt
                if hotspotPassword.isEmpty {
                    print("Connection aborted: No password provided.")
                    return
                }
            }
            
            // Fire the BLE trigger, then drop the connection to save battery
            bleManager.triggerHotspot(turnOn: true)
            isTransitioning = true
            
            // Aggressive 60-second Wi-Fi scan to bypass macOS's lazy auto-join delay
            var attempts = 0
            Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { timer in
                attempts += 1
                
                // Pass the saved password into our brute-force connection command
                networkManager.forceConnect(to: networkManager.targetSSID, password: hotspotPassword)
                                
                if networkManager.isConnectedToHotspot {
                    isTransitioning = false
                    timer.invalidate()
                } else if attempts >= 12 {
                    isTransitioning = false
                    timer.invalidate()
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
