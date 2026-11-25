//
//  AppModel.swift
//  VietTap (Swift beta)
//
//  App state and everything around the hook: settings, Accessibility,
//  input source, workspace notifications and the login item.
//  The hook calls back on the main thread (its tap is on the main run loop),
//  and so does every notification and timer here.
//

import AppKit
import Carbon
import ServiceManagement
import os

private let log = Logger(subsystem: "com.sonvu.viettap.beta", category: "app")

enum Pref {
    static let language = "InputMethod"          // 0 English, 1 Vietnamese
    static let switchKey = "SwitchKeyStatus"     // OpenKey hotkey format
    static let spelling = "Spelling"
    static let smartSwitch = "UseSmartSwitchKey" // remember language per app
    static let openAtLogin = "RunOnStartup"
    static let smartData = "smartSwitchKey"      // per-app data blob
    static let switchSound = "PlaySwitchSound"
    static let imported = "ImportedSettings"
}

final class AppModel: NSObject, ObservableObject {
    static let shared = AppModel()
    static let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "VietTap"
    /// The Objective-C VietTap. Both apps must never hook the keyboard at once.
    static let otherAppID = "com.sonvu.viettap"

    @Published private(set) var running = false
    @Published private(set) var inputSourcePaused = false
    @Published private(set) var vietnamese = true
    @Published private(set) var otherAppIsRunning = false
    @Published private(set) var hotKey = HotKey.controlShift
    @Published private(set) var playSound = true
    @Published private(set) var spelling = true
    @Published private(set) var smartSwitch = true
    @Published private(set) var openAtLogin = false

    private var pausingSourceName = ""
    private var pausingSourceIsVietnamese = false
    private var permissionTimer: Timer?
    private var watchdog: Timer?
    private let defaults = UserDefaults.standard

    // MARK: - Launch

