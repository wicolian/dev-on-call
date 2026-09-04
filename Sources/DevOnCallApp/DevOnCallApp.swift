import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var testWindow: NSWindow?
    private var testModel: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isUITest = CommandLine.arguments.contains("--ui-test-window")
            || CommandLine.arguments.contains("--ui-test-settings")
        NSApp.setActivationPolicy(isUITest ? .regular : .accessory)
        guard isUITest else {
            LaunchAtLoginController.enableByDefaultOnce()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showTestWindow()
        }
    }

    private func showTestWindow() {
        let model = AppModel()
        model.preferences.soundEnabled = false
        model.preferences.speechEnabled = false
        model.preferences.systemNotificationsEnabled = false
        let showSettings = CommandLine.arguments.contains("--ui-test-settings")
        let size = showSettings ? NSSize(width: 720, height: 520) : NSSize(width: 404, height: 526)
        let rootView = showSettings
            ? AnyView(SettingsView(model: model))
            : AnyView(MenuPanel(model: model))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = showSettings ? "Dev On Call — Settings" : "Dev On Call — UI Test"
        window.contentView = NSHostingView(rootView: rootView)
        window.isReleasedWhenClosed = false
        window.center()
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        testWindow = window
        testModel = model

        if !showSettings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                model.triggerTest()
            }
        }
    }
}

@main
struct DevOnCallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: model.menuBarSymbol)
                Text("ON")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
            }
                .accessibilityLabel("Dev On Call — \(model.monitoringLabel)")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }

    }
}
