import AppKit
import ApplicationServices
import Foundation
import Darwin
import IOKit.pwr_mgt
import MacToolsPluginKit
@main struct Probe {
    static func assertNoCuaSleepAssertion() {
        var copied: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&copied) == kIOReturnSuccess, let copied else {
            fatalError("Could not inspect this probe's sleep assertions")
        }
        let dictionary = copied.takeRetainedValue() as NSDictionary
        let assertions = dictionary[NSNumber(value: ProcessInfo.processInfo.processIdentifier)] as? [[String: Any]] ?? []
        if assertions.contains(where: { ($0[kIOPMAssertionNameKey as String] as? String)?.hasPrefix("Cua Driver:") == true }) {
            print("ERROR: Cua installed an unrequested display-sleep assertion")
            exit(1)
        }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let runtime = CuaRuntime(libraryURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let controller = ComputerUseController(runtime: runtime, environment: SystemComputerUseEnvironment())
        let pid = Int32(CommandLine.arguments[2])!
        let app = NSRunningApplication(processIdentifier: pid)!
        let root = AXUIElementCreateApplication(pid)
        var roots: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &roots) == .success,
              let children = roots as? [AXUIElement], children.contains(where: { child in
                  var role: CFTypeRef?
                  return AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role) == .success
                      && role as? String == "AXSheet"
              }) else { fatalError("Fixture must expose the unapproved application-root sheet") }
        let fixtureState = URL(fileURLWithPath: CommandLine.arguments[3])
        let initial = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
        let params = try ActionParameterSet(["app": .string(app.localizedName!), "windowID": .integer(Int64(initial["windowID"] as! Int))])
        func waitFor(_ key: String, _ expected: Bool) async throws {
            for _ in 0..<100 {
                let state = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
                if state[key] as? Bool == expected { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            fatalError("Fixture did not reach \(key)=\(expected)")
        }
        let directory = fixtureState.deletingLastPathComponent()
        let toolbarParams = try ActionParameterSet(["app": .string(app.localizedName!),
            "windowID": .integer(Int64(initial["windowID"] as! Int)), "scope": .string("toolbar")])
        _ = try controller.prepareApproval("inspect-app", parameters: toolbarParams)
        let toolbarRead = try await controller.perform("inspect-app", parameters: toolbarParams,
            inspectionTarget: controller.preparedInspectionTarget(toolbarParams))
        let toolbarState = try JSONSerialization.jsonObject(with: Data(toolbarRead.message.utf8)) as! [String: Any]
        let toolbarControls = toolbarState["controls"] as! [[String: Any]]
        guard toolbarState["complete"] as? Bool == true,
              toolbarControls.contains(where: { $0["role"] as? String == "AXToolbar" }),
              toolbarControls.contains(where: { $0["label"] as? String == "Fixture toolbar button" && $0["native_input_ready"] as? Bool == true }),
              !toolbarRead.message.contains("EXCLUDED-") else {
            FileHandle.standardError.write(Data((toolbarRead.message + "\n").utf8))
            fatalError("Toolbar scope did not preserve native controls and exclude page/context content")
        }
        let toolbarAfter = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
        guard toolbarAfter["scopedReads"] as? Int == initial["scopedReads"] as? Int else { fatalError("Toolbar semantic capture read excluded content") }
        // Keep the control readable while its parent's metadata becomes unavailable.
        // The native read counter must stay zero even though input is refused.
        let ancestryImage = dlopen(nil, RTLD_NOW)!
        let failAncestry = unsafeBitCast(dlsym(ancestryImage, "mactools_fixture_fail_ancestry"),
            to: (@convention(c) (Bool) -> Void).self)
        let ancestorFailures = unsafeBitCast(dlsym(ancestryImage, "mactools_fixture_ancestor_failures"),
            to: (@convention(c) () -> UInt32).self)
        let descendantReads = unsafeBitCast(dlsym(ancestryImage, "mactools_fixture_descendant_reads"),
            to: (@convention(c) () -> UInt32).self)
        let observedButton = toolbarControls.first { $0["label"] as? String == "Fixture toolbar button" }!
        let ancestryClick = try ActionParameterSet(["observationID": .string(toolbarState["observationID"] as! String),
            "controlID": .string(observedButton["element_token"] as! String)])
        _ = try controller.prepareApproval("click-control", parameters: ancestryClick)
        failAncestry(true)
        do { _ = try await controller.perform("click-control", parameters: ancestryClick); fatalError("Unavailable ancestor permitted input") }
        catch ComputerUseError.staleObservation {}
        catch ComputerUseError.unverified {}
        let ancestryRefused = ancestorFailures() > 0
        let reads = descendantReads()
        failAncestry(false)
        guard ancestryRefused, reads == 0 else {
            FileHandle.standardError.write(Data("Ancestor refusal read descendant content: failures=\(ancestryRefused), value reads=\(reads)\n".utf8))
            exit(1)
        }
        print("PASS: unavailable ancestor refused with zero descendant AXValue reads")
        // The refused input consumed its observation; restore a fresh toolbar target.
        _ = try controller.prepareApproval("inspect-app", parameters: toolbarParams)
        let refreshed = try await controller.perform("inspect-app", parameters: toolbarParams,
            inspectionTarget: controller.preparedInspectionTarget(toolbarParams))
        let refreshedState = try JSONSerialization.jsonObject(with: Data(refreshed.message.utf8)) as! [String: Any]
        let refreshedControls = refreshedState["controls"] as! [[String: Any]]
        let refreshedButton = refreshedControls.first { $0["label"] as? String == "Fixture toolbar button" }!
        let toolbarClick = try ActionParameterSet(["observationID": .string(refreshedState["observationID"] as! String),
            "controlID": .string(refreshedButton["element_token"] as! String)])
        _ = try controller.prepareApproval("click-control", parameters: toolbarClick)
        try Data().write(to: directory.appendingPathComponent("protect-toolbar"))
        try await waitFor("toolbarProtected", true)
        do { _ = try await controller.perform("click-control", parameters: toolbarClick); fatalError("Protected toolbar ancestor permitted input") }
        catch ComputerUseError.staleObservation {}
        catch ComputerUseError.unverified {
            // AppKit may expose inherited protection on the addressed control,
            // causing an earlier native refusal. The counter must prove zero input.
        }
        let protectedAfter = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
        guard protectedAfter["toolbarClicks"] as? Int == 0 else { fatalError("Protected toolbar received native input") }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("protect-toolbar"))
        try await waitFor("toolbarProtected", false)
        // Retain every toolbar object while switching the window's document, then
        // switch only the address peer outside the target's inner layout group.
        for (flag, stateKey) in [("change-document", "documentChanged"),
                                 ("change-toolbar-destination", "toolbarDestinationChanged")] {
            _ = try controller.prepareApproval("inspect-app", parameters: toolbarParams)
            let read = try await controller.perform("inspect-app", parameters: toolbarParams,
                inspectionTarget: controller.preparedInspectionTarget(toolbarParams))
            let state = try JSONSerialization.jsonObject(with: Data(read.message.utf8)) as! [String: Any]
            let controls = state["controls"] as! [[String: Any]]
            let button = controls.first { $0["label"] as? String == "Fixture toolbar button" }!
            let click = try ActionParameterSet(["observationID": .string(state["observationID"] as! String),
                "controlID": .string(button["element_token"] as! String)])
            _ = try controller.prepareApproval("click-control", parameters: click)
            try Data().write(to: directory.appendingPathComponent(flag))
            try await waitFor(stateKey, true)
            do { _ = try await controller.perform("click-control", parameters: click); fatalError("Changed toolbar document permitted input") }
            catch ComputerUseError.staleObservation {}
            let after = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
            guard after["toolbarClicks"] as? Int == 0,
                  after["scopedReads"] as? Int == initial["scopedReads"] as? Int else {
                fatalError("Stale toolbar input or excluded content read")
            }
            try FileManager.default.removeItem(at: directory.appendingPathComponent(flag))
            try await waitFor(stateKey, false)
        }
        // The probe-only interposer fails B's real AX action-list IPC. A remains
        // readable, but its apparently unique label must not permit approval.
        try Data().write(to: directory.appendingPathComponent("add-failed-peer"))
        try await waitFor("ambiguousShown", true)
        _ = try controller.prepareApproval("inspect-app", parameters: params)
        let failedRead = try await controller.perform("inspect-app", parameters: params,
            inspectionTarget: controller.preparedInspectionTarget(params))
        let failedState = try JSONSerialization.jsonObject(with: Data(failedRead.message.utf8)) as! [String: Any]
        let failedControls = failedState["controls"] as! [[String: Any]]
        let readablePeer = failedControls.first { $0["label"] as? String == "Fixture ambiguous action" }!
        let image = dlopen(nil, RTLD_NOW)!
        let address = dlsym(image, "mactools_fixture_failed_action_reads")!
        let failureCount = unsafeBitCast(address, to: (@convention(c) () -> UInt32).self)
        guard failureCount() > 0, failedState["complete"] as? Bool == false else { fatalError("Failed peer read was reported complete") }
        dlclose(image)
        do {
            _ = try controller.prepareApproval("click-control", parameters: .init([
                "observationID": .string(failedState["observationID"] as! String),
                "controlID": .string(readablePeer["element_token"] as! String)]))
            fatalError("Missing ambiguous peer permitted approval")
        } catch ComputerUseError.unavailable {}
        let refusedPeer = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
        guard refusedPeer["ambiguousClicks"] as? Int == 0 else { fatalError("Ambiguous control received input") }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("add-failed-peer"))
        try await waitFor("ambiguousShown", false)
        let approval = try controller.prepareApproval("inspect-app", parameters: params)
        guard approval.summary.contains("MacTools Native Policy Fixture") || approval.summary.contains("#") else { fatalError("Missing native window context") }
        FileHandle.standardError.write(Data("Native fixture: initial inspection\n".utf8))
        let observed = try await controller.perform("inspect-app", parameters: params,
            inspectionTarget: controller.preparedInspectionTarget(params))
        Self.assertNoCuaSleepAssertion()
        guard !observed.message.contains("DO-NOT-READ-MACTOOLS"), !observed.message.contains("Fixture protected field"),
              !observed.message.contains("UNAPPROVED-WINDOW-CONTENT") else { fatalError("Private field escaped") }
        let scoped = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
        guard scoped["foreignReads"] as? Int == initial["foreignReads"] as? Int else { fatalError("Unapproved window values were read") }
        var state = try JSONSerialization.jsonObject(with: Data(observed.message.utf8)) as! [String: Any]
        var controls = state["controls"] as! [[String: Any]]
        guard let staleBox = controls.first(where: { ($0["context"] as? String)?.contains("First item") == true && $0["role"] as? String == "AXCheckBox" }) else {
            FileHandle.standardOutput.write(Data(observed.message.utf8)); exit(1)
        }
        let otherBox = controls.first { ($0["context"] as? String)?.contains("Other item") == true && $0["role"] as? String == "AXCheckBox" }!
        guard staleBox["label"] as? String == otherBox["label"] as? String else { fatalError("Expected identical control labels") }
        let otherApproval = try controller.prepareApproval("click-control", parameters: .init([
            "observationID": .string(state["observationID"] as! String), "controlID": .string(otherBox["element_token"] as! String)]))
        let staleClick = try ActionParameterSet(["observationID": .string(state["observationID"] as! String),
            "controlID": .string(staleBox["element_token"] as! String)])
        let pendingApproval = try controller.prepareApproval("click-control", parameters: staleClick)
        guard pendingApproval.summary.contains("First item"), otherApproval.summary.contains("Other item"),
              pendingApproval.summary != otherApproval.summary else { fatalError("Identical labels need distinct visible row approvals") }
        try Data().write(to: fixtureState.deletingLastPathComponent().appendingPathComponent("change-control"))
        var changed = false
        for _ in 0..<100 {
            let data = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
            if data["title"] as? String == "Fixture changed action" { changed = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard changed else { fatalError("Fixture did not reuse its retained control") }
        do {
            _ = try await controller.perform("click-control", parameters: staleClick)
            print("ERROR: a semantically changed retained control was dispatched")
            await runtime.shutdown(); exit(1)
        } catch ComputerUseError.staleObservation {}
        let untouched = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
        guard untouched["clicks"] as? Int == 0 else { fatalError("Stale control received native input") }
        // Keep the same button title/object, but recycle the surrounding row to a new item.
        _ = try controller.prepareApproval("inspect-app", parameters: params)
        FileHandle.standardError.write(Data("Native fixture: row inspection\n".utf8))
        let rowRead = try await controller.perform("inspect-app", parameters: params, inspectionTarget: controller.preparedInspectionTarget(params))
        let rowState = try JSONSerialization.jsonObject(with: Data(rowRead.message.utf8)) as! [String: Any]
        let rowControls = rowState["controls"] as! [[String: Any]]
        let rowBox = rowControls.first { ($0["context"] as? String)?.contains("First item") == true && $0["role"] as? String == "AXCheckBox" }!
        let rowClick = try ActionParameterSet(["observationID": .string(rowState["observationID"] as! String),
            "controlID": .string(rowBox["element_token"] as! String)])
        _ = try controller.prepareApproval("click-control", parameters: rowClick)
        try Data().write(to: fixtureState.deletingLastPathComponent().appendingPathComponent("change-context"))
        changed = false
        for _ in 0..<100 {
            let data = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
            if data["row"] as? String == "Second item" { changed = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard changed else { fatalError("Fixture did not recycle its row context") }
        do {
            _ = try await controller.perform("click-control", parameters: rowClick)
            print("ERROR: a recycled row's unchanged button was dispatched")
            await runtime.shutdown(); exit(1)
        } catch ComputerUseError.staleObservation {}
        let rowUntouched = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
        guard rowUntouched["clicks"] as? Int == 0 else { fatalError("Recycled row received native input") }
        // A native destination change must not pass under identical visible label/context.
        _ = try controller.prepareApproval("inspect-app", parameters: params)
        FileHandle.standardError.write(Data("Native fixture: URL inspection\n".utf8))
        let urlRead = try await controller.perform("inspect-app", parameters: params, inspectionTarget: controller.preparedInspectionTarget(params))
        let urlState = try JSONSerialization.jsonObject(with: Data(urlRead.message.utf8)) as! [String: Any]
        let urlControls = urlState["controls"] as! [[String: Any]]
        let urlBox = urlControls.first { ($0["context"] as? String)?.contains("Second item") == true && $0["role"] as? String == "AXCheckBox" }!
        let urlClick = try ActionParameterSet(["observationID": .string(urlState["observationID"] as! String),
            "controlID": .string(urlBox["element_token"] as! String)])
        _ = try controller.prepareApproval("click-control", parameters: urlClick)
        try Data().write(to: fixtureState.deletingLastPathComponent().appendingPathComponent("change-url"))
        changed = false
        for _ in 0..<100 {
            let data = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
            if data["urlChanged"] as? Bool == true { changed = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard changed else { fatalError("Fixture did not update its native URL") }
        do {
            _ = try await controller.perform("click-control", parameters: urlClick)
            print("ERROR: a changed native destination was dispatched")
            await runtime.shutdown(); exit(1)
        } catch ComputerUseError.staleObservation {}
        let urlUntouched = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
        guard urlUntouched["clicks"] as? Int == 0 else { fatalError("Changed native URL received input") }
        // Revalidation must reject a newly exposed foreign child before its value is read.
        _ = try controller.prepareApproval("inspect-app", parameters: params)
        let foreignRead = try await controller.perform("inspect-app", parameters: params, inspectionTarget: controller.preparedInspectionTarget(params))
        let foreignState = try JSONSerialization.jsonObject(with: Data(foreignRead.message.utf8)) as! [String: Any]
        let foreignBox = (foreignState["controls"] as! [[String: Any]]).first {
            $0["role"] as? String == "AXCheckBox" && ($0["context"] as? String)?.contains("Second item") == true
        }!
        let foreignClick = try ActionParameterSet(["observationID": .string(foreignState["observationID"] as! String),
            "controlID": .string(foreignBox["element_token"] as! String)])
        _ = try controller.prepareApproval("click-control", parameters: foreignClick)
        try Data().write(to: directory.appendingPathComponent("attach-foreign"))
        try await waitFor("foreignAttached", true)
        do { _ = try await controller.perform("click-control", parameters: foreignClick); fatalError("Foreign contextual child permitted input") }
        catch ComputerUseError.staleObservation {}
        let foreignAfter = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
        guard foreignAfter["foreignReads"] as? Int == initial["foreignReads"] as? Int,
              foreignAfter["clicks"] as? Int == 0 else { fatalError("Revalidation read or acted through a foreign window") }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("attach-foreign"))
        try await waitFor("foreignAttached", false)
        _ = try controller.prepareApproval("inspect-app", parameters: params)
        FileHandle.standardError.write(Data("Native fixture: fresh inspection\n".utf8))
        let fresh = try await controller.perform("inspect-app", parameters: params, inspectionTarget: controller.preparedInspectionTarget(params))
        state = try JSONSerialization.jsonObject(with: Data(fresh.message.utf8)) as! [String: Any]
        controls = state["controls"] as! [[String: Any]]
        guard let field = controls.first(where: { ($0["role"] as? String) == "AXTextField" }),
              let control = field["element_token"] as? String else { print(observed.message); fatalError("Native field unavailable") }
        let write = try ActionParameterSet(["observationID": .string(state["observationID"] as! String),
            "controlID": .string(control), "value": .string("Native policy: 茶 ✅")])
        let writeApproval = try controller.prepareApproval("set-control-value", parameters: write)
        guard writeApproval.summary.contains("Native policy: 茶 ✅") else { fatalError("Missing proposed text") }
        FileHandle.standardError.write(Data("Native fixture: native value write\n".utf8))
        let outcome = try await controller.perform("set-control-value", parameters: write)
        print("Controller native-write verified: \(outcome.verified)")
        let after = (try JSONSerialization.jsonObject(with: Data(outcome.message.utf8)) as! [String: Any])["observation"] as! [String: Any]
        let afterControls = after["controls"] as! [[String: Any]]
        guard afterControls.contains(where: { $0["value"] as? String == "Native policy: 茶 ✅" }) else {
            FileHandle.standardOutput.write(Data(outcome.message.utf8)); fatalError("Fresh observation did not confirm fixture text")
        }
        guard let box = afterControls.first(where: { $0["role"] as? String == "AXCheckBox" && ($0["context"] as? String)?.contains("Second item") == true }) else { fatalError("Checkbox unavailable") }
        do {
            let clicked = try await controller.perform("click-control", parameters: .init([
                "observationID": .string(after["observationID"] as! String), "controlID": .string(box["element_token"] as! String)]))
            guard !clicked.verified else { fatalError("Dispatch alone must not claim completion") }
        } catch ComputerUseError.unverified {
            // Background AXPress can report an uncertain acknowledgement after dispatch.
            // The fixture's independent counter below must still establish exactly one effect.
        }
        // A web field's AX echo is not proof that the app accepted its value.
        _ = try controller.prepareApproval("inspect-app", parameters: params)
        FileHandle.standardError.write(Data("Native fixture: echo inspection\n".utf8))
        let echoRead = try await controller.perform("inspect-app", parameters: params, inspectionTarget: controller.preparedInspectionTarget(params))
        let echoState = try JSONSerialization.jsonObject(with: Data(echoRead.message.utf8)) as! [String: Any]
        let echoField = (echoState["controls"] as! [[String: Any]]).first { $0["label"] as? String == "Fixture echo field" }!
        let echoWrite = try ActionParameterSet(["observationID": .string(echoState["observationID"] as! String),
            "controlID": .string(echoField["element_token"] as! String), "value": .string("AX echo only")])
        _ = try controller.prepareApproval("set-control-value", parameters: echoWrite)
        FileHandle.standardError.write(Data("Native fixture: web echo write\n".utf8))
        let echoOutcome = try await controller.perform("set-control-value", parameters: echoWrite)
        guard !echoOutcome.verified else { fatalError("Web AX echo was promoted to verified") }
        let echoAfter = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
        guard echoAfter["echoAppValue"] as? String == "Original app value" else { fatalError("Echo fixture unexpectedly changed application state") }
        // A depth-pruned branch invalidates completeness even below the node cap.
        try Data().write(to: fixtureState.deletingLastPathComponent().appendingPathComponent("add-deep"))
        for _ in 0..<100 {
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
            if state["deepShown"] as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try controller.prepareApproval("inspect-app", parameters: params)
        FileHandle.standardError.write(Data("Native fixture: depth inspection\n".utf8))
        let deepRead = try await controller.perform("inspect-app", parameters: params, inspectionTarget: controller.preparedInspectionTarget(params))
        let deepState = try JSONSerialization.jsonObject(with: Data(deepRead.message.utf8)) as! [String: Any]
        guard deepState["complete"] as? Bool == false else { fatalError("Depth-limited scope was reported complete") }
        let deepBox = (deepState["controls"] as! [[String: Any]]).first { $0["role"] as? String == "AXCheckBox" }!
        let deepClick = try ActionParameterSet(["observationID": .string(deepState["observationID"] as! String),
            "controlID": .string(deepBox["element_token"] as! String)])
        do { _ = try controller.prepareApproval("click-control", parameters: deepClick); fatalError("Incomplete scope prepared approval") }
        catch ComputerUseError.unavailable {}
        do { _ = try await controller.perform("click-control", parameters: deepClick); fatalError("Incomplete scope dispatched") }
        catch ComputerUseError.unavailable {}
        try FileManager.default.removeItem(at: directory.appendingPathComponent("add-deep"))
        try await waitFor("deepShown", false)
        try Data().write(to: directory.appendingPathComponent("add-unknown"))
        try await waitFor("unknownShown", true)
        for missing in [false, true] {
            if missing {
                try Data().write(to: directory.appendingPathComponent("missing-role"))
                try await waitFor("missingRole", true)
            }
            _ = try controller.prepareApproval("inspect-app", parameters: params)
            let unknownRead = try await controller.perform("inspect-app", parameters: params, inspectionTarget: controller.preparedInspectionTarget(params))
            let unknownState = try JSONSerialization.jsonObject(with: Data(unknownRead.message.utf8)) as! [String: Any]
            let after = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureState)) as! [String: Any]
            guard unknownState["complete"] as? Bool == false, !unknownRead.message.contains("UNCLASSIFIED-CONTENT"),
                  after["unknownReads"] as? Int == 0 else { fatalError("Unknown or missing role content was read or reported complete") }
        }
        await runtime.shutdown()
        Self.assertNoCuaSleepAssertion()
        print("Native exact-window effects, protected/unknown exclusion, scoped toolbar/context reads, fault-injected peer completeness, stale toolbar document/address and control/row/URL/foreign-child zero-dispatch, depth refusal, no sleep assertion, and unverified web echoes passed.")
    }
}
