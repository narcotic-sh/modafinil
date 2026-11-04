import AppKit
import SwiftUI

/// Hosts the SwiftUI main window (sidebar + pages).
final class MainWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(model: AppUIModel, remoteMacs: RemoteMacsController) {
        let host = NSHostingController(rootView: MainWindowView().environmentObject(model).environmentObject(remoteMacs))
        host.sizingOptions = []
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Modafinil"
        window.toolbar = NSToolbar(identifier: "ModafinilMainWindow")
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 520)
        window.setContentSize(NSSize(width: 920, height: 660))
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("ModafinilMainWindow") { window.center() }
        window.setFrameAutosaveName("ModafinilMainWindow")
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
