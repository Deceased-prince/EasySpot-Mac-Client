//
//  easyspotApp.swift
//  easyspot
//
//  Created by Joshua Mendoza on 4/5/26.
//

import SwiftUI
import ServiceManagement
import AppKit
import Foundation
import Observation

// MARK: - App Entry Point

/// The top-level SwiftUI `App` struct and the sole entry point for EasySpot.
///
/// ## App Architecture
/// EasySpot is a macOS Menu Bar-only app (no dock icon, no main window). The entire
/// UI lives inside a `MenuBarExtra` scene. Two long-lived manager objects are owned here
/// at the `App` level so they survive menu open/close cycles:
/// - `BLEManager`: handles the Bluetooth "sniper" command.
/// - `NetworkManager`: handles passive Wi-Fi monitoring and the forced connection handshake.
///
/// ## Hotspot Flow Overview
/// 1. User taps **Turn Hotspot ON**.
/// 2. `BLEManager` scans for the Android device and writes a 1-byte ON command over BLE.
/// 3. Simultaneously, a repeating 5-second timer calls `NetworkManager.forceConnect()`
///    to try associating the Mac to the hotspot Wi-Fi network.
/// 4. When `isConnectedToHotspot` flips to `true`, the timer is invalidated and the UI resets.
/// 5. If the BLE step fails, `onChange(of: bleManager.state)` catches it and cancels everything early.
/// 6. If the Wi-Fi step never succeeds after 60 seconds, `showConnectionTimeoutAlert()` is presented.
@main
struct EasySpotTriggerApp: App {

    // MARK: - Long-Lived Managers

    // `@State` on an App-level struct is equivalent to `@StateObject` — it is owned by the
    // SwiftUI scene graph and will NOT be re-initialized when the menu closes and reopens.
    // `@Observable` classes do not use `@StateObject`; `@State` is the correct wrapper here.
    @State var bleManager     = BLEManager()
    @State var networkManager = NetworkManager()

    // MARK: - Persisted App Preferences

    /// A lightweight boolean flag that lets the UI know whether a Keychain password exists,
    /// without having to read the Keychain on every render. The password itself is never
    /// stored in UserDefaults — only this indicator flag is.
    @AppStorage("isPasswordSaved") private var isPasswordSaved = false

    /// Tracks whether the user has manually typed in an SSID vs. selected one from the scanner.
    /// When `true`, the UI shows the manual label and a "Switch back" button instead of the picker.
    @AppStorage("isManualSSID") private var isManualSSID = false

    // MARK: - Ephemeral UI State

    /// Mirrors the current state of `SMAppService` to drive the "Launch at Login" checkbox.
    /// Initialized once from the live service status.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// `true` while the BLE command has been sent and we are waiting for the Mac to join the
    /// hotspot Wi-Fi. Controls the "Connecting..." button label and the animated Menu Bar icon.
    @State private var isTransitioning = false

    /// A reference to the active Wi-Fi handshake timer so it can be invalidated early
    /// (e.g., if BLE fails or the user taps the button again).
    @State private var hotspotConnectionTimer: Timer?

    /// A `ProcessInfo` activity token held for the duration of the Wi-Fi handshake.
    ///
    /// macOS "App Nap" can throttle or freeze timers in apps that are not in the foreground.
    /// Holding this token tells the OS that a user-initiated operation is in progress and
    /// that the app must not be throttled until the token is explicitly released.
    /// Every `beginActivity` call MUST be paired with a corresponding `endActivity` call.
    @State private var connectionActivity: NSObjectProtocol?

    // MARK: - Computed Menu Bar Icon

    /// Returns the appropriate SF Symbol name for the current app state.
    ///
    /// Priority order (highest to lowest):
    /// 1. `personalhotspot`  — Mac is connected to the hotspot (success state).
    /// 2. `…circle`          — BLE command sent; actively trying to join Wi-Fi (ON flow).
    /// 3. `…slash`           — BLE OFF command sent; waiting for SSID to drop (disconnecting).
    /// 4. `…slash`           — BLE error occurred (scan timed out, device not found, etc.).
    /// 5. `…`                — Default idle state.
    var menuBarIcon: String {
        if networkManager.isConnectedToHotspot {
            return "personalhotspot"
        } else if isTransitioning {
            return "antenna.radiowaves.left.and.right.circle"
        } else if case .disconnecting = bleManager.state {
            // Reuse the slash icon to visually indicate the connection is winding down.
            return "antenna.radiowaves.left.and.right.slash"
        } else if case .error = bleManager.state {
            return "antenna.radiowaves.left.and.right.slash"
        } else {
            return "antenna.radiowaves.left.and.right"
        }
    }

