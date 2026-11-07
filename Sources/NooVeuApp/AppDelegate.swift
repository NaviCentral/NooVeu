import AppKit
import NooVeuCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Shared by every window, so a file open in two windows is decoded once.
    private let scheduler = DecodeScheduler()
    private var controllers: [ViewerWindowController] = []
    /// Where the next window's top-left goes, so windows cascade instead of stacking exactly.
    private var cascadePoint = NSPoint.zero
    private let launchProbe = LaunchProbe.isEnabled
    /// Empties the decode cache when the system runs short of memory.
    private var memoryPressure: DispatchSourceMemoryPressure?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [scheduler] in
            Task { await scheduler.purge() }
        }
        pressure.resume()
        memoryPressure = pressure

        // Files passed on the command line; Finder opens arrive through application(_:open:).
        let urls = CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        // A launch probe with nothing to show must still end, so scripts never hang.
        if launchProbe { LaunchProbe.armTimeout() }
        openWindows(for: urls)

        if controllers.isEmpty && !launchProbe {
            openDocument(nil)
            // Cancelling the open panel would leave a running app with no window.
            if controllers.isEmpty { NSApp.terminate(nil) }
        }
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openWindows(for: urls)
    }

    /// One window per folder, not per file: a window flips through its whole folder.
    private func openWindows(for urls: [URL]) {
        OpenPlan.windows(for: urls).forEach(openWindow)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .folder]
        panel.message = "Choose an image, or a folder of images"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWindow(for: url)
    }

    private func openWindow(for url: URL) {
        let controller = ViewerWindowController(scheduler: scheduler)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        if launchProbe && controllers.isEmpty {
            controller.onFirstImageFrame = { LaunchProbe.reportAndExit() }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        // The first window stays centred (a zero point leaves it where it is); later ones step
        // down and to the right.
        if let window = controller.window {
            cascadePoint = window.cascadeTopLeft(from: cascadePoint)
        }
        controller.open(url)
    }
}
