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
import Observation

// MARK: - NetworkManager

/// Manages Wi-Fi state monitoring and forced network connections to the Android hotspot.
///
/// ## Responsibilities
/// - **Passive Radar**: A lightweight 2-second polling timer reads the current SSID from
///   the Wi-Fi interface without triggering a hardware scan, resulting in near-zero CPU usage.
/// - **Active Scan**: When explicitly requested (e.g., on first launch or "Refresh" tap),
///   a full hardware scan discovers all nearby networks to populate the target SSID picker.
/// - **Force Connect**: During the hotspot handshake, repeatedly attempts to associate the
///   Mac to the target network using the saved Keychain password.
///
/// ## Threading Model
/// All CoreWLAN operations (`scanForNetworks`, `associate`) are **synchronous and blocking**.
/// They are therefore always dispatched to a background QoS queue. Any resulting UI state
/// updates are marshaled back to the main queue via `DispatchQueue.main.async`.
///
/// ## @Observable
/// Uses Swift 5.9's `@Observable` macro. The `targetSSID` property mirrors `@AppStorage`
/// behavior using a stored property with a `didSet` that writes directly to `UserDefaults` —
/// this pattern is required because `@AppStorage` cannot be used on stored properties inside
/// an `@Observable` class.
///
/// - Note: Requires macOS 14+.
@Observable
class NetworkManager: NSObject, CLLocationManagerDelegate {

    // MARK: - Public Observable Properties

    /// The SSID of the Wi-Fi network the Mac is currently connected to.
    /// Updated every 2 seconds by the passive monitoring timer.
    var currentSSID: String = ""

    /// `true` when `currentSSID` matches `targetSSID`, indicating the Mac is on the hotspot.
    var isConnectedToHotspot: Bool = false

    /// The list of SSIDs discovered during the most recent active Wi-Fi scan.
    /// Populated by `scanForNetworks()` and shown in the target SSID picker.
    var availableNetworks: [String] = []

    /// The SSID of the Android hotspot we want to connect to.
    ///
    /// Persisted across launches via `UserDefaults`. Uses a `didSet` observer instead of
    /// `@AppStorage` for compatibility with the `@Observable` macro.
    var targetSSID: String = UserDefaults.standard.string(forKey: "hotspotSSID") ?? "" {
        didSet { UserDefaults.standard.set(targetSSID, forKey: "hotspotSSID") }
    }

    // MARK: - Private State (Excluded from SwiftUI Observation)

    /// The shared CoreWLAN client used for all Wi-Fi operations.
    ///
    /// `CWWiFiClient.shared()` is required — not merely convenient. `associate(to:password:)`
    /// must go through the shared singleton to properly integrate with macOS's network routing
    /// stack. A non-shared `CWWiFiClient()` instance can scan SSIDs but does NOT hook into
    /// system routing, which causes a "connected but no internet" result when forcing a join.
    @ObservationIgnored private var client: CWWiFiClient = CWWiFiClient.shared()

    /// The Combine cancellable that drives the 2-second passive monitoring timer.
    /// Stored so it can be cleanly cancelled in `deinit`.
    @ObservationIgnored private var timer: AnyCancellable?

    /// The Core Location manager needed to satisfy the macOS Wi-Fi entitlement prompt.
    @ObservationIgnored private var locationManager = CLLocationManager()

    /// An in-flight connection lock. Prevents a new `forceConnect` call from starting while
    /// a previous background task is still executing its scan + associate sequence.
    @ObservationIgnored private var isConnecting = false

    // MARK: - Initializer

    override init() {
        super.init()

        locationManager.delegate = self

        // On macOS, CLLocationManager only has "always" authorization — the iOS concept of
        // "when in use" does not exist on the Mac. `requestAlwaysAuthorization()` is the
        // correct call. The actual gate for reading SSIDs on macOS is the `com.apple.security.network.client`
        // entitlement + Wi-Fi location permission, not this call alone.
        locationManager.requestAlwaysAuthorization()

        // Sync UI to the current Wi-Fi state immediately on launch.
        checkWiFiState()
        startMonitoring()
    }

    // MARK: - Passive Monitoring

