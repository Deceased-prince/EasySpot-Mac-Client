//
//  easyspotApp.swift
//  easyspot
//
//  Created by Joshua Mendoza on 4/5/26.
//

import SwiftUI
import ServiceManagement

@main
struct EasySpotTriggerApp: App {
    @StateObject var bleManager = BLEManager()
    @StateObject var networkManager = NetworkManager()
    
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
                
                // Network Selection Menu
                if networkManager.availableNetworks.isEmpty {
                    Text("Scanning for networks...")
                        .font(.caption)
                        .foregroundColor(.gray)
                } else {
                    Picker("Target Hotspot:", selection: $networkManager.targetSSID) {
                        Text("Select a network...").tag("")
                        ForEach(networkManager.availableNetworks, id: \.self) { network in
                            Text(network).tag(network)
                        }
                    }
                }
                
                Button("Refresh Network List") {
                    networkManager.scanForNetworks()
                }
                
                Divider()
                
                // System Settings
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
                // Ensure UI is perfectly synced the moment the menu is clicked
                networkManager.checkWiFiState()
            }
        }
    }
    
    /// Handles the hybrid Bluetooth/Wi-Fi handshake
    func toggleHotspotFlow() {
        if networkManager.isConnectedToHotspot {
            bleManager.triggerHotspot(turnOn: false)
        } else {
            // Fire the BLE trigger, then drop the connection to save battery
            bleManager.triggerHotspot(turnOn: true)
            isTransitioning = true
            
            // Aggressive 60-second Wi-Fi scan to bypass macOS's lazy auto-join delay
            var attempts = 0
            Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { timer in
                attempts += 1
                networkManager.scanForNetworks()
                
                if networkManager.isConnectedToHotspot {
                    isTransitioning = false
                    timer.invalidate()
                } else if attempts >= 12 { // 60 seconds max
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
