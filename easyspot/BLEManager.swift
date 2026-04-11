//
//  BLEManager.swift
//  easyspot
//
//  Created by Joshua Mendoza on 4/5/26.
//

import Foundation
import CoreBluetooth
import Observation
import UserNotifications

// MARK: - BLE State

/// Represents every possible phase of the BLE connection lifecycle.
///
/// The UI observes this value to drive button labels, inline error messages,
/// and the Menu Bar icon. Conforming to `Equatable` is required for SwiftUI's
/// `.onChange(of:)` modifier, which performs an equality check before firing.
enum BLEState: Equatable {
    /// No BLE activity. The initial state on launch and after a clean teardown.
    case idle
    /// Actively scanning the air for the EasySpot BLE beacon.
    case scanning
    /// Peripheral was discovered; GATT service/characteristic discovery is in progress.
    case connecting
    /// Command was written and a delivery receipt was received from the Android device.
    case success
    /// The BLE OFF command has been sent and we are waiting for the Mac's Wi-Fi SSID
    /// to drop, confirming the Android hotspot has actually stopped broadcasting.
    /// The UI uses this to show a "Disconnecting..." label and a distinct Menu Bar icon
    /// rather than snapping immediately back to the idle "Turn Hotspot ON" state.
    case disconnecting
    /// Something went wrong. The associated `String` contains a human-readable description
    /// shown inline in the Menu Bar UI.
    case error(String)
}

// MARK: - BLEManager