    /// Starts a 2-second polling timer that passively reads the current SSID.
    ///
    /// `interface.ssid()` only reads from the Wi-Fi driver's cached state — it does NOT
    /// trigger a hardware radio scan. This means the polling loop has near-zero battery impact.
    func startMonitoring() {
        timer = Timer.publish(every: 2.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.checkWiFiState()
            }
    }

    /// Reads the current SSID and updates `currentSSID` and `isConnectedToHotspot`.
    ///
    /// Only modifies `@Observable` properties when the value actually changes to avoid
    /// triggering unnecessary SwiftUI re-renders on every timer tick.
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

    // MARK: - Active Scanning

    /// Actively powers the Wi-Fi antenna to enumerate all visible networks nearby.
    ///
    /// This is an expensive operation — it wakes the radio and takes 1-3 seconds.
    /// It is only triggered on first launch (after location permission is granted)
    /// and when the user taps "Refresh Network List" in the Menu Bar.
    func scanForNetworks() {
        guard let interface = client.interface() else { return }

        // Push the blocking CoreWLAN call off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let networks = try interface.scanForNetworks(withName: nil)
                // Deduplicate and sort for a clean picker experience.
                let ssids = networks.compactMap { $0.ssid }.filter { !$0.isEmpty }

                DispatchQueue.main.async {
                    self?.availableNetworks = Array(Set(ssids)).sorted()
                }
            } catch {
                print("Network scan failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - CLLocationManagerDelegate

    /// Called when the user responds to the macOS location permission prompt.
    ///
    /// On macOS, the authorized status value is `.authorized` — there is no
    /// `.authorizedWhenInUse` (that enum case is iOS-only and unavailable here).
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorized {
            // Kick off an initial network scan now that we have permission to read SSIDs.
            scanForNetworks()
        }
    }

    // MARK: - Force Connection

    /// Attempts to forcibly associate the Mac to the target hotspot using the saved password.
    ///
    /// Called repeatedly by the Wi-Fi handshake timer in `easyspotApp.swift` every 5 seconds
    /// until the connection succeeds or the 60-second window expires.
    ///
    /// The `isConnecting` guard ensures that if a previous attempt is still executing its
    /// background scan+associate sequence (which can take several seconds), the next timer
    /// tick is dropped rather than spawning a second overlapping task.
    func forceConnect(to ssid: String, password: String) {
        guard let interface = client.interface() else { return }

        // Drop the call if we're already mid-attempt to prevent overlapping background tasks.
        guard !isConnecting else {
            print("forceConnect: Already connecting, skipping this attempt.")
            return
        }
        isConnecting = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // `defer` guarantees the lock is always released, even if we `return` early or throw.
            defer {
                DispatchQueue.main.async { self?.isConnecting = false }
            }

            do {
                // Step 1: Scan specifically for our target SSID to get a `CWNetwork` object.
                // We cannot associate without one — `associate(to:password:)` needs the full
                // network object, not just the SSID string.
                let networks = try interface.scanForNetworks(withName: ssid)
                guard let targetNetwork = networks.first else {
                    print("forceConnect: Hotspot '\(ssid)' not visible yet. Will retry.")
                    return
                }

                // Step 2: Verify the password is present before attempting to associate.
                guard !password.isEmpty else {
                    print("forceConnect: No password available. Cannot associate.")
                    return
                }

                // Step 3: Tell macOS's network stack to drop the current network and join the hotspot.
                print("forceConnect: Hotspot found. Forcing Wi-Fi association...")
                try interface.associate(to: targetNetwork, password: password)

                // Step 4: Immediately re-check the SSID so the UI updates without waiting
                // for the next 2-second passive timer tick.
                DispatchQueue.main.async {
                    self?.checkWiFiState()
                }
            } catch {
                print("forceConnect: Failed — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Lifecycle

    /// Cleans up the Combine timer and CoreWLAN delegate when this object is deallocated.
    deinit {
        // Clearing the delegate prevents CoreWLAN from calling back into a deallocated object.
        // Since we use the shared singleton, this only affects our observer slot — it does not
        // tear down any system-wide Wi-Fi state.
        client.delegate = nil
        timer?.cancel()
        print("NetworkManager deallocated.")
    }
}
