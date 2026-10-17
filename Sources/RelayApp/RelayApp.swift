import AppKit
import SwiftUI

@main
struct RelayApp: App {
    @NSApplicationDelegateAdaptor(RelayAppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Relay", id: "transfer") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 700, minHeight: 590)
                .onAppear { delegate.model = model }
                .onOpenURL { model.addFiles([$0]) }
        }
        .defaultSize(width: 800, height: 680)
        .defaultPosition(.center)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Transfer", action: model.newTransfer)
                    .keyboardShortcut("n")
                    .disabled(model.isTransferring)
                Button("Add Files…", action: model.chooseFiles)
                    .keyboardShortcut("o")
                    .disabled(model.isTransferring)
                Button("Choose Destination…", action: model.chooseDestination)
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.isTransferring)
            }
            CommandGroup(replacing: .help) {
                Button("Show Verification Receipts", action: model.showReceipts)
            }
        }
    }
}

@MainActor
final class RelayAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if !model.isTransferring {
            model.stopBeforeQuitting { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        let alert = NSAlert()
        alert.messageText = "A transfer is in progress"
        alert.informativeText = "Relay can stop safely before quitting. Verified copies will be kept."
        alert.addButton(withTitle: "Keep Transferring")
        alert.addButton(withTitle: "Stop and Quit")
        if alert.runModal() == .alertSecondButtonReturn {
            model.stopBeforeQuitting { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
