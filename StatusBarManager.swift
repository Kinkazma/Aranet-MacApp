//
//  StatusBarManager.swift
//  Aranet4MacApp
//
//  Created by Gael Dauchy on 25/10/2025.
//  Copyright © 2025 Aranet4Mac. All rights reserved.
//

import AppKit
import SwiftUI

@MainActor
final class StatusBarManager: NSObject {
    static let shared = StatusBarManager()

    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var settingsPopover: NSPopover?
    private var mainPopover: NSPopover?

    private lazy var popStorage = HistoryStorage()
    private lazy var popService: Aranet4Service = {
        let s = Aranet4Service()
        s.storage = popStorage
        return s
    }()
    private lazy var popScheduler = Scheduler()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleAppActivated(_:)),
                                               name: NSApplication.didBecomeActiveNotification,
                                               object: nil)
    }

    private var dockWindow: NSWindow?

    @objc private func handleAppActivated(_ note: Notification) {
        // Only react if Dock is enabled
        let showDock = UserDefaults.standard.bool(forKey: "pref.showDock")
        guard showDock else { return }

        // If a popover is showing, don't spawn a window
        if (mainPopover?.isShown == true) || (settingsPopover?.isShown == true) { return }

        // If there is already any visible window, no need to create another
        if NSApp.windows.contains(where: { $0.isVisible }) { return }

        // Show or create the Dock window
        showDockWindow()
    }

    private func showDockWindow() {
        if let win = dockWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // Build a SwiftUI-hosted window using the same independent instances as the popover
        let hosting = NSHostingController(
            rootView: ContentView()
                .environmentObject(popStorage)
                .environmentObject(popService)
                .environmentObject(popScheduler)
        )
        let win = NSWindow(contentViewController: hosting)
        win.setContentSize(NSSize(width: 1024, height: 700))
        win.title = "Aranet4"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        dockWindow = win
    }

    @objc func applyPreferencesFromDefaults() {
        let defaults = UserDefaults.standard
        let showDock = defaults.bool(forKey: "pref.showDock")
        var showStatus = defaults.bool(forKey: "pref.showStatusItem")

        // Enforce invariant: at least one surface active
        if !showDock && !showStatus {
            // Par défaut, on réactive l’extension (barre de menus)
            showStatus = true
            defaults.set(true, forKey: "pref.showStatusItem")
        }

        // Apply Dock visibility
        let policy: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        NSApp.setActivationPolicy(policy)

        // Apply status item visibility
        setVisible(showStatus)
    }

    /// Affiche ou retire l'icône de barre de menus
    func setVisible(_ visible: Bool) {
        if visible {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                statusItem = item
                configureButton()
                rebuildMenu()
            }
        } else {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                settingsPopover?.close()
                mainPopover?.close()
                statusItem = nil
            }
        }
    }

    // MARK: - Setup

    private func configureButton() {
        guard let button = statusItem?.button else { return }

        // Icône / titre
        // Utilise notre icône personnalisée embarquée dans les ressources de l'application
        // On charge l'image nommée "MenuIcon" depuis le catalogue d'actifs. Si elle existe,
        // on l'utilise comme image de la barre de menus et on la marque comme template pour
        // que macOS l'adapte automatiquement au mode sombre ou clair. Si l'image ne peut
        // pas être trouvée, on retombe sur un titre texte minimaliste.
        if let image = NSImage(named: "MenuIcon") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "CO₂"
        }
        button.toolTip = "Aranet4 – Raccourcis"

        // Capter clic gauche & droit
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let openItem = NSMenuItem(title: "Ouvrir Aranet4", action: #selector(openMain), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        let prefsItem = NSMenuItem(title: "Réglages…", action: #selector(openSettings), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quitter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Click routing

    @objc private func handleStatusItemClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent, let button = statusItem?.button else {
            toggleMainPopover()
            return
        }
        // Clic droit (ou Ctrl‑clic) → menu contextuel
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem?.menu = menu     // attache temporairement
            button.performClick(nil)    // pop le menu
            statusItem?.menu = nil      // détache aussitôt
        } else {
            // Clic gauche → popover principal (contenu de la fenêtre), auto‑dismiss
            toggleMainPopover()
        }
    }

    // MARK: - Actions

    @objc private func openMain() {
        // Option pour ouvrir la fenêtre principale (si Dock actif)
        NSApp.activate(ignoringOtherApps: true)
        if let win = NSApp.windows.first {
            win.makeKeyAndOrderFront(nil)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    @objc private func openSettings() {
        showSettingsPopover()
    }

    /// Shows a transient popover with inline settings, anchored to the status bar button.
    private func showSettingsPopover() {
        guard let button = statusItem?.button else { return }

        // Toggle behavior: if already visible, close.
        if let pop = settingsPopover, pop.isShown {
            pop.performClose(nil)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient   // auto-close when clicking outside
        popover.animates = true

        // SwiftUI inline settings view that binds directly to @AppStorage keys
        let hosting = NSHostingController(rootView: InlineSettingsView())
        popover.contentViewController = hosting

        // Size of the popover content
        popover.contentSize = NSSize(width: 340, height: 160)

        settingsPopover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    /// Toggle the main quick panel popover that hosts the full ContentView (transient, auto-dismiss on outside click)
    private func toggleMainPopover() {
        guard let button = statusItem?.button else { return }

        if let pop = mainPopover, pop.isShown {
            pop.performClose(nil)
            return
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true

        let hosting = NSHostingController(
            rootView: ContentView()
                .environmentObject(popStorage)
                .environmentObject(popService)
                .environmentObject(popScheduler)
        )
        pop.contentViewController = hosting

        // Reasonable default size; the view will size itself
        pop.contentSize = NSSize(width: 900, height: 600)

        mainPopover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    /// Close both popovers explicitly (optional helper)
    private func closePopovers() {
        mainPopover?.performClose(nil)
        settingsPopover?.performClose(nil)
    }

    @objc func openSettingsFromInline(_ sender: Any?) {
        showSettingsPopover()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Inline Settings UI (SwiftUI inside the popover)
struct InlineSettingsView: View {
    @AppStorage("pref.showDock") private var showDock: Bool = true
    @AppStorage("pref.showStatusItem") private var showStatusItem: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Affichage").font(.headline)
            Toggle("Afficher dans le Dock", isOn: $showDock)
            Toggle("Afficher l’extension (barre de menus)", isOn: $showStatusItem)
            Text("Au moins une des deux options doit rester activée.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: showDock) { newValue in
            let defaults = UserDefaults.standard
            if !newValue && !showStatusItem {
                // Empêche l’état invalide: réactive l’extension
                showStatusItem = true
                defaults.set(true, forKey: "pref.showStatusItem")
            }
            StatusBarManager.shared.applyPreferencesFromDefaults()
        }
        .onChange(of: showStatusItem) { newValue in
            let defaults = UserDefaults.standard
            if !newValue && !showDock {
                // Empêche l’état invalide: réactive le Dock
                showDock = true
                defaults.set(true, forKey: "pref.showDock")
            }
            StatusBarManager.shared.applyPreferencesFromDefaults()
        }
        .onAppear {
            StatusBarManager.shared.applyPreferencesFromDefaults()
        }
    }
}

extension StatusBarManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let obj = notification.object as? NSWindow, obj == dockWindow {
            dockWindow = nil
        }
    }
}