/// Manages all BLE communication with the EasySpot Android companion app.
///
/// ## Architecture — "Sniper Mode"
/// Rather than keeping a persistent BLE connection alive (which drains battery on both
/// the Mac and the Android device), BLEManager uses a one-shot "sniper" approach:
/// 1. Scan for the EasySpot peripheral.
/// 2. Connect, discover services, and write a single 1-byte command.
/// 3. Wait for a write receipt (`.withResponse`) to confirm Android processed it.
/// 4. Immediately disconnect.
///
/// ## @Observable
/// Uses Swift 5.9's `@Observable` macro instead of the older Combine-based
/// `ObservableObject` + `@Published` pattern. Only the `state` and `scanTimeoutDuration`
/// properties participate in SwiftUI observation. All internal CoreBluetooth bookkeeping
/// properties are marked `@ObservationIgnored` to exclude them from tracking.
///
/// - Note: Requires macOS 14+.
@Observable
class BLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // MARK: - Public Observable State

    /// The current phase of the BLE lifecycle. Observed by the UI to update the
    /// Menu Bar icon and inline error messages.
    var state: BLEState = .idle

    // MARK: - Private State (Excluded from SwiftUI Observation)

    /// The CoreBluetooth central manager. Implicitly unwrapped because it is
    /// always initialized synchronously in `init()` before any methods are called.
    @ObservationIgnored private var centralManager: CBCentralManager!

    /// A strong reference to the discovered EasySpot peripheral, held from discovery
    /// until `didDisconnectPeripheral` fires. CoreBluetooth also holds its own internal
    /// reference, so we must not prematurely nil this out before the disconnect callback.
    @ObservationIgnored private var easySpotPeripheral: CBPeripheral?

    /// The raw command byte waiting to be delivered:  `1` = hotspot ON, `0` = hotspot OFF.
    /// Stored here so it survives the async discovery → connect → write delegate chain.
    @ObservationIgnored private var pendingCommand: UInt8?

    /// The timer that automatically aborts a scan after `scanTimeoutDuration` seconds
    /// to prevent the radio from running indefinitely if the Android device is out of range.
    @ObservationIgnored private var scanTimeoutTimer: Timer?

    // MARK: - BLE Service & Characteristic UUIDs

    /// Grouping UUIDs in a private enum makes it trivial to update them if the
    /// Android app ever changes its GATT signature, and prevents string-literal typos.
    private enum Constants {
        /// The primary GATT service UUID advertised by the EasySpot Android app.
        static let serviceUUID = CBUUID(string: "7baad717-1551-45e1-b852-78d20c7211ec")
        /// The writable GATT characteristic UUID that accepts the hotspot command byte.
        static let charUUID   = CBUUID(string: "47436878-5308-40f9-9c29-82c2cb87f595")
    }

    // MARK: - Configurable Scan Timeout

    /// How long (in seconds) to scan for the Android device before giving up.
    ///
    /// Backed by `UserDefaults` so the user's preference survives app restarts.
    /// The UI exposes this as a `Picker` with 10 / 15 / 20 / 30-second options.
    /// Defaults to 15 seconds if no value has been stored yet.
    var scanTimeoutDuration: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "bleScanTimeout")
            return stored > 0 ? stored : 15.0
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "bleScanTimeout")
        }
    }

    // MARK: - Initializer

    override init() {
        super.init()
        // Passing `queue: nil` schedules all CoreBluetooth delegate callbacks on the main
        // queue, which means we can safely update @Observable properties without dispatching.
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    /// Initiates the BLE sequence to turn the Android hotspot on or off.
    ///
    /// If a scan is already in progress, it is canceled and restarted with the new command.
    /// If we are mid-connection (GATT discovery in flight), the trigger is ignored to avoid
    /// leaving the peripheral in an undefined "zombie" state.
    ///
    /// - Parameter turnOn: `true` to send the ON command (byte `1`), `false` for OFF (byte `0`).
    func triggerHotspot(turnOn: Bool) {
        // Guard against concurrent triggers at different lifecycle stages.
        if case .scanning = state {
            print("Already scanning — canceling current scan to restart.")
            stopScanningAndReset()
        } else if case .connecting = state {
            print("Already connecting — ignoring trigger to avoid GATT race condition.")
            return
        }

        pendingCommand = turnOn ? 1 : 0

        if turnOn {
            // Entering the ON flow — begin scanning immediately.
            state = .scanning

            if centralManager.state == .poweredOn {
                print("Bluetooth powered on. Starting scan for EasySpot beacon...")
                startScanWithTimeout()
            } else {
                // Bluetooth may not be ready yet (e.g., app launched immediately at login).
                // `centralManagerDidUpdateState` will catch the `.poweredOn` transition and
                // kick off the scan automatically once the radio is ready.
                print("Bluetooth is not powered on. Waiting for state update...")
                state = .error("Bluetooth is turned off")
            }
        } else {
            // Entering the OFF flow — mark as disconnecting so the UI can show feedback
            // while the BLE scan runs and the Android device stops the hotspot.
            // The caller (`easyspotApp`) is responsible for watching `NetworkManager.isConnectedToHotspot`
            // and resetting this state back to `.idle` once the SSID disappears.
            state = .disconnecting
            print("Disconnecting — scanning to send OFF command...")

            if centralManager.state == .poweredOn {
                startScanWithTimeout()
            } else {
                print("Bluetooth is not powered on. Waiting for state update...")
                state = .error("Bluetooth is turned off")
            }
        }
    }

    // MARK: - Notification Permission

    /// Requests permission to display local macOS notifications.
    ///
    /// Should be called once on app launch (via `.onAppear`). Subsequent calls are safe —
    /// the OS will not prompt the user again if permission was already granted or denied.
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error.localizedDescription)")
            } else {
                print("Notification permission granted: \(granted)")
            }
        }
    }

    // MARK: - Private Helpers

    /// Starts a peripheral scan and schedules the timeout watchdog timer.
    ///
    /// Scanning is limited to peripherals advertising `Constants.serviceUUID` so that
    /// the Mac's Bluetooth radio only wakes for relevant devices, maximizing battery efficiency.
    private func startScanWithTimeout() {
        centralManager.scanForPeripherals(withServices: [Constants.serviceUUID], options: nil)

        // Cancel any pre-existing watchdog to avoid double-firing.
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: scanTimeoutDuration, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            print("Scan timed out after \(self.scanTimeoutDuration)s. Aborting.")
            self.stopScanningAndReset()

            // Only mark as error if we're still scanning — if the peripheral was discovered
            // in the final milliseconds, state may have already advanced to .connecting.
            if case .scanning = self.state {
                self.state = .error("Device not found")
                self.postNotification(
                    title: "EasySpot — Device Not Found",
                    body: "Couldn't find your Android device. Make sure Bluetooth is enabled and the EasySpot app is running."
                )
            }
        }
    }

    /// Tears down an in-progress scan and resets ephemeral connection state.
    ///
    /// Guards against interrupting a mid-connection GATT handshake: if we abort while
    /// `.connecting`, CoreBluetooth can leave the peripheral in a zombie state where it
    /// appears connected but never fires delegate callbacks. The peripheral cancel is
    /// therefore skipped in that phase.
    private func stopScanningAndReset() {
        centralManager.stopScan()
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
        pendingCommand = nil

        // Do not forcibly disconnect if CoreBluetooth is mid-handshake.
        if case .connecting = state { return }

        if let peripheral = easySpotPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
            easySpotPeripheral = nil
        }
    }

    /// Fires a local macOS notification banner.
    ///
    /// A unique identifier is generated per notification so that rapid-fire calls
    /// (e.g., two commands sent back-to-back) do not silently replace each other.
    /// Requires prior authorization via `requestNotificationPermission()`.
    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default

        // `trigger: nil` means the notification fires immediately (no delay or schedule).
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - CBCentralManagerDelegate

    /// Called whenever the Bluetooth radio changes state (e.g., powered on/off, unauthorized).
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn && pendingCommand != nil {
            // The radio just became available while a trigger was pending.
            // Only restart the scan if we are genuinely in the `.scanning` phase —
            // this prevents accidentally re-kicking a scan during a mid-connection
            // Bluetooth hiccup (e.g., a brief signal drop while writing to the peripheral).
            if case .scanning = state {
                print("Bluetooth powered on with pending command — resuming scan.")
                startScanWithTimeout()
            }
        } else if central.state != .poweredOn {
            print("Bluetooth is not powered on: \(central.state.rawValue)")
            if pendingCommand != nil {
                state = .error("Bluetooth is not powered on")
            }
        }
    }

    /// Called when a peripheral matching our service UUID filter is discovered.
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        print("Discovered EasySpot device (\(peripheral.name ?? "unknown")). Stopping scan.")

        // Cancel the timeout watchdog — we found the device in time.
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = nil
        centralManager.stopScan()

        // Advance state and retain the peripheral before connecting.
        // Setting the delegate here (rather than after `connect()`) ensures we never
        // miss any callbacks that could theoretically arrive very quickly.
        state = .connecting
        easySpotPeripheral = peripheral
        easySpotPeripheral?.delegate = self

        centralManager.connect(peripheral, options: nil)
    }

    /// Called when a connection to the peripheral is successfully established.
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected. Discovering GATT services...")
        // Filter discovery to only our target service UUID to minimize overhead.
        peripheral.discoverServices([Constants.serviceUUID])
    }

    /// Called when CoreBluetooth fails to establish a connection to the peripheral.
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        state = .error("Failed to connect to device")
        stopScanningAndReset()
    }

    /// Called when a peripheral disconnects, either expectedly (after our `cancelPeripheralConnection`
    /// call) or unexpectedly (e.g., Android device moved out of range mid-handshake).
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if let error = error {
            // An error here means the disconnection was NOT triggered by us — it was unexpected.
            print("Unexpected disconnection: \(error.localizedDescription)")

            // If we already reached `.success`, the write was confirmed before the drop.
            // That case is treated as a clean exit — not an error from the user's perspective.
            if case .success = state {
                // Expected — CoreBluetooth fires this after our cancelPeripheralConnection call.
            } else {
                state = .error("Disconnected unexpectedly")
            }
        } else {
            // No error means this was our own explicit cancelPeripheralConnection call.
            // Linger on `.success` briefly so the UI can display it, then return to idle.
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

        // nil out our reference here — NOT in didWriteValueFor — because CoreBluetooth holds
        // its own strong reference to the peripheral until this callback fires. Clearing our
        // pointer prematurely in didWriteValueFor would cause a mismatch with the internal ref.
        easySpotPeripheral = nil
        pendingCommand = nil
    }

    // MARK: - CBPeripheralDelegate

    /// Called after `discoverServices()` completes. Drills into each service to find our target characteristic.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            // Filter characteristic discovery to only our known UUID to minimize radio time.
            peripheral.discoverCharacteristics([Constants.charUUID], for: service)
        }
    }

    /// Called after `discoverCharacteristics(for:)` completes. Writes the pending command if our
    /// target characteristic is present.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics {
            if characteristic.uuid == Constants.charUUID {
                if let command = pendingCommand {
                    let data = Data([command])

                    // `.withResponse` is critical here. If we used `.withoutResponse` and
                    // disconnected immediately, Android's BLE stack might not have finished
                    // processing the state change before the connection drops, causing the
                    // hotspot toggle to be silently ignored.
                    peripheral.writeValue(data, for: characteristic, type: .withResponse)
                    print("Writing command byte \(command) to EasySpot characteristic...")
                }
            }
        }
    }

    /// Called after a `.withResponse` write completes, confirming Android received the command.
    ///
    /// This is the final step of the BLE lifecycle. Regardless of success or failure,
    /// we immediately disconnect to save battery on both the Mac and the Android device.
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Write failed: \(error.localizedDescription)")
            state = .error("Failed to send command")
            postNotification(
                title: "EasySpot — Command Failed",
                body: "Failed to send the hotspot command: \(error.localizedDescription)"
            )
        } else {
            print("Write receipt confirmed. Android processed the command.")
            state = .success

            // Notify the user that the BLE side of the handshake succeeded.
            // The Wi-Fi join phase is handled separately by NetworkManager.
            let commandWasOn = pendingCommand == 1
            postNotification(
                title: "EasySpot",
                body: commandWasOn
                    ? "Hotspot command sent! Waiting for network to appear..."
                    : "Hotspot off command sent."
            )
        }

        // Trigger an immediate disconnect. Battery on both devices is conserved by
        // never holding a BLE connection open longer than the single write round-trip.
        // NOTE: Do NOT nil out `easySpotPeripheral` here — `didDisconnectPeripheral`
        // is the correct and safe place to do that (see its comment above).
        centralManager.cancelPeripheralConnection(peripheral)
        pendingCommand = nil
    }

    // MARK: - Lifecycle

    /// Cleans up delegate references when the object is deallocated.
    ///
    /// Setting delegates to `nil` prevents CoreBluetooth from calling back into a
    /// deallocated object, which would cause a crash (EXC_BAD_ACCESS).
    deinit {
        centralManager.delegate = nil
        easySpotPeripheral?.delegate = nil
        easySpotPeripheral = nil
    }
}
