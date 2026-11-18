//
//  MenuBarController.swift
//  Status-bar item: a click opens the quick-controls panel, a right-click (or control-click) the menu.
//

import AppKit
import Combine
import ServiceManagement
import SwiftUI

// App-level options, set from the status item's right-click menu (reachable even while disconnected).
enum MenuBarSettings {
    static let showBatteryKey = "MenuBarShowBattery"
    static let showModeKey = "MenuBarShowMode"
    static let menuBarOnlyKey = "MenuBarOnly"
    static let connectOnLaunchKey = "ConnectOnLaunch"

    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static var showBattery: Bool {
        get { bool(showBatteryKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: showBatteryKey) }
    }
    static var showMode: Bool {
        get { bool(showModeKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: showModeKey) }
    }
    // No Dock icon and no window at launch; the window still opens from the status item, or by launching
    // the app again (Finder, Spotlight), so it stays reachable if the menu bar hides the status item.
    static var menuBarOnly: Bool {
        get { bool(menuBarOnlyKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: menuBarOnlyKey) }
    }
    static var connectOnLaunch: Bool {
        get { bool(connectOnLaunchKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: connectOnLaunchKey) }
    }

    // Launch at login goes through SMAppService (macOS 13+); the system owns the state, so it is never cached.
    static var launchAtLoginAvailable: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }
    static var launchAtLogin: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }
    static func setLaunchAtLogin(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else { return }
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

// Installed once from AppDelegate; reads and drives the same HeadphonesModel as the window. The icon shows the
// playback device next to the headphones (phone, computer, or its multipoint slot number), and the headphones
// fill in while playback is fixed to this Mac.
@objc final class MenuBarController: NSObject, NSMenuDelegate {
    private static var instance: MenuBarController?

    private let model = HeadphonesModel.shared
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    @objc static func install() {
        guard instance == nil else { return }
        // The panel can open before the window has appeared, so don't wait for it to apply the theme.
        AppTheme.stored.applyToApp()
        instance = MenuBarController()
        if MenuBarSettings.menuBarOnly {
            applyActivationPolicy()
            NSApp.windows.filter { $0.contentViewController != nil && !($0 is NSPanel) }.forEach { $0.orderOut(nil) }
        }
        if MenuBarSettings.connectOnLaunch {
            // Next turn, so the window (if shown) can render before the connect pumps the run loop.
            DispatchQueue.main.async { HeadphonesModel.shared.connectOnLaunchIfPossible() }
        }
    }

    private static func applyActivationPolicy() {
        NSApp.setActivationPolicy(MenuBarSettings.menuBarOnly ? .accessory : .regular)
    }

    private override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false

        let panel = NSHostingController(rootView: QuickControlsView(
            openWindow: { [weak self] in self?.popover.performClose(nil); Self.openMainWindow() },
            quit: { NSApp.terminate(nil) }
        ))
        if #available(macOS 13.0, *) { panel.sizingOptions = .preferredContentSize }
        popover.contentViewController = panel
        popover.behavior = .transient
        // Let the panel's background extend under the arrow, so the arrow matches the theme instead of
        // showing the system material. Earlier systems keep the default arrow.
        if #available(macOS 14.0, *) { popover.hasFullSizeContent = true }

        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateIcon()
        // objectWillChange fires before the new values land, so read them on the next main-loop turn.
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &cancellables)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            // A status item with a menu attached never sends its action, so attach it for this click only.
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            refreshMultipointIfIdle()
            if let panel = popover.contentViewController, #unavailable(macOS 13.0) {
                popover.contentSize = panel.view.fittingSize
            }
            // A popover takes its appearance from the status item, which follows the menu bar (light over a light
            // wallpaper), not from the app. The panel is themed dark, so system controls in it (the EQ picker)
            // then drew their light-mode text with a darkening blend: near-black on black. Use the app's appearance,
            // set per theme by AppTheme.applyToApp(), so the panel and its controls agree.
            popover.appearance = NSApp.effectiveAppearance
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    static func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.contentViewController != nil && !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
    }

    // Re-read so the panel or menu reflects changes made from the phone or the headset.
    private func refreshMultipointIfIdle() {
        if model.connected && !model.multipointBusy && !model.refreshingMultipoint {
            model.refreshMultipoint()
        }
    }

    // Phone if the name says so, computer for this Mac (or another Mac), otherwise the slot number.
    private func playbackSymbol(for device: PairedDeviceInfo) -> String {
        let name = device.name.lowercased()
        if name.contains("phone") { return "iphone" }
        if device.isThisMac || name.contains("mac") { return "laptopcomputer" }
        return "\(device.slot).circle"
    }

    // Noise Cancelling and Ambient Sound get a badge; Off gets none.
    private func modeSymbol() -> String? {
        guard model.connected, MenuBarSettings.showMode else { return nil }
        switch model.mode {
        case .noiseCanceling: return "waveform.slash"
        case .ambientSound: return "ear"
        default: return nil
        }
    }

    // The lowest earbud on TWS models (the one that runs out first), else the headset's single level.
    private func batteryTitle() -> String {
        guard model.connected, MenuBarSettings.showBattery else { return "" }
        let level: Int
        if model.hasDualBattery {
            level = [model.batteryLeft, model.batteryRight].filter { $0 >= 0 }.min() ?? -1
        } else {
            level = model.batteryLevel
        }
        return level >= 0 ? "\(level)%" : ""
    }

    private func updateIcon() {
        let base = model.playbackPinnedToThisMac ? "headphones.circle.fill" : "headphones"
        let device = model.playbackDevice
        let accessories = [modeSymbol(), device.map(playbackSymbol(for:))].compactMap { $0 }
        statusItem.button?.image = Self.icon(base: base, accessories: accessories)
        let title = batteryTitle()
        statusItem.button?.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        statusItem.button?.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular),
        ])
        statusItem.button?.appearsDisabled = !model.connected
        if let device = device {
            let name = device.name.isEmpty ? device.address : device.name
            statusItem.button?.toolTip = "Playing on \(name)" + (model.playbackPinned ? " (fixed)" : "")
        } else {
            statusItem.button?.toolTip = model.connected ? model.deviceName : "SonyBridge"
        }
    }

    // Draws the headphones symbol with any smaller symbols beside it (mode, playback device), as one template image.
    // A symbol missing on this macOS version is skipped.
    private static func icon(base: String, accessories: [String]) -> NSImage? {
        let baseConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let accessoryConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        guard let baseImage = NSImage(systemSymbolName: base, accessibilityDescription: "SonyBridge")?
            .withSymbolConfiguration(baseConfig) else { return nil }
        let accessoryImages = accessories.compactMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(accessoryConfig)
        }
        guard !accessoryImages.isEmpty else {
            baseImage.isTemplate = true
            return baseImage
        }
        let spacing: CGFloat = 2
        let images = [baseImage] + accessoryImages
        let size = NSSize(width: images.map(\.size.width).reduce(0, +) + spacing * CGFloat(accessoryImages.count),
                          height: images.map(\.size.height).max() ?? 0)
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for part in images {
                part.draw(in: NSRect(x: x, y: (size.height - part.size.height) / 2,
                                     width: part.size.width, height: part.size.height))
                x += part.size.width + spacing
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SonyBridge"
        return image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if model.connected {
            menu.addItem(disabledItem(model.deviceName))
            if model.hasPlaybackPinState {
                if model.thisMac != nil {
                    let pinned = model.playbackPinnedToThisMac
                    let pin = actionItem(pinned ? "Playback Fixed to This Mac" : "Pin Playback to This Mac", #selector(pinToThisMac))
                    pin.state = pinned ? .on : .off
                    pin.isEnabled = !pinned && !model.multipointBusy
                    menu.addItem(pin)
                } else {
                    menu.addItem(disabledItem("This Mac isn't a connected device"))
                }
                if model.playbackPinned {
                    let unfix = actionItem("Unfix Playback", #selector(unfixPlayback))
                    unfix.isEnabled = !model.multipointBusy
                    menu.addItem(unfix)
                }
            }
            if model.multipointBusy {
                menu.addItem(disabledItem("Sending…"))
            } else if let error = model.errorMessage {
                menu.addItem(disabledItem(error))
            }
            refreshMultipointIfIdle()
        } else {
            menu.addItem(disabledItem("No headphones connected"))
            let connect = actionItem(model.connecting ? "Connecting…" : "Connect Headphones", #selector(connectHeadphones))
            connect.isEnabled = !model.connecting
            menu.addItem(connect)
            // Every paired device, so a renamed or unrecognised headset can be picked by hand.
            let chooser = NSMenuItem(title: "Connect To", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            model.reloadAvailableDevices()
            for device in model.availableDevices {
                let item = actionItem(device.name, #selector(connectToDevice(_:)))
                item.representedObject = device.address
                item.state = device.connected ? .on : .off
                item.isEnabled = !model.connecting
                if device.looksLikeSony { item.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: nil) }
                submenu.addItem(item)
            }
            if submenu.items.isEmpty { submenu.addItem(disabledItem("No paired devices")) }
            chooser.submenu = submenu
            menu.addItem(chooser)
        }
        menu.addItem(.separator())
        menu.addItem(settingsItem())
        menu.addItem(.separator())
        menu.addItem(actionItem("Open SonyBridge", #selector(openWindow)))
        menu.addItem(actionItem("Quit SonyBridge", #selector(quit), key: "q"))
    }

    @objc private func pinToThisMac() { model.pinPlaybackToThisMac() }
    @objc private func unfixPlayback() { model.setPlaybackPinned(false) }
    @objc private func openWindow() { Self.openMainWindow() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func connectHeadphones() {
        NSApp.activate(ignoringOtherApps: true)
        model.connect()
    }

    @objc private func connectToDevice(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String,
              let device = model.availableDevices.first(where: { $0.address == address }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        model.connect(to: device)
    }

    private func settingsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        func toggle(_ title: String, _ on: Bool, _ action: Selector) {
            let entry = actionItem(title, action)
            entry.state = on ? .on : .off
            submenu.addItem(entry)
        }
        toggle("Show Battery in Menu Bar", MenuBarSettings.showBattery, #selector(toggleShowBattery))
        toggle("Show Noise Control in Menu Bar", MenuBarSettings.showMode, #selector(toggleShowMode))
        submenu.addItem(.separator())
        toggle("Menu Bar Only (Hide Dock Icon)", MenuBarSettings.menuBarOnly, #selector(toggleMenuBarOnly))
        if MenuBarSettings.launchAtLoginAvailable {
            toggle("Open at Login", MenuBarSettings.launchAtLogin, #selector(toggleLaunchAtLogin))
        }
        toggle("Connect on Launch", MenuBarSettings.connectOnLaunch, #selector(toggleConnectOnLaunch))
        item.submenu = submenu
        return item
    }

    @objc private func toggleShowBattery() { MenuBarSettings.showBattery.toggle(); updateIcon() }
    @objc private func toggleShowMode() { MenuBarSettings.showMode.toggle(); updateIcon() }
    @objc private func toggleConnectOnLaunch() { MenuBarSettings.connectOnLaunch.toggle() }

    @objc private func toggleMenuBarOnly() {
        MenuBarSettings.menuBarOnly.toggle()
        Self.applyActivationPolicy()
        // Leaving the Dock deactivates the app; keep the window in front if it was open.
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleLaunchAtLogin() {
        let enable = !MenuBarSettings.launchAtLogin
        do {
            try MenuBarSettings.setLaunchAtLogin(enable)
            // Opening at login is only useful if the headphones connect too.
            if enable { MenuBarSettings.connectOnLaunch = true }
        } catch {
            let alert = NSAlert()
            alert.messageText = enable ? "Couldn't turn on Open at Login" : "Couldn't turn off Open at Login"
            alert.informativeText = error.localizedDescription
                + "\n\nYou can also manage it in System Settings → General → Login Items."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