    func launch() {
        registerDefaults()
        importSettingsIfNeeded()
        loadSettings()

        VTEngineInit()
        VTSetLanguageObserver { [weak self] in self?.refresh() }
        SwitchSound.prepare()
        VTSetHotKeySwitchObserver { [weak self] language in
            if self?.playSound == true { SwitchSound.play(language: Int(language)) }
        }

        observeWorkspace()
        observeInputSource()
        applyOpenAtLoginPreference()
        startHookIfPossible()
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Pref.language: 1,
            Pref.switchKey: Int(HotKey.controlShift),
            Pref.spelling: true,
            Pref.smartSwitch: true,
            Pref.openAtLogin: false, // a beta never adds itself to login items
            Pref.switchSound: true,
        ])
    }

    /// On the first launch, take over the settings of VietTap, or else of
    /// OpenKey. "Open at login" is not copied.
    private func importSettingsIfNeeded() {
        guard !defaults.bool(forKey: Pref.imported) else { return }
        defaults.set(true, forKey: Pref.imported)
        let keys = [Pref.language, Pref.switchKey, Pref.spelling, Pref.smartSwitch,
                    Pref.smartData, Pref.switchSound]
        for suite in [Self.otherAppID, "com.tuyenmai.openkey"] {
            guard let source = UserDefaults(suiteName: suite),
                  source.object(forKey: Pref.switchKey) != nil else { continue }
            for key in keys {
                if let value = source.object(forKey: key) { defaults.set(value, forKey: key) }
            }
            log.info("imported settings from \(suite, privacy: .public)")
            return
        }
    }

    private func loadSettings() {
        hotKey = Int32(truncatingIfNeeded: defaults.integer(forKey: Pref.switchKey))
        playSound = defaults.bool(forKey: Pref.switchSound)
        spelling = defaults.bool(forKey: Pref.spelling)
        smartSwitch = defaults.bool(forKey: Pref.smartSwitch)
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Hook

    /// otherAppQuit: VietTap just quit. At that moment it can still be in the
    /// list of running apps, so do not look it up.
    private func startHookIfPossible(otherAppQuit: Bool = false) {
        otherAppIsRunning = !otherAppQuit && NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.otherAppID)
            .contains { !$0.isTerminated }
        if otherAppIsRunning {
            log.info("VietTap is open, the hook waits")
            refresh()
        } else if AXIsProcessTrusted() {
            startHook()
        } else {
            refresh()
            openAccessibilitySettings()
        }
    }

    private func startHook() {
        guard VTHookStart() else {
            log.error("event tap could not start, waiting for Accessibility")
            openAccessibilitySettings()
            return
        }
        log.info("keyboard hook running")
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in VTHookWatchdog() }
        watchdog?.tolerance = 1
        refresh()
    }

    func quitOtherApp() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.otherAppID)
            .forEach { $0.terminate() }
    }

    // MARK: - Accessibility

    /// Shows the macOS prompt (it also adds the app to the Accessibility list),
    /// opens the Accessibility page, and starts the hook when access is on.
    func openAccessibilitySettings() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self, AXIsProcessTrusted() else { return }
            timer.invalidate()
            self.permissionTimer = nil
            if !self.otherAppIsRunning { self.startHook() }
        }
    }

    // MARK: - State shown in the menu bar

    func refresh() {
        running = VTHookIsRunning()
        inputSourcePaused = VTHookIsInputSourcePaused()
        vietnamese = VTGetLanguage() == 1
    }

    func toggleLanguage() { VTToggleLanguage() }

    var statusImage: NSImage {
        // While an input method pauses the hook, show its language, so that
        // typing Vietnamese with another input method does not show E.
        StatusIcon.image(vietnamese: inputSourcePaused ? pausingSourceIsVietnamese : (vietnamese && running),
                         dimmed: !running || inputSourcePaused)
    }

    var statusText: String {
        if otherAppIsRunning { return "\(Self.appName): paused while VietTap is open" }
        if !running { return "\(Self.appName): needs Accessibility access" }
        if inputSourcePaused { return "\(Self.appName): paused while \(pausingSourceName) is selected" }
        return "\(Self.appName): \(vietnamese ? "Vietnamese" : "English")"
    }

    var languageSubtitle: String {
        inputSourcePaused ? "Paused: \(pausingSourceName) is selected" : "Switch: \(HotKey.display(hotKey))"
    }

    // MARK: - Settings

    func setHotKey(_ value: Int32) {
        VTSetSwitchKey(value)
        hotKey = value
    }

    func setPlaySound(_ on: Bool) {
        defaults.set(on, forKey: Pref.switchSound)
        playSound = on
        if on { SwitchSound.play(language: Int(VTGetLanguage())) } // a sample
    }

    func setSpelling(_ on: Bool) {
        VTSetSpelling(on)
        spelling = on
    }

    func setSmartSwitch(_ on: Bool) {
        VTSetSmartSwitch(on)
        smartSwitch = on
    }

    func setOpenAtLogin(_ on: Bool) {
        defaults.set(on, forKey: Pref.openAtLogin)
        changeLoginItem(on)
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Login item

    private func changeLoginItem(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on && service.status != .enabled { try service.register() }
            if !on && service.status == .enabled { try service.unregister() }
        } catch {
            log.error("login item change failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The "Open at login" setting decides. If the user turned the item off in
    /// System Settings, the status is "requires approval" and stays so.
    private func applyOpenAtLoginPreference() {
        let wanted = defaults.bool(forKey: Pref.openAtLogin)
        let status = SMAppService.mainApp.status
        if wanted && status != .enabled && status != .requiresApproval { changeLoginItem(true) }
        if !wanted && status == .enabled { changeLoginItem(false) }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Input source

    /// Pause while a macOS input method is selected, so that a key is never
    /// converted twice. A plain keyboard layout (ABC, U.S., ...) resumes.
    private func observeInputSource() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(inputSourceChanged(_:)),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately)
        checkInputSource()
    }

    @objc private func inputSourceChanged(_ note: Notification) {
        checkInputSource()
        // The notice can come a moment before the new input is active.
        for delay in [0.2, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.checkInputSource() }
        }
    }

    private func checkInputSource() {
        var isLayout = true
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() {
            let type: String? = source.property(kTISPropertyInputSourceType)
            isLayout = type == nil || type == (kTISTypeKeyboardLayout as String)
            pausingSourceName = source.property(kTISPropertyLocalizedName) ?? ""
            let sourceID: String = source.property(kTISPropertyInputSourceID) ?? ""
            let languages: [String] = source.property(kTISPropertyInputSourceLanguages) ?? []
            if sourceID.hasPrefix("com.sonvu.inputmethod.GoTiengViet.") {
                pausingSourceIsVietnamese = sourceID.hasSuffix(".vi")
            } else {
                pausingSourceIsVietnamese = languages.first == "vi"
            }
        }
        if isLayout == VTHookIsInputSourcePaused() {
            log.info("\(isLayout ? "resumed" : "paused", privacy: .public) (input source: \(self.pausingSourceName, privacy: .public))")
        }
        VTHookSetInputSourcePaused(!isLayout)
        refresh()
    }

    // MARK: - Workspace

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            VTActiveAppChanged(app?.bundleIdentifier)
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            VTRequestNewSession()
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Create the tap again after sleep, as OpenKey did.
            guard let self, AXIsProcessTrusted(), !self.otherAppIsRunning else { return }
            VTHookStop()
            self.startHook()
        }
        // Start or stop the hook when the Objective-C VietTap quits or opens.
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, Self.isOtherApp(note) else { return }
            self.startHookIfPossible(otherAppQuit: true)
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, Self.isOtherApp(note) else { return }
            VTHookStop()
            self.otherAppIsRunning = true
            self.refresh()
        }
    }

    private static func isOtherApp(_ note: Notification) -> Bool {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier == otherAppID
    }
}

private extension TISInputSource {
    func property<T>(_ key: CFString) -> T? {
        guard let pointer = TISGetInputSourceProperty(self, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? T
    }
}
