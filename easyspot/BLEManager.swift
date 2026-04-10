//
//  BLEManager.swift
//  easyspot
//
//  Created by Joshua Mendoza on 4/5/26.
//


import Foundation
import CoreBluetooth
import Combine

enum BLEState {
    case idle
    case scanning
    case connecting
    case success
    case error(String)
}

/// Handles the BLE communication with the EasySpot Android app.
/// Uses an efficient "Sniper" architecture: It only powers up the Bluetooth scan when triggered,
/// connects, sends the command, waits for a delivery receipt, and immediately drops the connection.
class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    @Published var state: BLEState = .idle
    
    // MARK: - Dependencies & State
    private var centralManager: CBCentralManager!
    private var easySpotPeripheral: CBPeripheral?
    private var pendingCommand: UInt8?
    private var scanTimeoutTimer: Timer?
    
    // Grouping constants makes it incredibly easy to update if the Android app changes its signature
    private enum Constants {
        static let serviceUUID = CBUUID(string: "7baad717-1551-45e1-b852-78d20c7211ec")
        static let charUUID = CBUUID(string: "47436878-5308-40f9-9c29-82c2cb87f595")
    }
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Public API
    
    /// Initiates the sequence to turn the hotspot on or off.
    func triggerHotspot(turnOn: Bool) {
        // Prevent concurrent triggers
        if case .scanning = state {
            print("Already scanning. Canceling current scan to restart.")
            stopScanningAndReset()
        } else if case .connecting = state {
            print("Already connecting. Ignoring trigger.")
            return
        }
        
        pendingCommand = turnOn ? 1 : 0
        state = .scanning
        
        if centralManager.state == .poweredOn {
            print("Scanning for EasySpot BLE beacon...")
            startScanWithTimeout()
        } else {
            print("Bluetooth is turned off or unavailable.")
            state = .error("Bluetooth is turned off")
        }
    }
    
    private func startScanWithTimeout() {
        centralManager.scanForPeripherals(withServices: [Constants.serviceUUID], options: nil)
        
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            print("Scan timed out.")
            self.stopScanningAndReset()
            
            // Only update state to error if we hadn't already found it and moved to connecting
            if case .scanning = self.state {
                self.state = .error("Device not found")
            }
        }
    }
    
    private func stopScanningAndReset() {
        centralManager.stopScan()
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
        pendingCommand = nil
        if let peripheral = easySpotPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
            easySpotPeripheral = nil
        }
    }
    
    // MARK: - CoreBluetooth Central Manager Delegate
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn && pendingCommand != nil {
            startScanWithTimeout()
        } else if central.state != .poweredOn {
            print("Bluetooth is not powered on.")
            if pendingCommand != nil {
                state = .error("Bluetooth is not powered on")
            }
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        print("Discovered EasySpot device. Stopping scan.")
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
        centralManager.stopScan()
        
        state = .connecting
        easySpotPeripheral = peripheral
        easySpotPeripheral?.delegate = self
        
        centralManager.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to device. Discovering services...")
        peripheral.discoverServices([Constants.serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        state = .error("Failed to connect to device")
        stopScanningAndReset()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            print("Unexpectedly disconnected: \(error.localizedDescription)")
            
            // Only flag as error if we didn't just succeed
            if case .success = state {
                // Connection dropped normally after our explicit cancel request
            } else {
                state = .error("Disconnected unexpectedly")
            }
        } else {
            // No error, expected disconnect. Restore to idle if we succeeded.
            if case .success = state {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if case .success = self.state {
                        self.state = .idle
                    }
                }
            } else {
                state = .idle
            }
        }
        
        easySpotPeripheral = nil
        pendingCommand = nil
    }
    
    // MARK: - CoreBluetooth Peripheral Delegate
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics([Constants.charUUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
            
        for characteristic in characteristics {
            if characteristic.uuid == Constants.charUUID {
                if let command = pendingCommand {
                    let data = Data([command])
                    
                    // CRITICAL: We use `.withResponse` to prevent a race condition on the Android side.
                    // If we disconnect too fast, Android fails to process the state change.
                    peripheral.writeValue(data, for: characteristic, type: .withResponse)
                    print("Attempting to write command: \(command)...")
                }
            }
        }
    }
    
    /// Listens for the delivery receipt from Android before safely hanging up the connection.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error writing command: \(error.localizedDescription)")
            state = .error("Failed to send command")
        } else {
            print("Receipt confirmed! Android device processed the command.")
            state = .success
        }
            
        // Disconnect immediately to save battery on both devices
        centralManager.cancelPeripheralConnection(peripheral)
        pendingCommand = nil
        easySpotPeripheral = nil // <-- NEW: Explicitly clear the memory!
    }
    
    // Safely destroy background listeners if the app quits or resets
    deinit {
        centralManager.delegate = nil
        easySpotPeripheral?.delegate = nil
        easySpotPeripheral = nil
    }
}
