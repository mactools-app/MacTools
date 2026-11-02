import AppKit
import Foundation
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
        let params = try ActionParameterSet(["app": .string(app.localizedName!)])
        let approval = try controller.prepareApproval("inspect-app", parameters: params)
        guard approval.summary.contains("MacTools Native Policy Fixture") || approval.summary.contains("#") else { fatalError("Missing native window context") }
        let observed = try await controller.perform("inspect-app", parameters: params,
            inspectionTarget: controller.preparedInspectionTarget(params))
        Self.assertNoCuaSleepAssertion()
        guard !observed.message.contains("DO-NOT-READ-MACTOOLS"), !observed.message.contains("Fixture protected field") else { fatalError("Protected field escaped") }
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
        let fixtureState = URL(fileURLWithPath: CommandLine.arguments[3])
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
        _ = try controller.prepareApproval("inspect-app", parameters: params)
        let fresh = try await controller.perform("inspect-app", parameters: params, inspectionTarget: controller.preparedInspectionTarget(params))
        state = try JSONSerialization.jsonObject(with: Data(fresh.message.utf8)) as! [String: Any]
        controls = state["controls"] as! [[String: Any]]
        guard let field = controls.first(where: { ($0["role"] as? String) == "AXTextField" }),
              let control = field["element_token"] as? String else { print(observed.message); fatalError("Native field unavailable") }
        let write = try ActionParameterSet(["observationID": .string(state["observationID"] as! String),
            "controlID": .string(control), "value": .string("Native policy: 茶 ✅")])
        let writeApproval = try controller.prepareApproval("set-control-value", parameters: write)
        guard writeApproval.summary.contains("Native policy: 茶 ✅") else { fatalError("Missing proposed text") }
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
        await runtime.shutdown()
        Self.assertNoCuaSleepAssertion()
        print("Native exact-window read/write/click passed; protected control omitted; distinct approvals, no sleep assertion, and stale control/row/URL zero-dispatch passed.")
    }
}
