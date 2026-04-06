//
//  NetworkManager.swift
//  easyspot
//
//  Created by Joshua Mendoza on 4/5/26.
//


import Foundation
import CoreWLAN
import Combine
import CoreLocation
import SwiftUI

/// Manages the Wi-Fi connection state to passively monitor if the Mac is connected to the target Android Hotspot.
/// This acts as the "Passive Radar" fallback to avoid keeping a CoreBluetooth connection alive, saving Mac battery.
class NetworkManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var currentSSID: String = ""
    @Published var isConnectedToHotspot: Bool = false
    @Published var availableNetworks: [String] = []
    
    // Persists the target network name across app restarts
    @AppStorage("hotspotSSID") var targetSSID: String = ""
    
    private var client: CWWiFiClient
    private var timer: AnyCancellable?
    private var locationManager = CLLocationManager()
    
    override init() {
        self.client = CWWiFiClient.shared()
        super.init()
        
        // Triggers the required macOS Location Services prompt to allow SSID reading
        locationManager.delegate = self
        locationManager.requestAlwaysAuthorization()
        
        // Immediate check on initialization to sync UI state
        checkWiFiState()
        startMonitoring()
    }
    
    /// Passively checks the current Wi-Fi interface every 2 seconds.
    /// This does NOT trigger a hardware network scan, resulting in near-zero battery drain.
    func startMonitoring() {
        timer = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkWiFiState()
            }
    }
    
    func checkWiFiState() {
        guard let interface = client.interface() else { return }
        
        let newSSID = interface.ssid() ?? ""
        if newSSID != currentSSID {
            currentSSID = newSSID
        }
        
        let isConnected = (currentSSID == targetSSID && !targetSSID.isEmpty)
        if isConnectedToHotspot != isConnected {
            isConnectedToHotspot = isConnected
        }
    }
    
    /// Actively powers the Wi-Fi antenna to scan the room.
    /// Used only when explicitly requested or during the 60-second connection handshake.
    func scanForNetworks() {
        guard let interface = client.interface() else { return }
        do {
            let networks = try interface.scanForNetworks(withName: nil)
            let ssids = networks.compactMap { $0.ssid }.filter { !$0.isEmpty }
            
            DispatchQueue.main.async {
                self.availableNetworks = Array(Set(ssids)).sorted()
            }
        } catch {
            print("Network scan failed: \(error.localizedDescription)")
        }
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways {
            scanForNetworks()
        }
    }
}
