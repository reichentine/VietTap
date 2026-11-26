//
//  VietTapApp.swift
//  VietTap
//
//  The app in SwiftUI: a menu bar extra and a Settings window. The keyboard
//  hook (KeyHook.mm) and the OpenKey engine are in Objective-C++ and C++;
//  Swift calls them through VTHook.h.
//

import SwiftUI

@main
struct VietTapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(nsImage: model.statusImage)
                .accessibilityLabel(model.statusText)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.launch()
    }
}

/// The menu of the menu bar icon.
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.otherAppIsRunning {
            Text("Paused: \(model.otherAppName) is open")
            Button("Quit \(model.otherAppName)") { model.quitOtherApp() }
            Divider()
        } else if !model.running {
            Button("Allow Accessibility Access…") { model.openAccessibilitySettings() }
            Divider()
        }

        Toggle(isOn: Binding(get: { model.vietnamese },
                             set: { _ in model.toggleLanguage() })) {
            Text("Vietnamese")
            Text(model.languageSubtitle)
        }
        .disabled(!model.running || model.inputSourcePaused)

        Divider()
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit \(AppModel.appName)") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
