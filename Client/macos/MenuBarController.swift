//
//  MenuBarController.swift
//  Status-bar item: a click opens the quick-controls panel, a right-click (or control-click) the menu.
//

import AppKit
import Combine
import SwiftUI

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
    private var appearanceObservation: NSKeyValueObservation?

    @objc static func install() {
        guard instance == nil else { return }
        // The panel can open before the window has appeared, so don't wait for it to apply the theme.
        AppTheme.stored.applyToApp()
        instance = MenuBarController()
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

        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateIcon()
        // objectWillChange fires before the new values land, so read them on the next main-loop turn.
        model.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
            .store(in: &cancellables)
        // Follow a light/dark switch made while the panel is open.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updatePopoverAppearance() }
        }
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
            updatePopoverAppearance()
            if let panel = popover.contentViewController, #unavailable(macOS 13.0) {
                popover.contentSize = panel.view.fittingSize
            }
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // The storyboard window isn't shown at launch (menu-bar app); it's made on first open and kept, since
    // it isn't released when closed.
    private static var windowController: NSWindowController?

    @objc static func openMainWindow() {
        if windowController == nil {
            windowController = NSStoryboard(name: "Main", bundle: nil)
                .instantiateController(withIdentifier: "MainWindow") as? NSWindowController
        }
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    // A status-item popover takes the menu bar's appearance, which follows the wallpaper rather than the
    // system setting, so set it from the theme (Native Glass: the system's light/dark) each time it shows.
    private func updatePopoverAppearance() {
        popover.appearance = AppTheme.stored.resolvedAppearance
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

    private func updateIcon() {
        let base = model.playbackPinnedToThisMac ? "headphones.circle.fill" : "headphones"
        let device = model.playbackDevice
        statusItem.button?.image = Self.icon(base: base, accessory: device.map(playbackSymbol(for:)))
        statusItem.button?.appearsDisabled = !model.connected
        if let device = device {
            let name = device.name.isEmpty ? device.address : device.name
            statusItem.button?.toolTip = "Playing on \(name)" + (model.playbackPinned ? " (fixed)" : "")
        } else {
            statusItem.button?.toolTip = model.connected ? model.deviceName : "SonyBridge"
        }
    }

    // Draws the headphones symbol with an optional second symbol beside it, as one template image.
    private static func icon(base: String, accessory: String?) -> NSImage? {
        let baseConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let accessoryConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        guard let baseImage = NSImage(systemSymbolName: base, accessibilityDescription: "SonyBridge")?
            .withSymbolConfiguration(baseConfig) else { return nil }
        guard let accessory = accessory,
              let accessoryImage = NSImage(systemSymbolName: accessory, accessibilityDescription: nil)?
                .withSymbolConfiguration(accessoryConfig) else {
            baseImage.isTemplate = true
            return baseImage
        }
        let spacing: CGFloat = 2
        let size = NSSize(width: baseImage.size.width + spacing + accessoryImage.size.width,
                          height: max(baseImage.size.height, accessoryImage.size.height))
        let image = NSImage(size: size, flipped: false) { _ in
            baseImage.draw(in: NSRect(x: 0, y: (size.height - baseImage.size.height) / 2,
                                      width: baseImage.size.width, height: baseImage.size.height))
            accessoryImage.draw(in: NSRect(x: baseImage.size.width + spacing, y: (size.height - accessoryImage.size.height) / 2,
                                           width: accessoryImage.size.width, height: accessoryImage.size.height))
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
        }
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