    // MARK: - Menu Bar UI

    var body: some Scene {
        MenuBarExtra("EasySpot", systemImage: menuBarIcon) {
            // `@Bindable` is required to derive two-way SwiftUI bindings (the `$` prefix)
            // from `@Observable` objects. Without it, `$nm.targetSSID` would not compile.
            @Bindable var bm = bleManager
            @Bindable var nm = networkManager

            VStack {

                // MARK: Main Action Button
                // Tap to start or stop the hotspot flow. The label reflects the current state.
                // Disabled while a connection is in progress or no target SSID has been set.
                Button(action: {
                    toggleHotspotFlow()
                }) {
                    if isTransitioning {
                        Text("Connecting...")
                    } else if case .disconnecting = bleManager.state {
                        // The BLE OFF command has been sent. We are now waiting for the
                        // passive SSID monitor to confirm the hotspot has stopped broadcasting.
                        Text("Disconnecting...")
                    } else if networkManager.isConnectedToHotspot {
                        Text("Turn Hotspot OFF")
                    } else {
                        Text("Turn Hotspot ON")
                    }
                }
                // Also disable the button while disconnecting to prevent the user from
                // firing a new command while the previous OFF sequence is still in flight.
                .disabled(isTransitioning || networkManager.targetSSID.isEmpty || {
                    if case .disconnecting = bleManager.state { return true }
                    return false
                }())

                // MARK: Inline BLE Error Display
                // If BLE fails (e.g., device not found), the error message is shown in-line
                // beneath the button rather than spawning an intrusive modal alert.
                if case .error(let message) = bleManager.state {
                    Text("⚠️ \(message)")
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Divider()

                // MARK: Network Target Selector
                // Two modes: "Auto-Scan" (shows a Picker populated by a hardware Wi-Fi scan)
                // and "Manual" (shows the user-typed SSID with a revert button).
                if isManualSSID {
                    // Manual Mode — display the stored SSID as a read-only label.
                    Text("Target: \(networkManager.targetSSID)")
                        .font(.caption)
                        .foregroundColor(.gray)

                    Button("Switch back to Auto-Scan") {
                        isManualSSID = false
                        // Clear the target so the main button disables until a new one is chosen.
                        networkManager.targetSSID = ""
                        networkManager.scanForNetworks()
                    }
                } else {
                    // Auto-Scan Mode — show the picker or a "scanning" placeholder.
                    if networkManager.availableNetworks.isEmpty {
                        Text("Scanning for active networks...")
                            .font(.caption)
                            .foregroundColor(.gray)
                    } else {
                        Picker("Target Hotspot:", selection: $nm.targetSSID) {
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

                // MARK: BLE Scan Timeout Picker
                // Lets the user tune how long BLEManager scans before giving up.
                // The selected value is persisted in UserDefaults via `BLEManager.scanTimeoutDuration`.
                Picker("BLE Scan Timeout:", selection: $bm.scanTimeoutDuration) {
                    Text("10s").tag(10.0)
                    Text("15s").tag(15.0)
                    Text("20s").tag(20.0)
                    Text("30s").tag(30.0)
                }

                Divider()

                // MARK: Settings
                Button(action: {
                    promptForPassword()
                }) {
                    Image(systemName: "key")
                    // Read the lightweight boolean flag rather than the Keychain itself to
                    // decide which label to show. Avoids a synchronous Keychain read on render.
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
                // Sync Wi-Fi state immediately rather than waiting for the first 2-second tick.
                networkManager.checkWiFiState()
                // Request notification permission once. The OS will only show the system
                // prompt on first launch — subsequent calls are no-ops.
                bleManager.requestNotificationPermission()
            }
            // Observe BLE state changes to react immediately when BLE fails.
            //
            // Without this, a BLE failure (e.g., scan timeout after 15s) would leave
            // `isTransitioning = true` and the Wi-Fi handshake timer running for a full
            // 60 seconds before finally displaying a timeout alert — even though the BLE
            // side already failed and no hotspot command was ever sent.
            .onChange(of: bleManager.state) { _, newState in
                if case .error = newState {
                    isTransitioning = false
                    hotspotConnectionTimer?.invalidate()
                    hotspotConnectionTimer = nil

                    // Release the App Nap suppression token early since the operation is over.
                    if let activity = connectionActivity {
                        ProcessInfo.processInfo.endActivity(activity)
                        connectionActivity = nil
                    }
                }
            }
            // Observe Wi-Fi connection changes to detect when the hotspot disconnects.
            //
            // When `isConnectedToHotspot` flips from `true` to `false` and the BLE state
            // is `.disconnecting`, the Android device has confirmed the hotspot is off.
            // We reset BLE state to `.idle` so the UI returns to "Turn Hotspot ON".
            .onChange(of: networkManager.isConnectedToHotspot) { _, isConnected in
                if !isConnected, case .disconnecting = bleManager.state {
                    bleManager.state = .idle
                    print("Hotspot disconnected. BLE state reset to idle.")
                }
            }
        }
    }

    // MARK: - AppKit Popups

    /// Presents a native AppKit alert prompting the user to type their hotspot SSID manually.
    ///
    /// Used when the Wi-Fi scanner can't find the hotspot (e.g., it's hidden or out of initial range).
    ///
    /// `NSApp.activate()` is required for Menu Bar apps to bring the alert to the foreground.
    /// Without it, the alert window spawns behind the focused app and appears invisible to the user.
    func promptForSSID() {
        NSApp.activate() // macOS 14+ replacement for the deprecated `ignoringOtherApps: true` variant.

        let alert = NSAlert()
        alert.messageText    = "Manual Hotspot Configuration"
        alert.informativeText = "Enter the exact name (SSID) of your Android hotspot."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        inputField.placeholderString = "e.g. Pixel_10_Pro"
        alert.accessoryView = inputField

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // Trim whitespace to prevent invisible characters from causing a mismatch.
            let enteredSSID = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !enteredSSID.isEmpty {
                networkManager.targetSSID = enteredSSID
                isManualSSID = true
            }
        }
    }

    /// Presents a native AppKit alert with a secure text field for the hotspot Wi-Fi password.
    ///
    /// The password is saved to the Keychain via `KeychainHelper`. A lightweight boolean flag
    /// (`isPasswordSaved`) is updated in `AppStorage` so the UI knows whether a password exists
    /// on future launches without needing to read the Keychain during rendering.
    func promptForPassword() {
        NSApp.activate() // macOS 14+ replacement for the deprecated `ignoringOtherApps: true` variant.

        let alert = NSAlert()
        alert.messageText     = "EasySpot Wi-Fi Password"
        alert.informativeText = "Please enter the password for your Android hotspot. This is required to force the Mac to auto-join the network."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        // `NSSecureTextField` renders input as dots (•••) so the password is never visible on screen.
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        passwordField.placeholderString = "Hotspot Password"
        alert.accessoryView = passwordField

        let response = alert.runModal()

        // User hit Cancel — bail out without touching the Keychain.
        guard response == .alertFirstButtonReturn else { return }

        let newPassword    = passwordField.stringValue
        let keychainService = "\(Bundle.main.bundleIdentifier ?? "com.Unknown.EasySpot").HotspotPassword"

        let result = KeychainHelper.savePassword(newPassword, for: keychainService)

        switch result {
        case .success:
            print("✅ Password saved to Keychain.")
            // Only set the flag to `true` if the password isn't blank (clearing a password).
            isPasswordSaved = !newPassword.isEmpty

        case .failure(let error):
            print("❌ Keychain save failed: \(error.localizedDescription)")
            // Surface the error to the user with a clear explanation.
            let errorAlert = NSAlert()
            errorAlert.messageText     = "Failed to Save Password"
            errorAlert.informativeText = "macOS denied access to the Keychain. Please check your Mac's security settings."
            errorAlert.alertStyle       = .critical
            errorAlert.runModal()
        }
    }

    // MARK: - Hotspot Flow Logic

    /// Orchestrates the full hybrid BLE + Wi-Fi hotspot handshake.
    ///
    /// ## Turn OFF
    /// Simply fires a BLE OFF command. The Wi-Fi will naturally drop once the hotspot
    /// broadcasting stops, and the 2-second passive monitor will detect the change.
    ///
    /// ## Turn ON
    /// 1. Validates that a Keychain password is available (prompts if not).
    /// 2. Sends a BLE ON command to the Android device.
    /// 3. Acquires a `ProcessInfo` activity token to suppress App Nap.
    /// 4. Starts a repeating 5-second timer for up to 12 attempts (60 seconds total),
    ///    calling `forceConnect()` each tick to try to associate the Mac to the hotspot.
    /// 5. Clears the timer and releases the activity token when the connection is confirmed
    ///    or the 60-second window expires.
    func toggleHotspotFlow() {
        if networkManager.isConnectedToHotspot {
            // Already on the hotspot — send the OFF command and let passive monitoring
            // detect the disconnect naturally.
            bleManager.triggerHotspot(turnOn: false)
        } else {
            // --- Turn ON path ---

            let keychainService = "\(Bundle.main.bundleIdentifier ?? "com.Unknown.EasySpot").HotspotPassword"
            var currentPassword = KeychainHelper.loadPassword(for: keychainService) ?? ""

            // If no password is stored, block and prompt for one before continuing.
            if currentPassword.isEmpty {
                promptForPassword()
                // Re-read after the user (hopefully) entered a password.
                currentPassword = KeychainHelper.loadPassword(for: keychainService) ?? ""

                if currentPassword.isEmpty {
                    print("Connection aborted: no password was provided.")
                    return
                }
            }

            // Step 1: Fire the BLE ON command. This is non-blocking — the actual
            // write happens asynchronously via the CoreBluetooth delegate chain.
            bleManager.triggerHotspot(turnOn: true)
            isTransitioning = true

            // Invalidate any pre-existing timer to prevent overlapping handshake loops
            // if the user somehow triggers the flow twice rapidly.
            hotspotConnectionTimer?.invalidate()

            // Step 2: Acquire the App Nap suppression token.
            // IMPORTANT: This must always be paired with an `endActivity` call in every
            // code path that can terminate the handshake (success, timeout, or BLE error).
            connectionActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated,
                reason: "EasySpot Wi-Fi Hotspot Handshake"
            )

            var attempts = 0

            // Step 3: Start the Wi-Fi polling loop.
            // Every 5 seconds, try to force the Mac onto the hotspot. Stop after 12 attempts
            // (60 seconds) regardless of outcome to avoid an infinite loop.
            hotspotConnectionTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { timer in
                attempts += 1

                // Try to associate. This call is non-blocking — it dispatches its own work
                // to a background queue and returns immediately. An `isConnecting` guard inside
                // `NetworkManager.forceConnect` prevents overlapping background tasks.
                networkManager.forceConnect(to: networkManager.targetSSID, password: currentPassword)

                if networkManager.isConnectedToHotspot {
                    // ✅ Success path — Mac joined the hotspot.
                    isTransitioning = false
                    timer.invalidate()
                    hotspotConnectionTimer = nil

                    // Release the App Nap token — the critical operation is complete.
                    if let activity = connectionActivity {
                        ProcessInfo.processInfo.endActivity(activity)
                        connectionActivity = nil
                    }

                } else if attempts >= 12 {
                    // ⏱ Timeout path — BLE may have succeeded but the Mac never joined.
                    // This can happen when the hotspot takes longer than 60s to broadcast,
                    // or if the Wi-Fi association is blocked by a macOS network policy.
                    isTransitioning = false
                    timer.invalidate()
                    hotspotConnectionTimer = nil

                    // Release the App Nap token before showing the alert.
                    if let activity = connectionActivity {
                        ProcessInfo.processInfo.endActivity(activity)
                        connectionActivity = nil
                    }

                    showConnectionTimeoutAlert()
                }
            }
        }
    }

    /// Presents a warning alert when the 60-second Wi-Fi handshake window expires
    /// without the Mac successfully joining the target hotspot.
    private func showConnectionTimeoutAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText     = "EasySpot — Connection Timed Out"
        alert.informativeText = "The hotspot command was sent to your Android device, but your Mac couldn't join the network within 60 seconds. Make sure the hotspot is broadcasting and try again."
        alert.alertStyle       = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Launch at Login

    /// Toggles the "Launch at Login" behavior using the modern `SMAppService` API.
    ///
    /// `SMAppService` replaced the older `SMLoginItemSetEnabled` API in macOS 13.
    /// The app must be code-signed for this to work; unsigned builds will silently fail.
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
            print("Failed to update launch-at-login: \(error)")
        }
    }
}
