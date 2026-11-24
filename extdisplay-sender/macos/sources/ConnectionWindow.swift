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
final class ConnectionWindow: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum SessionState: Equatable {
        case connecting
        case active(String) // display label
    }

    private struct ActiveSession {
        let key: String
        let sender: Sender
        var choice: ReceiverChoice
        var state: SessionState
        let usingStoredCredential: Bool
        var rememberOnActive: Bool
        var pendingIdentity: String?
        var pendingCode: String?
    }

    private struct RowItem {
        let key: String
        let choice: ReceiverChoice?
        let storedPeer: StoredPeer?
        let session: ActiveSession?
        let authFailed: Bool
        let lastError: String?
    }

    private let watcher = LinkWatcher()
    private let discovery = ReceiverDiscovery()
    private let peerStore = PeerStore.shared
    private var window: NSWindow!
    private let status = NSTextField(wrappingLabelWithString: "Waiting for a Thunderbolt/USB4 link to LOCachy…")
    private let permissions = NSTextField(wrappingLabelWithString: "")
    private let tableView = NSTableView()
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let pairButton = NSButton(title: "Pair…", target: nil, action: nil)
    private let forgetButton = NSButton(title: "Forget", target: nil, action: nil)
    private let retryButton = NSButton(title: "Rescan", target: nil, action: nil)
    private let recording = NSButton(title: "Allow Screen Recording…", target: nil, action: nil)
    private let accessibility = NSButton(title: "Allow Accessibility…", target: nil, action: nil)

    private var choices: [ReceiverChoice] = []
    private var sessions: [String: ActiveSession] = [:]
    private var rows: [RowItem] = []
    private var selectedKey: String?
    private var lastAutoTriedCode: [String: String] = [:]
    private var lastAutoTriedStored: [String: String] = [:]
    private var authFailedKeys = Set<String>()
    private var manuallyDisconnectedKeys = Set<String>()
    private var sessionErrors: [String: String] = [:]
    private var linkMessage = ""
    private var problem: String?
    private var terminating = false
    private var terminateReplied = false
    private var didResetTCC = false
    private var permissionTimer: Timer?
    private var signals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        watcher.onChange = { [weak self] snapshot in
            guard let self else { return }
            self.linkMessage = snapshot.message
            // Keep discovery running even while sessions are active so additional
            // LOCachy displays plugged into Thunderbolt/USB4 connect automatically.
            self.discovery.update(snapshot.links)
            self.render()
        }
        discovery.onChange = { [weak self] choices in
            guard let self else { return }
            self.choices = choices
            let presentKeys = Set(choices.map { $0.peerKey })
            self.manuallyDisconnectedKeys.formIntersection(presentKeys)
            self.rebuildRows()
            self.autoConnectEligible()
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
            if state.ready, self.window.isVisible, self.problem == nil, self.authFailedKeys.isEmpty {
                let anyNeedsPair = self.rows.contains { row in
                    row.session == nil && row.choice != nil && row.choice!.pairedOnly && row.storedPeer == nil
                }
                if !anyNeedsPair {
                    self.window.orderOut(nil)
                    NSApplication.shared.setActivationPolicy(.accessory)
                }
                if !self.choices.isEmpty {
                    self.lastAutoTriedCode.removeAll()
                    self.lastAutoTriedStored.removeAll()
                    self.autoConnectEligible()
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "LOCachy Extended Display"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isRestorable = false

        let title = NSTextField(labelWithString: "LOCachy Extended Display")
        title.font = .boldSystemFont(ofSize: 19)
        let note = NSTextField(wrappingLabelWithString: "Automatically connects to one or more LOCachy receivers over Thunderbolt/USB4 cables, hubs, docks, or daisy chains. Paired receivers reconnect automatically without a code.")
        note.textColor = .secondaryLabelColor

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("receiver"))
        nameColumn.title = "Receiver"
        nameColumn.width = 250
        let stateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state"))
        stateColumn.title = "Status"
        stateColumn.width = 310
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(stateColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.rowHeight = 24

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        connectButton.target = self; connectButton.action = #selector(connectPressed)
        connectButton.keyEquivalent = "\r"
        pairButton.target = self; pairButton.action = #selector(pairPressed)
        forgetButton.target = self; forgetButton.action = #selector(forgetPressed)
        retryButton.target = self; retryButton.action = #selector(retryPressed)
        recording.target = self; recording.action = #selector(recordingPressed)
        accessibility.target = self; accessibility.action = #selector(accessibilityPressed)
        let localNetwork = NSButton(title: "Local Network settings…", target: self, action: #selector(networkPressed))

        let permissionButtons = NSStackView(views: [recording, accessibility, localNetwork])
        permissionButtons.orientation = .horizontal
        permissionButtons.spacing = 8

        let actions = NSStackView(views: [connectButton, pairButton, forgetButton, retryButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        let stack = NSStackView(views: [title, note, status, scroll, permissions, permissionButtons, actions])
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
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 150),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Pair Receiver Token…", action: #selector(pairPressed), keyEquivalent: "p")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit LOCachy Extended Display", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApplication.shared.mainMenu = menu
        rebuildRows()
    }

    func applicationDidBecomeActive(_ notification: Notification) { refreshPermissions() }
    func windowDidBecomeKey(_ notification: Notification) { refreshPermissions() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApplication.shared.setActivationPolicy(.regular)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationShouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        permissionTimer?.invalidate()
        permissionTimer = nil
        if sessions.isEmpty {
            discovery.stop()
            watcher.stop()
            InputCoordinator.shared.shutdown()
            return .terminateNow
        }
        terminating = true
        for session in sessions.values {
            session.sender.stop()
        }
        // Safety timeout: reply even if a session never reports its end.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.replyToTerminate()
        }
        return .terminateLater
    }

    private func replyToTerminate() {
        guard !terminateReplied else { return }
        terminateReplied = true
        InputCoordinator.shared.shutdown()
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }

    // MARK: - Table Data Source & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < rows.count else { return nil }
        let item = rows[row]
        let id = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("cell")
        let cell: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            cell = reused
        } else {
            cell = NSTextField(labelWithString: "")
            cell.identifier = id
            cell.lineBreakMode = .byTruncatingTail
        }
        if id.rawValue == "receiver" {
            let name = item.choice?.name ?? item.storedPeer?.displayName ?? item.key
            if let link = item.choice?.link.name {
                cell.stringValue = "\(name) (\(link))"
            } else {
                cell.stringValue = "\(name) (offline)"
            }
            cell.textColor = item.choice == nil && item.session == nil ? .secondaryLabelColor : .labelColor
        } else {
            cell.stringValue = rowStatusText(item)
            if item.authFailed || item.lastError != nil {
                cell.textColor = .systemRed
            } else if let state = item.session?.state, case .active = state {
                cell.textColor = .systemGreen
            } else {
                cell.textColor = .secondaryLabelColor
            }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let idx = tableView.selectedRow
        selectedKey = (idx >= 0 && idx < rows.count) ? rows[idx].key : nil
        render()
    }

    private func rowStatusText(_ item: RowItem) -> String {
        if let session = item.session {
            switch session.state {
            case .connecting:
                return session.usingStoredCredential ? "Connecting (paired)…" : "Connecting…"
            case .active(let label):
                return session.usingStoredCredential ? "Active — \(label) (paired)" : "Active — \(label)"
            }
        }
        if item.authFailed {
            return "Authentication rejected — Re-pair required"
        }
        if let err = item.lastError {
            return err
        }
        if let choice = item.choice {
            if choice.pairedOnly && item.storedPeer == nil {
                return "Pairing required — click Pair…"
            }
            if item.storedPeer != nil {
                return "Paired — ready"
            }
            return "Discovered — ready"
        }
        return "Paired (not connected)"
    }

    private func rebuildRows() {
        var byKey: [String: RowItem] = [:]
        let storedPeers = Dictionary(peerStore.all().map { ($0.hostID, $0) }, uniquingKeysWith: { first, _ in first })

        // Active sessions first
        for (key, session) in sessions {
            let peer = session.choice.hostID.flatMap { storedPeers[$0] } ?? storedPeers[key]
            byKey[key] = RowItem(
                key: key,
                choice: choices.first(where: { $0.peerKey == key }) ?? session.choice,
                storedPeer: peer,
                session: session,
                authFailed: false,
                lastError: nil
            )
        }
        // Discovered receivers
        for choice in choices {
            let key = choice.peerKey
            guard byKey[key] == nil else { continue }
            let peer = choice.hostID.flatMap { storedPeers[$0] }
            byKey[key] = RowItem(
                key: key,
                choice: choice,
                storedPeer: peer,
                session: nil,
                authFailed: authFailedKeys.contains(key),
                lastError: sessionErrors[key]
            )
        }
        // Offline stored peers so user can inspect or forget them
        for (hostID, peer) in storedPeers where byKey[hostID] == nil {
            byKey[hostID] = RowItem(
                key: hostID,
                choice: nil,
                storedPeer: peer,
                session: nil,
                authFailed: authFailedKeys.contains(hostID),
                lastError: nil
            )
        }

        rows = byKey.values.sorted { lhs, rhs in
            let lRank = lhs.session != nil ? 0 : (lhs.choice != nil ? 1 : 2)
            let rRank = rhs.session != nil ? 0 : (rhs.choice != nil ? 1 : 2)
            if lRank != rRank { return lRank < rRank }
            let lName = lhs.choice?.name ?? lhs.storedPeer?.displayName ?? lhs.key
            let rName = rhs.choice?.name ?? rhs.storedPeer?.displayName ?? rhs.key
            if lName != rName { return lName < rName }
            return lhs.key < rhs.key
        }

        if let current = selectedKey, !rows.contains(where: { $0.key == current }) {
            selectedKey = nil
        }
        if selectedKey == nil, rows.count == 1 {
            selectedKey = rows[0].key
        }
        if window != nil {
            tableView.reloadData()
            if let current = selectedKey, let idx = rows.firstIndex(where: { $0.key == current }) {
                tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            }
        }
        render()
    }

    private func refreshPermissions() {
        guard window != nil else { return }
        let state = PermissionState.current()
        permissions.stringValue = state.explanation
        recording.isEnabled = !state.screenRecording
        accessibility.isEnabled = !state.accessibility
        render()
    }

    private func render() {
        guard window != nil else { return }
        let activeCount = sessions.values.filter {
            if case .active = $0.state { return true }
            return false
        }.count
        let connectingCount = sessions.count - activeCount

        if let problem {
            status.stringValue = problem
            status.textColor = .systemRed
        } else if !authFailedKeys.isEmpty {
            status.stringValue = "A paired receiver rejected its stored credential. Select it and click Pair… to re-pair."
            status.textColor = .systemRed
        } else if activeCount > 0 {
            let noun = activeCount == 1 ? "display" : "displays"
            let extra = connectingCount > 0 ? " (\(connectingCount) connecting…)" : ""
            status.stringValue = "\(activeCount) \(noun) connected\(extra). Arrangement and scaling are in System Settings → Displays."
            status.textColor = .labelColor
        } else if connectingCount > 0 {
            status.stringValue = "Connecting to \(connectingCount) LOCachy receiver\(connectingCount == 1 ? "" : "s")…"
            status.textColor = .labelColor
        } else if choices.isEmpty {
            status.stringValue = linkMessage.isEmpty ? "Waiting for a Thunderbolt/USB4 link to LOCachy…" : linkMessage
            status.textColor = .labelColor
        } else {
            let needsPairCount = choices.filter { choice in
                choice.pairedOnly && (choice.hostID.flatMap { peerStore.lookup(hostID: $0) } == nil)
            }.count
            if needsPairCount == choices.count {
                status.stringValue = "Paired-only receiver found. Click Pair… and paste the token from LOCachy."
            } else {
                status.stringValue = "\(choices.count) receiver\(choices.count == 1 ? "" : "s") found on Thunderbolt."
            }
            status.textColor = .labelColor
        }

        let selectedRow = selectedKey.flatMap { key in rows.first(where: { $0.key == key }) }
        if let row = selectedRow {
            if row.session != nil {
                connectButton.title = "Disconnect"
                connectButton.isEnabled = true
            } else if let choice = row.choice {
                if choice.pairedOnly && row.storedPeer == nil {
                    connectButton.title = "Connect"
                    connectButton.isEnabled = false
                } else {
                    connectButton.title = "Connect"
                    connectButton.isEnabled = true
                }
            } else {
                connectButton.title = "Connect"
                connectButton.isEnabled = false
            }
            forgetButton.isEnabled = row.storedPeer != nil
        } else {
            connectButton.title = "Connect"
            connectButton.isEnabled = false
            forgetButton.isEnabled = false
        }
        pairButton.isEnabled = true
        retryButton.isEnabled = true
    }

    // MARK: - Auto-connect & Session Management

    private func autoConnectEligible() {
        guard !terminating else { return }
        for choice in choices {
            let key = choice.peerKey
            guard sessions[key] == nil,
                  !authFailedKeys.contains(key),
                  !manuallyDisconnectedKeys.contains(key) else { continue }
            if let hostID = choice.hostID, let stored = peerStore.lookup(hostID: hostID) {
                let attemptSig = "\(choice.id)|\(stored.identity)|\(stored.pskBase32)"
                guard lastAutoTriedStored[key] != attemptSig else { continue }
                lastAutoTriedStored[key] = attemptSig
                startSession(for: choice, storedPeer: stored, rememberOnActive: false)
            } else if let code = choice.code {
                guard lastAutoTriedCode[key] != code else { continue }
                lastAutoTriedCode[key] = code
                startSession(for: choice, storedPeer: nil, rememberOnActive: false)
            } else if choice.pairedOnly {
                // Paired-only receiver without stored credentials: show window so user can pair.
                if !window.isVisible && sessions.isEmpty {
                    showSetupWindow()
                }
            }
        }
    }

    private func startSession(for choice: ReceiverChoice, storedPeer: StoredPeer?, rememberOnActive: Bool) {
        let key = choice.peerKey
        guard sessions[key] == nil else { return }
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        do {
            try LinkInterfaces.require(choice.link.name, index: choice.link.index)
            let identity: String
            let codeText: String
            let usingStored: Bool
            if let storedPeer {
                identity = storedPeer.identity
                codeText = storedPeer.pskBase32
                usingStored = true
            } else if let advertisedCode = choice.code {
                identity = Wire.identity
                codeText = advertisedCode
                usingStored = false
            } else {
                throw SenderError("This receiver requires pairing first. Click Pair… and paste its pairing token.")
            }

            var secretKey = try PeerStore.decodePSK(codeText)
            defer { secretKey.resetBytes(in: 0..<secretKey.count) }
            let endpoint = try CableEndpoint(host: choice.address, port: choice.port, interface: choice.link.name)
            guard endpoint.interfaceIndex == choice.link.index else {
                throw SenderError("The Thunderbolt interface changed.")
            }
            let sender = try Sender(
                endpoint: endpoint,
                key: secretKey,
                identity: identity,
                discoveredHostID: choice.hostID,
                inputCoordinator: .shared
            )
            secretKey.resetBytes(in: 0..<secretKey.count)

            // A receiver-issued credential is stored only when the person asked to
            // remember this receiver (Pair… / Remember Selected). It is then kept
            // pending until the session is active, which is the point where the
            // hello has been accepted over the TLS-authenticated channel.
            sender.onPairGrant = { [weak self] grantHostID, _, grantIdentity, grantCode in
                guard let self, var active = self.sessions[key], active.rememberOnActive,
                      active.choice.hostID == grantHostID else { return }
                active.pendingIdentity = grantIdentity
                active.pendingCode = grantCode
                self.sessions[key] = active
            }

            sender.onActive = { [weak self] panel in
                guard let self, var active = self.sessions[key] else { return }
                active.state = .active(panel.displayLabel)
                if active.rememberOnActive,
                   let hostID = panel.hostID ?? active.choice.hostID,
                   let saveIdentity = active.pendingIdentity,
                   let saveCode = active.pendingCode {
                    let stamp = ISO8601DateFormatter().string(from: Date())
                    let peer = StoredPeer(
                        hostID: hostID,
                        displayName: panel.displayLabel,
                        identity: saveIdentity,
                        pskBase32: saveCode,
                        createdAt: stamp,
                        lastUsedAt: stamp
                    )
                    try? self.peerStore.save(peer)
                    active.rememberOnActive = false
                    active.pendingIdentity = nil
                    active.pendingCode = nil
                } else if active.usingStoredCredential, let hostID = panel.hostID ?? active.choice.hostID {
                    self.peerStore.touchLastUsed(hostID: hostID, displayName: panel.displayLabel)
                }
                self.sessions[key] = active
                self.sessionErrors.removeValue(forKey: key)
                self.authFailedKeys.remove(key)
                self.problem = nil
                self.rebuildRows()
                if self.authFailedKeys.isEmpty && PermissionState.current().ready {
                    self.window.orderOut(nil)
                    NSApplication.shared.setActivationPolicy(.accessory)
                }
            }

            sender.onEnd = { [weak self] reason, _, authFailed in
                self?.ended(for: key, reason: reason, authFailed: authFailed)
            }

            sessions[key] = ActiveSession(
                key: key,
                sender: sender,
                choice: choice,
                state: .connecting,
                usingStoredCredential: usingStored,
                rememberOnActive: rememberOnActive,
                // Never persist an ephemeral one-shot attempt code (Wire.identity);
                // only a receiver-issued persistent pairGrant or imported token is stored.
                pendingIdentity: nil,
                pendingCode: nil
            )
            sessionErrors.removeValue(forKey: key)
            problem = nil
            rebuildRows()
            sender.run()
        } catch {
            sessionErrors[key] = String(describing: error)
            rebuildRows()
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

    private func ended(for key: String, reason: String, authFailed: Bool) {
        let removed = sessions.removeValue(forKey: key)
        if terminating {
            if sessions.isEmpty {
                discovery.stop()
                watcher.stop()
                replyToTerminate()
            }
            return
        }

        if reason.contains("-3801") {
            resetStaleScreenCaptureTCC()
            _ = CGRequestScreenCaptureAccess()
            problem = "Allow Screen Recording for LOCachy Extended Display in System Settings → Privacy & Security."
            showSetupWindow()
        } else if authFailed {
            authFailedKeys.insert(key)
            if removed?.usingStoredCredential == true {
                sessionErrors[key] = "Stored credential rejected — click Pair… to re-pair"
                showSetupWindow()
            } else {
                sessionErrors[key] = "Pairing code rejected"
            }
        } else if reason != "Stopped by the Mac" && reason != "Receiver ended the session" {
            sessionErrors[key] = reason
        } else {
            sessionErrors.removeValue(forKey: key)
        }

        rebuildRows()
        if !authFailed && !manuallyDisconnectedKeys.contains(key) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, !self.terminating, self.sessions[key] == nil,
                      !self.authFailedKeys.contains(key),
                      !self.manuallyDisconnectedKeys.contains(key) else { return }
                self.lastAutoTriedCode.removeValue(forKey: key)
                self.lastAutoTriedStored.removeValue(forKey: key)
                self.autoConnectEligible()
            }
        }
    }

    // MARK: - Actions

    @objc private func connectPressed() {
        guard let key = selectedKey, let row = rows.first(where: { $0.key == key }) else { return }
        if let active = row.session {
            manuallyDisconnectedKeys.insert(key)
            active.sender.stop()
            return
        }
        guard let choice = row.choice else { return }
        manuallyDisconnectedKeys.remove(key)
        authFailedKeys.remove(key)
        sessionErrors.removeValue(forKey: key)
        let stored = choice.hostID.flatMap { peerStore.lookup(hostID: $0) }
        if stored == nil && choice.pairedOnly {
            pairPressed()
            return
        }
        startSession(for: choice, storedPeer: stored, rememberOnActive: false)
    }

    @objc private func pairPressed() {
        let alert = NSAlert()
        alert.messageText = "Pair LOCachy Receiver"
        alert.informativeText = "Paste the pairing token or URI shown by LOCachy (locachy-pair://v1?… or locachy-pair-v1:…)."
        alert.addButton(withTitle: "Save Token")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "locachy-pair://v1?host=…&id=…&code=…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let rawToken = field.stringValue
        do {
            let peer = try PeerStore.parsePairingToken(rawToken)
            try peerStore.save(peer)
            authFailedKeys.remove(peer.hostID)
            manuallyDisconnectedKeys.remove(peer.hostID)
            sessionErrors.removeValue(forKey: peer.hostID)
            lastAutoTriedStored.removeValue(forKey: peer.hostID)
            problem = nil
            selectedKey = peer.hostID
            rebuildRows()
            if let matchingChoice = choices.first(where: { $0.hostID == peer.hostID || $0.peerKey == peer.hostID }) {
                if let active = sessions[matchingChoice.peerKey] {
                    // Stopping triggers ended(for:) which schedules autoConnectEligible()
                    // with the newly saved stored credential once teardown finishes.
                    active.sender.stop()
                } else {
                    startSession(for: matchingChoice, storedPeer: peer, rememberOnActive: false)
                }
            }
        } catch {
            problem = String(describing: error)
            render()
        }
    }

    @objc private func forgetPressed() {
        guard let key = selectedKey,
              let row = rows.first(where: { $0.key == key }),
              let stored = row.storedPeer else { return }
        _ = peerStore.remove(hostID: stored.hostID)
        authFailedKeys.remove(key)
        authFailedKeys.remove(stored.hostID)
        lastAutoTriedStored.removeValue(forKey: key)
        lastAutoTriedStored.removeValue(forKey: stored.hostID)
        sessionErrors.removeValue(forKey: key)
        rebuildRows()
    }

    @objc private func retryPressed() {
        problem = nil
        authFailedKeys.removeAll()
        manuallyDisconnectedKeys.removeAll()
        sessionErrors.removeAll()
        lastAutoTriedCode.removeAll()
        lastAutoTriedStored.removeAll()
        refreshPermissions()
        watcher.refresh()
        autoConnectEligible()
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
