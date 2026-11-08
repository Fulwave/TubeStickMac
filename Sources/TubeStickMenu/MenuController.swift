import AppKit
import Combine
import SwiftUI
import TubeStickKit

/// Owns the window, the menu bar item and the Dock presence. The menu and window are views of `AppModel`.
final class MenuController: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private var subscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app bundle carries AppIcon.icns; the drawn icon is only a fallback for running outside a bundle.
        if Bundle.main.path(forResource: "AppIcon", ofType: "icns") == nil { NSApp.applicationIconImage = Self.dockIcon() }
        buildMainMenu()
        model.onError = { [weak self] error in self?.showError(error) }
        subscription = model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] in
            DispatchQueue.main.async { self?.rebuildStatusMenu() }
        }
        applyDisplayMode(model.displayMode, showWindow: true)
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    // MARK: - Presence

    private func applyDisplayMode(_ mode: DisplayMode, showWindow show: Bool = false) {
        model.displayMode = mode
        NSApp.setActivationPolicy(mode.showsDock ? .regular : .accessory)
        if mode.showsMenuBar {
            if statusItem == nil {
                statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItem?.button?.image = NSImage(systemSymbolName: "tv", accessibilityDescription: "TubeStick")
                statusItem?.button?.image?.isTemplate = true
            }
            rebuildStatusMenu()
        } else if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        if show && mode != .menuBarOnly { showWindow() }
        if mode == .menuBarOnly { window?.orderOut(nil) }
    }

    private func showWindow() {
        if window == nil {
            let view = StationWindow(model: model, onDisplayModeChange: { [weak self] in self?.applyDisplayMode($0) })
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "TubeStick"
            w.contentView = NSHostingView(rootView: view)
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("TubeStickMain")
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menus

    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide TubeStick", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit TubeStick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Show Window", action: #selector(showWindowAction), keyEquivalent: "0").target = self
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    private func rebuildStatusMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        let status = NSMenuItem(title: model.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if model.videoStations.isEmpty {
            let none = NSMenuItem(title: "No stations yet. Choose Scan for Stations.", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for s in model.videoStations {
            let entry = NSMenuItem(title: "\(s.number)  \(s.name)", action: #selector(playStation(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = s
            entry.isEnabled = !model.isScanning
            entry.state = model.playing?.id == s.id ? .on : .off
            entry.toolTip = "RF channel \(s.rfChannel), signal \(s.quality.rawValue)"
            if s.quality >= .fair {
                let note = NSMutableAttributedString(string: "\(s.number)  \(s.name)")
                note.append(NSAttributedString(string: s.quality == .poor ? "   poor signal" : "   weak signal",
                                               attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 11)]))
                entry.attributedTitle = note
            }
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        if model.playing != nil { add(menu, "Stop", #selector(stopPlaying)) }
        if model.firmwareMissing { add(menu, "Download Tuner Firmware…", #selector(downloadFirmware)) }
        if model.isScanning { add(menu, "Cancel Scan", #selector(cancelScan)) }
        else { let s = add(menu, "Scan for Stations", #selector(scanStations)); s.isEnabled = !model.busy || model.playing != nil }
        menu.addItem(.separator())
        add(menu, "Show Window", #selector(showWindowAction))
        let show = NSMenuItem(title: "Show App In", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for mode in DisplayMode.allCases {
            let m = NSMenuItem(title: mode.title, action: #selector(chooseDisplayMode(_:)), keyEquivalent: "")
            m.target = self; m.representedObject = mode.rawValue
            m.state = model.displayMode == mode ? .on : .off
            sub.addItem(m)
        }
        show.submenu = sub
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TubeStick", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        menu.addItem(i)
        return i
    }

    // MARK: - Actions

    @objc private func playStation(_ sender: NSMenuItem) { if let s = sender.representedObject as? Station { model.play(s) } }
    @objc private func stopPlaying() { model.stop() }
    @objc private func scanStations() { model.scan() }
    @objc private func cancelScan() { model.cancelScan() }
    @objc private func showWindowAction() { showWindow() }
    @objc private func chooseDisplayMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = DisplayMode(rawValue: raw) { applyDisplayMode(mode) }
    }

    @objc private func downloadFirmware() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Download tuner firmware?"
        alert.informativeText = "The stick's tuner chip needs a small firmware file each time it is plugged in. TubeStick will download it from kernel.org (the linux-firmware project, about 12 KB) and check its checksum."
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.downloadFirmware() }
    }

    private func showError(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "TubeStick"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    /// A simple Dock icon: a TV symbol on a rounded square.
    private static func dockIcon() -> NSImage {
        let size = NSSize(width: 256, height: 256)
        return NSImage(size: size, flipped: false) { rect in
            let body = NSBezierPath(roundedRect: rect.insetBy(dx: 16, dy: 16), xRadius: 56, yRadius: 56)
            NSColor(calibratedRed: 0.13, green: 0.35, blue: 0.75, alpha: 1).setFill()
            body.fill()
            if let symbol = NSImage(systemSymbolName: "tv", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 120, weight: .regular)) {
                let tinted = NSImage(size: symbol.size, flipped: false) { r in
                    symbol.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true
                }
                tinted.draw(in: NSRect(x: (rect.width - symbol.size.width) / 2, y: (rect.height - symbol.size.height) / 2,
                                       width: symbol.size.width, height: symbol.size.height))
            }
            return true
        }
    }
}
