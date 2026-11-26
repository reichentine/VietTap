//
//  Settings.swift
//  VietTap
//
//  The Settings window, the switch key recorder, the menu bar icon and the
//  switch sound.
//

import SwiftUI
import Carbon

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            LabeledContent("Switch input:") { ShortcutField(model: model) }
            Toggle("Play a sound when switching",
                   isOn: Binding(get: { model.playSound }, set: model.setPlaySound))
                .padding(.bottom, 6)
            Toggle("Check spelling",
                   isOn: Binding(get: { model.spelling }, set: model.setSpelling))
            Toggle("Remember the input for each app",
                   isOn: Binding(get: { model.smartSwitch }, set: model.setSmartSwitch))
            Toggle("Open at login",
                   isOn: Binding(get: { model.openAtLogin }, set: model.setOpenAtLogin))
            LabeledContent("") {
                Text("Telex · Unicode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
        .fixedSize()
    }
}

// MARK: - Switch key

/// OpenKey hotkey format: bits 0-7 key code (0xFE = modifiers only),
/// 0x100 Control, 0x200 Option, 0x400 Command, 0x800 Shift,
/// bits 24-31 the key's character (for display).
enum HotKey {
    static let controlShift = Int32(bitPattern: 0xFE00_09FE)

    /// "⌃⇧", "⌥Z", ...
    static func display(_ hotKey: Int32) -> String {
        var s = ""
        if hotKey & 0x100 != 0 { s += "⌃" }
        if hotKey & 0x200 != 0 { s += "⌥" }
        if hotKey & 0x800 != 0 { s += "⇧" }
        if hotKey & 0x400 != 0 { s += "⌘" }
        if hotKey & 0xFF != 0xFE {
            let c = UInt8((hotKey >> 24) & 0xFF)
            if c == 0x20 { s += "Space" }
            else if c > 0x20 { s += String(UnicodeScalar(c)) }
            else { s += "Key \(hotKey & 0xFF)" }
        }
        return s.isEmpty ? "None" : s
    }

    static func modifierBits(_ m: NSEvent.ModifierFlags) -> Int32 {
        var bits: Int32 = 0
        if m.contains(.control) { bits |= 0x100 }
        if m.contains(.option) { bits |= 0x200 }
        if m.contains(.command) { bits |= 0x400 }
        if m.contains(.shift) { bits |= 0x800 }
        return bits
    }
}

/// A button that records the switch key. Click it, then press a modifier
/// combination (for example Control+Shift, then release) or a modifier plus
/// a key (for example Option+Z). Escape cancels.
struct ShortcutField: View {
    @ObservedObject var model: AppModel
    @StateObject private var recorder = ShortcutRecorder()

    var body: some View {
        Button {
            if recorder.isRecording { recorder.stop() } else { recorder.start { model.setHotKey($0) } }
        } label: {
            Text(recorder.isRecording ? "Type shortcut…" : HotKey.display(model.hotKey))
                .frame(minWidth: 96)
        }
        .help("Click, then press the new shortcut. Press Escape to cancel.")
        .onDisappear { recorder.stop() }
    }
}

final class ShortcutRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var peakModifiers: NSEvent.ModifierFlags = []
    private var onChange: ((Int32) -> Void)?
    private static let recorded: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    func start(onChange: @escaping (Int32) -> Void) {
        self.onChange = onChange
        isRecording = true
        peakModifiers = []
        VTHookSetPaused(true) // keep the current shortcut from switching meanwhile
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handle(event)
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: NSApp.keyWindow, queue: .main
        ) { [weak self] _ in self?.stop() }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        VTHookSetPaused(false)
    }

    private func finish(keyCode: Int32, character: Int32, modifiers: NSEvent.ModifierFlags) {
        let value = (character & 0xFF) << 24 | HotKey.modifierBits(modifiers) | (keyCode & 0xFF)
        stop()
        onChange?(value)
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(Self.recorded)
        if event.type == .flagsChanged {
            if !mods.isEmpty {
                peakModifiers.formUnion(mods)
            } else {
                // All modifiers released without a key: a modifier-only shortcut.
                // Require two modifiers, so that a single Shift tap never switches.
                if peakModifiers.rawValue.nonzeroBitCount >= 2 {
                    finish(keyCode: 0xFE, character: 0xFE, modifiers: peakModifiers)
                }
                peakModifiers = []
            }
            return
        }
        if event.keyCode == UInt16(kVK_Escape) && mods.isEmpty {
            stop()
            return
        }
        let c = event.charactersIgnoringModifiers?.uppercased().unicodeScalars.first?.value ?? 0
        guard !mods.isEmpty, (0x20...0x7E).contains(c) else {
            NSSound.beep() // needs a modifier and a plain key
            return
        }
        finish(keyCode: Int32(event.keyCode), character: Int32(c), modifiers: mods)
    }
}

// MARK: - Menu bar icon

enum StatusIcon {
    /// The SF Symbols "v.square" (Vietnamese) and "e.square" (English).
    /// Template images: macOS colors them for the menu bar. A dimmed icon
    /// (paused, or no Accessibility access) is drawn at lower opacity.
    static func image(vietnamese: Bool, dimmed: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular, scale: .large)
        guard let symbol = NSImage(systemSymbolName: vietnamese ? "v.square" : "e.square",
                                   accessibilityDescription: vietnamese ? "Vietnamese" : "English")?
            .withSymbolConfiguration(config) else { return NSImage() }
        guard dimmed else { return symbol }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.35)
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - Switch sound

/// macOS "Tink" when Vietnamese turns on, "Pop" when English turns on.
enum SwitchSound {
    private static let volume: Float = 0.35 // softer than a normal alert
    private static var vietnamese: NSSound?
    private static var english: NSSound?

    /// Loads both sounds and warms up audio output, so that the first switch
    /// does not wait for the audio device. Call once at launch.
    static func prepare() {
        vietnamese = NSSound(named: "Tink")?.copy() as? NSSound
        english = NSSound(named: "Pop")?.copy() as? NSSound
        vietnamese?.volume = 0
        vietnamese?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            vietnamese?.stop()
            vietnamese?.volume = volume
            english?.volume = volume
        }
    }

    /// language: 1 Vietnamese, 0 English. Returns immediately.
    static func play(language: Int) {
        let sound = language == 1 ? vietnamese : english
        let other = language == 1 ? english : vietnamese
        other?.stop()
        sound?.stop() // restart if it is still playing
        sound?.play()
    }
}
