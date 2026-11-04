import AppKit
import Foundation

@MainActor final class FixtureApplication: NSApplication {
    var extraRoots: [Any] = []
    override func accessibilityChildren() -> [Any]? { (super.accessibilityChildren() ?? []) + extraRoots }
}

@MainActor class AuditedField: NSTextField {
    var read: (() -> Void)?
    override func accessibilityValue() -> String? { read?(); return super.accessibilityValue() }
}

@MainActor final class EchoField: NSTextField {
    var echoed: Any?
    override func accessibilityValue() -> String? { echoed as? String ?? super.accessibilityValue() }
    override func setAccessibilityValue(_ value: Any?) { echoed = value }
}

@MainActor final class UnknownField: AuditedField {
    var missingRole = false
    override func accessibilityRole() -> NSAccessibility.Role? { missingRole ? nil : .unknown }
}

@MainActor final class FixtureToolbar: NSView {
    var pressed: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { pressed?(); return true }
}

@MainActor final class Fixture: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let note = NSTextField(string: "Fixture note")
    let secret = NSSecureTextField(string: "DO-NOT-READ-MACTOOLS")
    let receipt = NSButton(checkboxWithTitle: "Fixture checkbox", target: nil, action: nil)
    let otherReceipt = NSButton(checkboxWithTitle: "Fixture checkbox", target: nil, action: nil)
    let rowName = NSTextField(labelWithString: "First item")
    let otherName = NSTextField(labelWithString: "Other item")
    let echo = EchoField(string: "Original app value")
    var foreignWindow: NSWindow!
    var foreignRoot: NSView!
    var foreignReads = 0
    var firstRow: NSView!
    var originalRowChildren: [Any] = []
    var foreignAttached = false
    var scopedReads = 0
    var toolbarOuter: NSView!
    var toolbarProtected = false
    var toolbarClicks = 0
    let toolbarDestination = NSTextField(string: "https://example.com/document-a")
    var documentChanged = false
    var toolbarDestinationChanged = false
    var ambiguousButtons: [NSButton] = []
    var ambiguousClicks = 0
    var unknownReads = 0
    var unknown: UnknownField?
    var deepRoot: NSView?
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
        window.contentView!.setAccessibilityElement(true)
        window.contentView!.setAccessibilityRole(.group)
        window.contentView!.setAccessibilityParent(window)
        window.setAccessibilityChildren([window.contentView!])
        note.frame = NSRect(x: 24, y: 230, width: 520, height: 30)
        note.setAccessibilityLabel("Fixture note")
        note.setAccessibilityParent(window)
        secret.frame = NSRect(x: 24, y: 180, width: 520, height: 30)
        secret.setAccessibilityLabel("Fixture protected field")
        receipt.target = self
        receipt.action = #selector(clicked)
        receipt.setAccessibilityURL(URL(string: "https://example.com/first"))
        otherReceipt.target = self
        otherReceipt.action = #selector(clickedOther)
        firstRow = row(name: rowName, button: receipt, y: 100)
        originalRowChildren = firstRow.accessibilityChildren() ?? []
        for view in [note, secret, firstRow!,
                     row(name: otherName, button: otherReceipt, y: 30)] as [NSView] {
            window.contentView!.addSubview(view)
        }
        // A second owned window exposes an application-root sheet that must not
        // be traversed while the first window is approved.
        foreignWindow = NSWindow(contentRect: NSRect(x: 180, y: 220, width: 320, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        foreignWindow.title = "Unapproved fixture window"
        let foreign = AuditedField(string: "UNAPPROVED-WINDOW-CONTENT")
        foreign.setAccessibilityLabel("Unapproved fixture field")
        foreign.frame = NSRect(x: 10, y: 10, width: 280, height: 30)
        foreign.read = { [weak self] in self?.foreignReads += 1; self?.save() }
        foreignRoot = NSView(frame: foreignWindow.contentView!.bounds)
        foreignRoot.setAccessibilityElement(true)
        foreignRoot.addSubview(foreign)
        foreignRoot.setAccessibilityRole(.sheet)
        foreignRoot.setAccessibilityFrame(foreignWindow.frame)
        foreignRoot.setAccessibilityLabel("Unapproved root sheet")
        foreignRoot.setAccessibilityParent(foreignWindow)
        foreignRoot.setAccessibilityChildren([foreign])
        foreignWindow.contentView!.addSubview(foreignRoot)
        foreign.setAccessibilityParent(foreignRoot)
        (NSApp as? FixtureApplication)?.extraRoots = [foreignRoot!]
        foreignWindow.orderBack(nil)
        // Both the toolbar itself and its inner group are addressable context
        // shapes. Neither the page sibling nor the outer text may be read.
        let outer = NSView(frame: NSRect(x: 10, y: 270, width: 540, height: 28))
        toolbarOuter = outer
        outer.setAccessibilityElement(true); outer.setAccessibilityRole(.group); outer.setAccessibilityParent(window)
        let toolbar = FixtureToolbar(frame: outer.bounds)
        toolbar.pressed = { [weak self] in self?.toolbarClicks += 1; self?.save() }
        toolbar.setAccessibilityElement(true)
        toolbar.setAccessibilityLabel("Fixture toolbar")
        toolbar.setAccessibilityRole(.toolbar); toolbar.setAccessibilityParent(outer)
        let inner = NSView(frame: outer.bounds)
        inner.setAccessibilityElement(true); inner.setAccessibilityRole(.group); inner.setAccessibilityParent(toolbar)
        inner.setAccessibilityIdentifier("mactools-ancestry-parent")
        let tool = NSButton(title: "Fixture toolbar button", target: self, action: #selector(clickedToolbar))
        tool.setAccessibilityIdentifier("mactools-ancestry-control")
        tool.setAccessibilityParent(inner)
        let page = AuditedField(string: "EXCLUDED-PAGE-CONTENT")
        page.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXWebArea")); page.setAccessibilityParent(inner)
        let outside = AuditedField(string: "EXCLUDED-OUTSIDE-TOOLBAR")
        outside.setAccessibilityParent(outer)
        for field in [page, outside] { field.read = { [weak self] in self?.scopedReads += 1; self?.save() } }
        inner.addSubview(tool); inner.addSubview(page)
        inner.setAccessibilityChildren(NSAccessibility.unignoredChildren(from: [tool, page]))
        let address = NSView(frame: outer.bounds)
        address.setAccessibilityElement(true); address.setAccessibilityRole(.group); address.setAccessibilityParent(toolbar)
        toolbarDestination.frame = NSRect(x: 0, y: 0, width: 480, height: 24)
        toolbarDestination.setAccessibilityElement(true)
        toolbarDestination.setAccessibilityRole(.textField)
        toolbarDestination.setAccessibilityLabel("Fixture toolbar destination")
        toolbarDestination.setAccessibilityParent(address)
        address.addSubview(toolbarDestination); address.setAccessibilityChildren([toolbarDestination])
        toolbar.addSubview(inner); toolbar.addSubview(address); toolbar.setAccessibilityChildren([inner, address])
        outer.addSubview(toolbar); outer.addSubview(outside)
        outer.setAccessibilityChildren([toolbar] + NSAccessibility.unignoredChildren(from: [outside]))
        window.contentView!.addSubview(outer)
        let web = NSView(frame: NSRect(x: 20, y: 4, width: 530, height: 28))
        web.setAccessibilityElement(true)
        web.setAccessibilityRole(NSAccessibility.Role(rawValue: "AXWebArea"))
        web.setAccessibilityParent(window)
        echo.frame = NSRect(x: 0, y: 0, width: 480, height: 24)
        echo.setAccessibilityLabel("Fixture echo field")
        web.addSubview(echo)
        web.setAccessibilityChildren(NSAccessibility.unignoredChildren(from: [echo]))
        echo.setAccessibilityParent(web)
        window.contentView!.addSubview(web)
        window.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        save()
    }

    private func update() {
        let directory = output.deletingLastPathComponent()
        let showAmbiguous = FileManager.default.fileExists(atPath: directory.appendingPathComponent("add-failed-peer").path)
        if showAmbiguous, ambiguousButtons.isEmpty {
            for index in 0..<2 {
                let button = NSButton(title: "Fixture ambiguous action", target: self, action: #selector(clickedAmbiguous))
                button.frame = NSRect(x: CGFloat(20 + index * 250), y: 10, width: 240, height: 24)
                button.setAccessibilityIdentifier(index == 0 ? "mactools-readable-peer" : "mactools-ambiguous-peer")
                button.setAccessibilityParent(window)
                window.contentView!.addSubview(button); ambiguousButtons.append(button)
            }
        } else if !showAmbiguous, !ambiguousButtons.isEmpty {
            ambiguousButtons.forEach { $0.removeFromSuperview() }; ambiguousButtons.removeAll()
        }
        documentChanged = FileManager.default.fileExists(atPath: directory.appendingPathComponent("change-document").path)
        window.title = documentChanged ? "MacTools Native Policy Fixture — Document B" : "MacTools Native Policy Fixture"
        toolbarDestinationChanged = FileManager.default.fileExists(atPath: directory.appendingPathComponent("change-toolbar-destination").path)
        let destination = toolbarDestinationChanged ? "https://example.com/document-b" : "https://example.com/document-a"
        toolbarDestination.stringValue = destination
        toolbarDestination.setAccessibilityURL(URL(string: destination))
        toolbarProtected = FileManager.default.fileExists(atPath: directory.appendingPathComponent("protect-toolbar").path)
        NSAccessibility.setMayContainProtectedContent(toolbarProtected)
        toolbarOuter.setAccessibilityProtectedContent(toolbarProtected)
        let attachForeign = FileManager.default.fileExists(atPath: directory.appendingPathComponent("attach-foreign").path)
        if attachForeign != foreignAttached {
            firstRow.setAccessibilityChildren(attachForeign ? originalRowChildren + [foreignRoot!] : originalRowChildren)
            foreignAttached = attachForeign
        }
        let showUnknown = FileManager.default.fileExists(atPath: directory.appendingPathComponent("add-unknown").path)
        if showUnknown, unknown == nil {
            let field = UnknownField(string: "UNCLASSIFIED-CONTENT")
            field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
            field.setAccessibilityElement(true)
            field.setAccessibilityParent(window)
            field.setAccessibilityLabel("Fixture unknown field")
            field.read = { [weak self] in self?.unknownReads += 1; self?.save() }
            window.contentView!.addSubview(field)
            window.contentView!.setAccessibilityChildren(NSAccessibility.unignoredChildren(from: window.contentView!.subviews.filter { $0 !== field }) + [field])
            unknown = field
        }
        unknown?.missingRole = FileManager.default.fileExists(atPath: directory.appendingPathComponent("missing-role").path)
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
        let wantsDeep = FileManager.default.fileExists(atPath: directory.appendingPathComponent("add-deep").path)
        if wantsDeep, deepRoot == nil {
            let root = NSView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
            root.setAccessibilityElement(true); root.setAccessibilityRole(.row); root.setAccessibilityParent(window)
            var parent = root
            for _ in 0..<10 {
                let child = NSView(frame: root.bounds)
                child.setAccessibilityElement(true); child.setAccessibilityRole(.row)
                child.setAccessibilityParent(parent)
                parent.addSubview(child); parent.setAccessibilityChildren([child]); parent = child
            }
            let button = NSButton(title: "Fixture checkbox", target: self, action: #selector(clicked))
            button.setAccessibilityParent(parent)
            parent.addSubview(button); parent.setAccessibilityChildren([button])
            window.contentView!.addSubview(root); deepRoot = root
        } else if !wantsDeep, let root = deepRoot { root.removeFromSuperview(); deepRoot = nil }
        save()
    }

    @objc func clicked() { clicks += 1; save() }
    @objc func clickedOther() { otherClicks += 1; save() }
    @objc func clickedToolbar() { toolbarClicks += 1; save() }
    @objc func clickedAmbiguous() { ambiguousClicks += 1; save() }
    @objc func save() {
        let data = try! JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier,
            "note": note.stringValue, "checked": receipt.state == .on, "clicks": clicks,
            "otherClicks": otherClicks, "title": receipt.title, "row": rowName.stringValue, "urlChanged": urlChanged,
            "windowID": window.windowNumber, "foreignReads": foreignReads, "echoAppValue": echo.stringValue,
            "deepShown": deepRoot != nil, "foreignAttached": foreignAttached, "scopedReads": scopedReads,
            "toolbarProtected": toolbarProtected,
            "toolbarClicks": toolbarClicks,
            "documentChanged": documentChanged, "toolbarDestinationChanged": toolbarDestinationChanged,
            "ambiguousShown": !ambiguousButtons.isEmpty, "ambiguousClicks": ambiguousClicks,
            "unknownShown": unknown != nil, "unknownReads": unknownReads, "missingRole": unknown?.missingRole ?? false])
        try! data.write(to: output, options: .atomic)
    }
}

@main struct FixtureApp {
    @MainActor static func main() {
        let app = FixtureApplication.shared
        app.setActivationPolicy(.regular)
        let fixture = Fixture(output: URL(fileURLWithPath: CommandLine.arguments[1]))
        app.delegate = fixture
        app.run()
    }
}
