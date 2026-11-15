// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct PermissionState: Equatable {
    var screenRecording: Bool
    var accessibility: Bool
    var ready: Bool { screenRecording && accessibility }
    var explanation: String {
        let missing = [screenRecording ? nil : "Screen Recording", accessibility ? nil : "Accessibility"].compactMap { $0 }
        return missing.isEmpty ? "Permissions ready" : "Allow " + missing.joined(separator: " and ") + " in System Settings → Privacy & Security."
    }
    static func current() -> PermissionState {
        PermissionState(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted())
    }
}

@available(macOS 14.0, *)
final class ConnectionWindow: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let watcher = LinkWatcher()
    private let discovery = ReceiverDiscovery()
    private var window: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "Waiting for a Thunderbolt/USB4 link to LOCachy…")
    private let permissions = NSTextField(wrappingLabelWithString: "")
    private let receivers = NSPopUpButton(frame: .zero, pullsDown: false)
    private let connect = NSButton(title: "Connect", target: nil, action: nil)
    private let retry = NSButton(title: "Rescan", target: nil, action: nil)
    private let recording = NSButton(title: "Allow Screen Recording…", target: nil, action: nil)
    private let accessibility = NSButton(title: "Allow Accessibility…", target: nil, action: nil)
    private var choices: [ReceiverChoice] = []
    private var selected: String?
    private var lastAutoTriedCode: String?
    private var sender: Sender?
    private var linkMessage = ""
    private var problem: String?
    private var terminating = false
    private var didResetTCC = false
    private var permissionTimer: Timer?
    private var signals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        watcher.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.linkMessage = snapshot.message
            if self.sender == nil { self.discovery.update(snapshot.links) }
            self.render()
        }
        discovery.onChange = { [weak self] choices in
            guard let self, self.sender == nil else { return }
            self.choices = choices
            self.selected = DiscoveryProfile.preferred(choices, previous: self.selected)
            self.renderChoices()
            if let selected = self.selected,
               let choice = choices.first(where: { $0.id == selected }),
               choice.code != self.lastAutoTriedCode {
                self.lastAutoTriedCode = choice.code
                self.connectPressed()
            }
        }
        discovery.onError = { [weak self] message in self?.problem = message; self?.render() }
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume(); signals.append(source)
        }
        watcher.start()
        refreshPermissions()
        window.center()
        if !PermissionState.current().ready {
            showSetupWindow()
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let state = PermissionState.current()
            self.refreshPermissions()
            if state.ready, self.window.isVisible, self.problem == nil {
                self.window.orderOut(nil)
                NSApplication.shared.setActivationPolicy(.accessory)
                if self.sender == nil, self.selected != nil {
                    self.lastAutoTriedCode = nil
                    self.connectPressed()
                }
            }
        }
    }

    private func showSetupWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 380),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "LOCachy Extended Display"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let title = NSTextField(labelWithString: "LOCachy Extended Display")
        title.font = .boldSystemFont(ofSize: 19)
        let note = NSTextField(wrappingLabelWithString: "Automatically connects when extdisplay is opened on LOCachy over a Thunderbolt/USB4 cable, hub, dock or daisy chain.")
        note.textColor = .secondaryLabelColor
        receivers.target = self
        receivers.action = #selector(receiverChanged)
        connect.target = self; connect.action = #selector(connectPressed)
        connect.keyEquivalent = "\r"
        retry.target = self; retry.action = #selector(retryPressed)
        recording.target = self; recording.action = #selector(recordingPressed)
        accessibility.target = self; accessibility.action = #selector(accessibilityPressed)
        let localNetwork = NSButton(title: "Local Network settings…", target: self, action: #selector(networkPressed))
        let permissionButtons = NSStackView(views: [recording, accessibility])
        permissionButtons.orientation = .horizontal
        permissionButtons.spacing = 8
        let actions = NSStackView(views: [connect, retry, localNetwork])
        actions.orientation = .horizontal
        actions.spacing = 8
        let stack = NSStackView(views: [title, note, status, receivers, permissions, permissionButtons, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        guard let content = window.contentView else { return }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22),
            receivers.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit LOCachy Extended Display", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApplication.shared.mainMenu = menu
        renderChoices()
    }

    func applicationDidBecomeActive(_ notification: Notification) { refreshPermissions() }
    func windowDidBecomeKey(_ notification: Notification) { refreshPermissions() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }
    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        guard let sender else { discovery.stop(); watcher.stop(); return .terminateNow }
        terminating = true
        sender.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func renderChoices() {
        guard window != nil else { return }
        receivers.removeAllItems()
        if choices.isEmpty { receivers.addItem(withTitle: "Waiting for LOCachy…") }
        else {
            if selected == nil { receivers.addItem(withTitle: "Choose a receiver…") }
            for choice in choices {
                receivers.addItem(withTitle: "\(choice.name) — \(choice.link.name)")
                receivers.lastItem?.representedObject = choice.id
            }
            if let selected, let item = receivers.itemArray.first(where: { $0.representedObject as? String == selected }) {
                receivers.select(item)
            }
        }
        render()
    }

    private func refreshPermissions() {
        guard window != nil else { return }
        let state = PermissionState.current()
        permissions.stringValue = state.explanation
        recording.isEnabled = !state.screenRecording && sender == nil
        accessibility.isEnabled = !state.accessibility && sender == nil
        render()
    }

    private func render() {
        guard window != nil else { return }
        if sender != nil {
            receivers.isEnabled = false
            connect.isEnabled = true; connect.title = "Disconnect"
            retry.isEnabled = false
        } else {
            receivers.isEnabled = choices.count > 1
            connect.title = "Connect"
            connect.isEnabled = selected != nil
            retry.isEnabled = true
            status.stringValue = problem ?? (choices.isEmpty ? linkMessage : "Receiver found on the Thunderbolt link.")
            status.textColor = problem == nil ? .labelColor : .systemRed
        }
    }

    @objc private func receiverChanged() {
        selected = receivers.selectedItem?.representedObject as? String
        problem = nil
        render()
    }

    @objc private func connectPressed() {
        if let session = sender { session.stop(); return }
        guard let selected, let choice = choices.first(where: { $0.id == selected }) else { return }
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        do {
            try LinkInterfaces.require(choice.link.name, index: choice.link.index)
            var bytes = Array(choice.code.utf8)
            defer { PairingCode.zero(&bytes) }
            var key = try bytes.withUnsafeBufferPointer { try PairingCode.decode($0) }
            defer { key.resetBytes(in: 0..<key.count) }
            let endpoint = try CableEndpoint(host: choice.address, port: choice.port, interface: choice.link.name)
            guard endpoint.interfaceIndex == choice.link.index else { throw SenderError("The Thunderbolt interface changed.") }
            let session = try Sender(endpoint: endpoint, key: key)
            key.resetBytes(in: 0..<key.count)
            session.onActive = { [weak self] in
                self?.status.stringValue = "Connected. Scaled resolutions are available in System Settings → Displays."
                self?.window.orderOut(nil)
                NSApplication.shared.setActivationPolicy(.accessory)
            }
            session.onEnd = { [weak self] reason, _ in self?.ended(reason) }
            sender = session
            problem = nil
            status.stringValue = "Connecting to LOCachy…"
            status.textColor = .labelColor
            discovery.stop()
            render()
            session.run()
        } catch {
            problem = String(describing: error)
            render()
        }
    }

    private func resetStaleScreenCaptureTCC() {
        guard !didResetTCC else { return }
        didResetTCC = true
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "ScreenCapture", "org.locachy.extdisplay.sender"]
        try? proc.run()
        proc.waitUntilExit()
    }

    private func ended(_ reason: String) {
        sender = nil
        if terminating {
            permissionTimer?.invalidate()
            discovery.stop(); watcher.stop()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
            return
        }
        if reason.contains("-3801") {
            resetStaleScreenCaptureTCC()
            _ = CGRequestScreenCaptureAccess()
            problem = "Allow Screen Recording for LOCachy Extended Display in System Settings → Privacy & Security."
            showSetupWindow()
        } else {
            problem = nil
        }
        choices = []; selected = nil
        renderChoices()
        watcher.refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.sender == nil, !self.terminating else { return }
            self.lastAutoTriedCode = nil
            self.discovery.stop()
            self.watcher.refresh()
        }
    }

    @objc private func retryPressed() {
        guard sender == nil else { return }
        problem = nil
        lastAutoTriedCode = nil
        discovery.stop()
        choices = []; selected = nil
        renderChoices()
        refreshPermissions()
        watcher.refresh()
    }

    @objc private func recordingPressed() {
        _ = CGRequestScreenCaptureAccess()
        openSettings("Privacy_ScreenCapture")
        refreshPermissions()
    }
    @objc private func accessibilityPressed() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("Privacy_Accessibility")
        refreshPermissions()
    }
    @objc private func networkPressed() { openSettings("Privacy_LocalNetwork") }
    private func openSettings(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) else { return }
        NSWorkspace.shared.open(url)
    }
}
