# EasySpot macOS Native Client 🍎

A lightweight, purely native macOS menu bar utility designed to trigger and monitor your EasySpot Android hotspot seamlessly from your Mac.

Built from the ground up using modern Apple frameworks (`SwiftUI`, `CoreBluetooth`, and `CoreWLAN`), this client serves as a highly optimized, battery-conscious alternative to cross-platform or Python-based desktop clients.

## 🏗 The "Hybrid" Architecture
This app solves the Mac-to-Android hotspot handshake using a hybrid "Sniper & Passive Radar" approach to ensure near-zero battery drain on both devices.

1. **The Sniper (CoreBluetooth):** Instead of keeping a continuous Bluetooth connection alive in the background, this app connects to the Android BLE beacon *only* when the menu button is clicked. It sends the `[0x01]` command, waits for a delivery receipt, and immediately drops the Bluetooth connection.
2. **The Passive Radar (CoreWLAN):** To know when the hotspot is actually active, the app relies on the Mac's native Wi-Fi state. It passively checks the current SSID every 2 seconds. Because this doesn't trigger a physical hardware scan, it uses practically zero battery.
3. **The Aggressive Handshake:** When turning the hotspot ON, macOS can sometimes take up to a minute to naturally notice the new network. This app implements a 60-second active scanner that "kicks" the Mac's Wi-Fi antenna to instantly auto-join the hotspot the split-second the Android device broadcasts it.

## ✨ Features
* **100% Native UI:** Built entirely with `MenuBarExtra` for a true, lightweight macOS experience.
* **Dynamic Network Picker:** Automatically scans the room and populates a dropdown of available Wi-Fi networks to set as your target hotspot.
* **State-Aware Icon:** The menu bar icon dynamically updates to Apple's official "Personal Hotspot" icon when a successful Wi-Fi connection is verified.
* **Launch at Login:** Seamless system integration using `ServiceManagement`.
* **Zero Third-Party Dependencies:** Uses nothing but Apple's native frameworks.

## 🚀 Installation

*Note: This initial release is self-signed. You will need to bypass Apple's Gatekeeper on the first launch.*

1. Go to the **[Releases](../../releases)** page and download the latest `easyspot.app.zip`.
2. Extract the `.zip` file and drag `easyspot.app` into your Mac's **Applications** folder.
3. Because this app is not signed with a paid Apple Developer certificate, double-clicking it will show an "Unidentified Developer" warning. 
4. **To open it:** Right-click (or Control-click) the app and select **Open**. Click **Open** again in the warning dialog.
5. Grant the app **Location Permissions** (macOS requires this to read the names of Wi-Fi networks).

## 🛠 Usage
1. Click the antenna icon in your menu bar.
2. Wait a few seconds for the network list to populate (or click "Refresh Network List").
3. Select your Android phone's hotspot SSID from the dropdown menu.
4. Click **Turn Hotspot ON**. The app will trigger the phone and wait for the Mac to auto-join the network!

## 🤝 Credits
This client was built to integrate with the fantastic [EasySpot](https://github.com/EasySpotApp) ecosystem.
