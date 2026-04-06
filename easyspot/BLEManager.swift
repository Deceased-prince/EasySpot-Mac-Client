//
//  BLEManager.swift
//  easyspot
//
//  Created by Joshua Mendoza on 4/5/26.
//


import Foundation
import CoreBluetooth
import Combine

/// Handles the BLE communication with the EasySpot Android app.
/// Uses an efficient "Sniper" architecture: It only powers up the Bluetooth scan when triggered,
/// connects, sends the command, waits for a delivery receipt, and immediately drops the connection.
class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    // MARK: - Dependencies & State
    private var centralManager: CBCentralManager!
    private var easySpotPeripheral: CBPeripheral?
    private var pendingCommand: UInt8?
    
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
        pendingCommand = turnOn ? 1 : 0
        
        if centralManager.state == .poweredOn {
            print("Scanning for EasySpot BLE beacon...")
            centralManager.scanForPeripherals(withServices: [Constants.serviceUUID], options: nil)
        } else {
            print("Bluetooth is turned off or unavailable.")
        }
    }
    
    // MARK: - CoreBluetooth Central Manager Delegate
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn && pendingCommand != nil {
            centralManager.scanForPeripherals(withServices: [Constants.serviceUUID], options: nil)
        } else if central.state != .poweredOn {
            print("Bluetooth is not powered on.")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        print("Discovered EasySpot device. Stopping scan.")
        centralManager.stopScan()
        
        easySpotPeripheral = peripheral
        easySpotPeripheral?.delegate = self
        
        centralManager.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to device. Discovering services...")
        peripheral.discoverServices([Constants.serviceUUID])
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
        } else {
            print("Receipt confirmed! Android device processed the command.")
        }
        
        // Disconnect immediately to save battery on both devices
        centralManager.cancelPeripheralConnection(peripheral)
        pendingCommand = nil
    }
}
