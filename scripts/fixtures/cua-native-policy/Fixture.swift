import AppKit
import Foundation

@MainActor final class Fixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let note = NSTextField(string: "Fixture note")
    let secret = NSSecureTextField(string: "DO-NOT-READ-MACTOOLS")
    let receipt = NSButton(checkboxWithTitle: "Fixture checkbox", target: nil, action: nil)
    let otherReceipt = NSButton(checkboxWithTitle: "Fixture checkbox", target: nil, action: nil)
    let rowName = NSTextField(labelWithString: "First item")
    let otherName = NSTextField(labelWithString: "Other item")
    var clicks = 0
    var otherClicks = 0
    var urlChanged = false
    let output: URL

    init(output: URL) { self.output = output }

    private func row(name: NSTextField, button: NSButton, y: CGFloat) -> NSView {
        let row = NSView(frame: NSRect(x: 24, y: y, width: 520, height: 50))
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.row)
        name.frame = NSRect(x: 0, y: 10, width: 180, height: 24)
        let cell = NSView(frame: NSRect(x: 190, y: 0, width: 300, height: 50))
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.cell)
        button.frame = NSRect(x: 0, y: 10, width: 280, height: 24)
        cell.addSubview(button)
        row.addSubview(name)
        row.addSubview(cell)
        row.setAccessibilityChildren(NSAccessibility.unignoredChildren(from: [name, cell]))
        row.setAccessibilityParent(window)
        name.setAccessibilityParent(row)
        cell.setAccessibilityParent(row)
        cell.setAccessibilityChildren(NSAccessibility.unignoredChildren(from: [button]))
        button.setAccessibilityParent(cell)
        return row
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 160, y: 200, width: 580, height: 300),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "MacTools Native Policy Fixture"
        note.frame = NSRect(x: 24, y: 230, width: 520, height: 30)
        note.setAccessibilityLabel("Fixture note")
        secret.frame = NSRect(x: 24, y: 180, width: 520, height: 30)
        secret.setAccessibilityLabel("Fixture protected field")
        receipt.target = self
        receipt.action = #selector(clicked)
        receipt.setAccessibilityURL(URL(string: "https://example.com/first"))
        otherReceipt.target = self
        otherReceipt.action = #selector(clickedOther)
        for view in [note, secret, row(name: rowName, button: receipt, y: 100),
                     row(name: otherName, button: otherReceipt, y: 30)] as [NSView] {
            window.contentView!.addSubview(view)
        }
        window.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        save()
    }

    private func update() {
        let directory = output.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("change-control").path) {
            receipt.title = "Fixture changed action"
        }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("change-context").path) {
            rowName.stringValue = "Second item"
        }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("change-url").path) {
            receipt.setAccessibilityURL(URL(string: "https://example.com/second"))
            urlChanged = true
        }
        save()
    }

    @objc func clicked() { clicks += 1; save() }
    @objc func clickedOther() { otherClicks += 1; save() }
    @objc func save() {
        let data = try! JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
            "note": note.stringValue, "checked": receipt.state == .on, "clicks": clicks,
            "otherClicks": otherClicks, "title": receipt.title, "row": rowName.stringValue, "urlChanged": urlChanged])
        try! data.write(to: output, options: .atomic)
    }
}

@main struct FixtureApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let fixture = Fixture(output: URL(fileURLWithPath: CommandLine.arguments[1]))
        app.delegate = fixture
        app.run()
    }
}
