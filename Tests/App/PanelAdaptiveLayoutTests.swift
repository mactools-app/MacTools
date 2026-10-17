import AppKit
import XCTest
import MacToolsPluginKit
@testable import MacTools

@MainActor
final class PanelAdaptiveLayoutTests: XCTestCase {
    private func row(_ id: String, compact: Bool = true, width: MenuBarPanelItemWidth? = nil,
                     detail: PluginPanelDetail? = nil) -> PluginPanelRowSnapshot {
        .init(id: id, title: id, iconName: "circle", iconTint: .blue, controlStyle: .switch,
              menuActionBehavior: .keepPresented, description: "", helpText: "", descriptionTone: .secondary,
              isOn: true, isExpanded: false, isEnabled: true, detail: detail, buttonActionID: nil,
              buttonTitle: nil, supportsCompactSwitch: compact, usesCompactPresentation: compact, width: width)
    }

    func testInvalidWidthDraftsCannotReachColumnConversionOrCommit() throws {
        let formatter = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0)).locale(Locale(identifier: "en_US"))
        let pasted = try formatter.parseStrategy.parse("-999999999999999999999999")
        for value in [pasted, -Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude,
                      .infinity, -.infinity, .nan, 0, 315, 629] {
            XCTAssertNil(MenuBarPanelWidth.validatedDraft(value, maximum: 628))
        }
        XCTAssertEqual(MenuBarPanelWidth.columns(forSurfaceWidth: pasted), 1)
        XCTAssertEqual(MenuBarPanelWidth.columns(forSurfaceWidth: .greatestFiniteMagnitude), Int.max)
        XCTAssertEqual(MenuBarPanelWidth.columns(forSurfaceWidth: .nan), 1)
        XCTAssertEqual(MenuBarPanelWidth.validatedDraft(316, maximum: 628), 316)
        XCTAssertEqual(MenuBarPanelWidth.validatedDraft(628, maximum: 628), 628)
        XCTAssertEqual(MenuBarPanelWidth.validatedDraft(500.4, maximum: 628), 500)
        // A smaller screen changes presentation, not the saved preferred width.
        XCTAssertEqual(MenuBarPanelWidth.resolved(preferred: 940, maximum: 628), 628)
    }

    func testWidthControlsColumnCountWithoutResizingLegacyWidgets() throws {
        let rows = (0..<14).map { row(String($0)) }
        for (width, firstBandCount) in [(CGFloat(304), 2), (464, 3), (1100, 7)] {
            let layout = ConfiguredMenuBarPanelLayout.placement(features: rows, width: width)
            XCTAssertEqual(layout.featureFrames.values.filter { $0.minY == 0 }.count, firstBandCount)
            XCTAssertTrue(layout.featureFrames.values.allSatisfy { $0.maxX <= width + 0.001 && $0.width >= 148 })
        }
        let balanced = ConfiguredMenuBarPanelLayout.placement(features: Array(rows.prefix(4)), width: 548)
        XCTAssertEqual(balanced.featureFrames.values.filter { $0.minY == 0 }.count, 2)
        XCTAssertEqual(balanced.featureFrames.values.filter { $0.minY > 0 }.count, 2)
        XCTAssertTrue(balanced.featureFrames.values.allSatisfy { $0.width == 270 })
        let seven = ConfiguredMenuBarPanelLayout.placement(features: Array(rows.prefix(7)), width: 464)
        let bands = Dictionary(grouping: seven.featureFrames.values, by: \.minY).sorted { $0.key < $1.key }
        XCTAssertEqual(bands.map { $0.value.count }, [3, 2, 2])
        XCTAssertEqual(bands.flatMap(\.value).count, 7)
        let span = PluginPanelWidgetSpan(width: 4, height: 16)!
        let widgets = ComponentGridPlacementEngine.placements(for: [("legacy", span), ("next", .twoByOne)], width: 1100)
        let legacy = PanelLayoutDestination.frame(try XCTUnwrap(widgets.first))
        XCTAssertEqual(legacy.width, PluginPanelWidgetLayoutMetrics.default.gridWidth)
        XCTAssertEqual(legacy.minX, 0)
        XCTAssertGreaterThan(widgets[1].yOffset, legacy.maxY)
        for grid in [PluginPanelWidgetGrid.standard, .compact] {
            let span = PluginPanelWidgetSpan(width: grid.rawValue, height: 16, grid: grid)!
            let before = MenuBarPanelEntry(placement: .init(item: .init(pluginID: "example", itemID: "before")), kind: .row)
            let widget = MenuBarPanelEntry(placement: .init(item: .init(pluginID: "example", itemID: "widget")), kind: .widget)
            let after = MenuBarPanelEntry(placement: .init(item: .init(pluginID: "example", itemID: "after")), kind: .row)
            let snapshot = PluginPanelWidgetSnapshot(id: widget.id, title: "Legacy", iconName: "circle", iconTint: .blue,
                description: "", helpText: "", descriptionTone: .secondary, span: span, isActive: false, isEnabled: true)
            let layout = ConfiguredMenuBarPanelLayout.placement(entries: [before, widget, after], components: [snapshot],
                features: [row(before.id, compact: false), row(after.id, compact: false)], width: 304)
            let rect = PanelLayoutDestination.frame(try XCTUnwrap(layout.components.first))
            XCTAssertEqual(rect.width, ComponentPanelLayout.itemWidth(for: span))
            XCTAssertEqual(rect.height, ComponentPanelLayout.itemHeight(for: span))
            XCTAssertGreaterThan(rect.minY, try XCTUnwrap(layout.featureFrames[before.id]).maxY)
            XCTAssertGreaterThan(try XCTUnwrap(layout.featureFrames[after.id]).minY, rect.maxY)
        }
    }

    func testFillRowsEndTheFlowAndDropTargetsUseTheRenderedFrames() throws {
        let compact = (0..<4).map { row(String($0)) }
        let full = row("complex", compact: false, width: .fill)
        let rows = Array(compact.prefix(2)) + [full] + Array(compact.suffix(2))
        let entries = rows.map { item in
            MenuBarPanelEntry(placement: .init(item: .init(pluginID: "example", itemID: item.id)), kind: .row)
        }
        // Real row snapshots carry placement identity.
        let snapshots = zip(entries, rows).map { row($0.0.id, compact: $0.1.usesCompactPresentation, width: $0.1.width) }
        let layout = ConfiguredMenuBarPanelLayout.placement(entries: entries, components: [], features: snapshots, width: 800)
        let fullFrame = try XCTUnwrap(layout.featureFrames[entries[2].id])
        XCTAssertEqual(fullFrame.width, 800)
        XCTAssertGreaterThan(fullFrame.minY, 0)
        XCTAssertGreaterThan(try XCTUnwrap(layout.featureFrames[entries[3].id]).minY, fullFrame.maxY)
        let frames = PanelLayoutEntryFrame.frames(entries: entries, placement: layout)
        let geometry = PanelLayoutDropGeometry(frames: frames, width: 800)
        let first = try XCTUnwrap(frames.first)
        XCTAssertEqual(geometry.target(at: CGPoint(x: first.frame.maxX - 1, y: first.frame.midY), rightToLeft: false).offset, 1)
        XCTAssertEqual(geometry.target(at: CGPoint(x: 800 - first.frame.maxX + 1, y: first.frame.midY), rightToLeft: true).offset, 1)
        XCTAssertEqual(geometry.target(at: CGPoint(x: 400, y: fullFrame.maxY - 1), rightToLeft: false).offset, 3)
    }

    func testFlexibleSwitchDropsFollowTheResolvedFrames() throws {
        let entries = (0..<4).map { MenuBarPanelEntry(placement: .init(item: .init(pluginID: "example", itemID: String($0))), kind: .row) }
        let snapshots = entries.map { row($0.id) }
        let layout = ConfiguredMenuBarPanelLayout.placement(entries: entries, components: [], features: snapshots, width: 548)
        let source = try XCTUnwrap(snapshots.last?.compactLayoutWidget)
        let frames = PanelLayoutEntryFrame.frames(entries: entries, placement: layout)
        XCTAssertEqual(frames.map(\.frame), entries.compactMap { layout.featureFrames[$0.id] })
        let vacancies = PanelLayoutWidgetDropTargets.targets(source: source, entries: entries, components: [],
            features: snapshots, frames: frames, width: 548, sourceIsFlexible: true)
        XCTAssertTrue(vacancies.isEmpty)
        let geometry = PanelLayoutDropGeometry(frames: frames, width: 548, vacancies: vacancies)
        let second = try XCTUnwrap(frames.dropFirst().first)
        XCTAssertEqual(geometry.target(at: CGPoint(x: second.frame.minX + 1, y: second.frame.midY), rightToLeft: false).offset, 1)
        XCTAssertEqual(geometry.target(at: CGPoint(x: 548 - second.frame.minX - 1, y: second.frame.midY), rightToLeft: true).offset, 1)
    }

    func testMixedFlowExpandsHostControlsAndPreservesPluginWidgetDimensions() throws {
        let span = PluginPanelWidgetSpan(width: 1, height: 8, grid: .compact)!
        let features = ["switch": row("switch")]
        let placements = PanelAdaptiveFlow.placements(for: [("switch", PanelCompactSwitchLayout.span), ("legacy", span)],
                                                    features: features, width: 548)
        let control = PanelLayoutDestination.frame(try XCTUnwrap(placements.first))
        let widget = PanelLayoutDestination.frame(placements[1])
        XCTAssertEqual(widget.width, ComponentPanelLayout.itemWidth(for: span))
        XCTAssertEqual(widget.height, ComponentPanelLayout.itemHeight(for: span))
        XCTAssertEqual(widget.maxX, 548, accuracy: 0.001)
        XCTAssertEqual(widget.minY, control.minY)
        XCTAssertEqual(control.height, widget.height)
        XCTAssertLessThan(control.maxX, widget.minX)
    }

    func testScreenClampingKeepsWidthIndependentFromContent() {
        let maximum = MenuBarPanelWidth.maximum(visibleFrameWidth: 1024)
        XCTAssertEqual(MenuBarPanelWidth.resolved(preferred: 1600, maximum: maximum), maximum)
        XCTAssertEqual(MenuBarPanelWidth.resolved(preferred: 1600, maximum: 1800), 1600)
        XCTAssertEqual(MenuBarPanelWidth.resolved(preferred: .nan, maximum: maximum), 316)
        XCTAssertEqual(MenuBarPanelWidth.resolved(preferred: 100, maximum: maximum), 316)
    }

    func testItemWidthClampsThePresentationAndMeasuresItsOwnDetailHeight() throws {
        let detail = PluginPanelDetail(controls: [PluginPanelControl(id: "behavior", kind: .segmented,
            options: ["Default", "Keep Display On", "Keep Screen Tools Working"].map {
                PluginPanelControlOption(id: $0, title: $0, subtitle: "A description of this behavior")
            }, selectedOptionID: "Default", dateValue: nil, minimumDate: nil, displayedComponents: nil,
            datePickerStyle: nil, sectionTitle: nil, isEnabled: true)])
        let entry = MenuBarPanelEntry(placement: .init(item: .init(pluginID: "example", itemID: "control")), kind: .row)
        for (preference, expected) in [(nil, CGFloat(438)), (.fill, 900), (.custom(720), 720)] as [(MenuBarPanelItemWidth?, CGFloat)] {
            let snapshot = row(entry.id, compact: false, width: preference, detail: detail)
            let layout = ConfiguredMenuBarPanelLayout.placement(entries: [entry], components: [], features: [snapshot], width: 900)
            let frame = try XCTUnwrap(layout.featureFrames[entry.id])
            XCTAssertEqual(frame.width, expected)
            XCTAssertEqual(frame.height, MenuBarPanelLayout.rowHeight(for: snapshot, width: expected))
            let geometry = PanelLayoutDropGeometry(frames: PanelLayoutEntryFrame.frames(entries: [entry], placement: layout), width: 900)
            // The unused space to the right still provides an insertion after the item.
            XCTAssertEqual(geometry.target(at: CGPoint(x: 890, y: frame.maxY - 1), rightToLeft: false).offset, 1)
        }
        let narrow = row(entry.id, compact: false, width: .custom(720), detail: detail)
        XCTAssertEqual(PanelItemWidthLayout.resolved(narrow.width, available: 304), 304)
        XCTAssertEqual(PanelItemWidthLayout.resolved(narrow.width, available: 900), 720)
        XCTAssertGreaterThan(MenuBarPanelLayout.rowHeight(for: narrow, width: 304), MenuBarPanelLayout.rowHeight(for: narrow, width: 900))
        XCTAssertEqual(PanelItemWidthLayout.resolved(.custom(-20), available: 900), 304)
        XCTAssertEqual(PanelItemWidthLayout.resolved(.custom(.infinity), available: 900), 438)
    }

    func testOrdinaryRowsShareColumnsAndDragInsertionMatchesTheSavedOrder() throws {
        let rows = (0..<8).map { row(String($0), compact: false) }
        let entries = rows.map { MenuBarPanelEntry(placement: .init(item: .init(pluginID: "example", itemID: $0.id)), kind: .row) }
        let snapshots = entries.map { row($0.id, compact: false) }
        for columns in [1, 2, 3, 5] {
            let width = MenuBarPanelWidth.width(forColumns: columns) - MenuBarPanelLayout.outerPadding * 2
            let placement = ConfiguredMenuBarPanelLayout.placement(entries: entries, components: [], features: snapshots, width: width)
            XCTAssertEqual(placement.featureFrames.values.filter { $0.minY == 0 }.count, columns)
            XCTAssertTrue(placement.featureFrames.values.allSatisfy { $0.maxX <= width + 0.001 })
            if columns == 2 {
                let frames = PanelLayoutEntryFrame.frames(entries: entries, placement: placement)
                let first = try XCTUnwrap(frames.first)
                let geometry = PanelLayoutDropGeometry(frames: frames, width: width)
                let target = geometry.target(at: CGPoint(x: first.frame.maxX - 1, y: first.frame.midY), rightToLeft: false)
                XCTAssertEqual(target.offset, 1)
                let reordered = PanelLayoutDestination.moving(entries.last!.id, toOffset: target.offset, in: entries.map(\.id))
                let order = reordered.compactMap { id in entries.first { $0.id == id } }
                let moved = ConfiguredMenuBarPanelLayout.placement(entries: order, components: [], features: snapshots, width: width)
                XCTAssertEqual(moved.featureFrames[entries.last!.id]?.minY, first.frame.minY)
                XCTAssertGreaterThan(try XCTUnwrap(moved.featureFrames[entries.last!.id]).minX, first.frame.minX)
                let rtl = geometry.target(at: CGPoint(x: width - first.frame.maxX + 1, y: first.frame.midY), rightToLeft: true)
                XCTAssertEqual(rtl.offset, target.offset)
            }
        }
        XCTAssertEqual(MenuBarPanelWidth.width(forColumns: 2), 628)
    }

    func testExpandedRowsLeaveNeighborColumnsAvailable() throws {
        let detail = PluginPanelDetail(controls: [PluginPanelControl(id: "choices", kind: .selectList,
            options: (0..<5).map { PluginPanelControlOption(id: String($0), title: String($0)) },
            selectedOptionID: "0", dateValue: nil, minimumDate: nil, displayedComponents: nil,
            datePickerStyle: nil, sectionTitle: nil, isEnabled: true)])
        let items = [row("awake", compact: false, detail: detail)] + (0..<4).map { row(String($0), compact: false) }
        let placement = ConfiguredMenuBarPanelLayout.placement(features: items, width: 616)
        let awake = try XCTUnwrap(placement.featureFrames["awake"])
        let first = try XCTUnwrap(placement.featureFrames["0"])
        let second = try XCTUnwrap(placement.featureFrames["1"])
        XCTAssertEqual(first.minY, awake.minY)
        XCTAssertEqual(second.minX, first.minX)
        XCTAssertLessThan(second.minY, awake.maxY)
        let frames = Array(placement.featureFrames.values)
        for (index, frame) in frames.enumerated() {
            XCTAssertTrue(frames.dropFirst(index + 1).allSatisfy { !frame.intersects($0) })
        }
    }

    func testDropFootprintsMatchCommittedMovesAndCrossPanelInsertions() throws {
        let entries = (0..<5).map {
            MenuBarPanelEntry(placement: .init(item: .init(pluginID: "example", itemID: String($0))), kind: .row)
        }
        let snapshots = entries.enumerated().map { index, entry in
            row(entry.id, compact: index < 2, width: index == 4 ? .custom(500) : nil)
        }
        let widget = MenuBarPanelEntry(placement: .init(item: .init(pluginID: "example", itemID: "widget")), kind: .widget)
        let component = PluginPanelWidgetSnapshot(id: widget.id, title: "Widget", iconName: "circle", iconTint: .blue,
            description: "", helpText: "", descriptionTone: .secondary, span: .twoByOne, isActive: false, isEnabled: true)
        let order = entries + [widget]
        // Protect both host row presentations, a custom width, and a fixed plugin widget.
        for source in [entries[0], entries[2], entries[4], widget] {
            for offset in [0, 2, order.count] {
                let ids = PanelLayoutDestination.moving(source.id, toOffset: offset, in: order.map(\.id))
                let proposed = ids.compactMap { id in order.first { $0.id == id } }
                let placement = ConfiguredMenuBarPanelLayout.placement(entries: proposed,
                    components: [component], features: snapshots, width: 928)
                let expected = try XCTUnwrap(PanelLayoutEntryFrame.frames(entries: proposed, placement: placement)
                    .first { $0.id == source.id }?.frame)
                XCTAssertEqual(PanelLayoutDropFootprint.frame(source: source, offset: offset, entries: order,
                    components: [component], features: snapshots, width: 928), expected)
                let rtl = try XCTUnwrap(PanelLayoutDropFootprint.frame(source: source, offset: offset, entries: order,
                    components: [component], features: snapshots, width: 928, rightToLeft: true))
                XCTAssertEqual(rtl.minX, 928 - expected.maxX)
                XCTAssertEqual(rtl.size, expected.size)
            }
        }
        let transferred = try XCTUnwrap(PanelLayoutDropFootprint.frame(source: widget, offset: 1, entries: entries,
            components: [component], features: snapshots, width: 616))
        let crossPanelOrder = [entries[0], widget] + Array(entries.dropFirst())
        let committed = ConfiguredMenuBarPanelLayout.placement(entries: crossPanelOrder,
            components: [component], features: snapshots, width: 616)
        XCTAssertEqual(transferred, PanelLayoutDestination.frame(try XCTUnwrap(committed.components.first)))
        XCTAssertEqual(transferred.width, ComponentPanelLayout.itemWidth(for: component.span))
    }

    func testSeparatedCompactSwitchesDoNotShiftFullControlsBetweenColumns() throws {
        let entries = (0..<12).map {
            MenuBarPanelEntry(placement: .init(item: .init(pluginID: "example", itemID: String($0))), kind: .row)
        }
        let rows = entries.enumerated().map { row($0.element.id, compact: [4, 8].contains($0.offset)) }
        let layout = ConfiguredMenuBarPanelLayout.placement(entries: entries, components: [], features: rows, width: 928)
        let inset = MenuBarPanelWidth.columnInset(forSurfaceWidth: 928)
        let origins = (0..<3).map { MenuBarPanelWidth.columnOrigin($0, surfaceWidth: 928) + inset }
        for (index, entry) in entries.enumerated() where ![4, 8].contains(index) {
            let frame = try XCTUnwrap(layout.featureFrames[entry.id])
            XCTAssertTrue(origins.contains { abs($0 - frame.minX) < 0.001 })
        }
        let dark = try XCTUnwrap(layout.featureFrames[entries[4].id])
        let night = try XCTUnwrap(layout.featureFrames[entries[8].id])
        XCTAssertEqual(dark.minY, night.minY)
        XCTAssertGreaterThan(night.minX, dark.minX)
    }

    func testLargeWidgetCanLandInEachColumnAndPreparedTargetsMatchSavedResults() throws {
        let span = PluginPanelWidgetSpan(width: 4, height: 24)!
        let entries = (0..<6).map {
            MenuBarPanelEntry(placement: .init(item: .init(pluginID: "example", itemID: String($0))), kind: .widget)
        }
        let widgets = entries.map { PluginPanelWidgetSnapshot(id: $0.id, title: "Widget", iconName: "circle", iconTint: .blue,
            description: "", helpText: "", descriptionTone: .secondary, span: span, isActive: false, isEnabled: true) }
        let layout = ConfiguredMenuBarPanelLayout.placement(entries: entries, components: widgets, features: [], width: 928)
        XCTAssertEqual(layout.components.filter { $0.yOffset == 0 }.count, 3)
        let candidates = PanelLayoutDropCandidates.targets(source: entries[5], entries: entries, components: widgets, features: [], width: 928)
        let geometry = PanelLayoutDropGeometry(frames: PanelLayoutEntryFrame.frames(entries: entries, placement: layout),
            width: 928, candidates: candidates)
        for column in 0..<3 {
            let x = MenuBarPanelWidth.columnOrigin(column, surfaceWidth: 928)
            let point = CGPoint(x: x + ComponentPanelLayout.itemWidth(for: span) / 2,
                                y: min(24, ComponentPanelLayout.itemHeight(for: span) / 2))
            let target = geometry.target(at: point, rightToLeft: false)
            let frame = try XCTUnwrap(target.previewFrame)
            XCTAssertEqual(frame.minX, x)
            XCTAssertEqual(frame.size, CGSize(width: ComponentPanelLayout.itemWidth(for: span), height: ComponentPanelLayout.itemHeight(for: span)))
            XCTAssertEqual(frame, PanelLayoutDropFootprint.frame(source: entries[5], offset: target.offset,
                entries: entries, components: widgets, features: [], width: 928))
            let rtl = geometry.target(at: CGPoint(x: 928 - point.x, y: point.y), rightToLeft: true)
            XCTAssertEqual(rtl.offset, target.offset)
            XCTAssertEqual(rtl.previewFrame?.minX, 928 - frame.maxX)
        }
    }

    func testPreparedTallRowTargetsMatchCommitAcrossPanelsAndStayStableNearAnEdge() throws {
        let entries = (0..<12).map {
            MenuBarPanelEntry(placement: .init(item: .init(pluginID: "example", itemID: String($0))), kind: .row)
        }
        let detail = PluginPanelDetail(controls: [PluginPanelControl(id: "choices", kind: .selectList,
            options: (0..<5).map { .init(id: String($0), title: String($0)) }, selectedOptionID: "0", dateValue: nil,
            minimumDate: nil, displayedComponents: nil, datePickerStyle: nil, sectionTitle: nil, isEnabled: true)])
        let rows = entries.enumerated().map { row($0.element.id, compact: [4, 8].contains($0.offset), detail: $0.offset == 5 ? detail : nil) }
        for crossPanel in [false, true] {
            let destination = crossPanel ? entries.filter { $0.id != entries[5].id } : entries
            let candidates = PanelLayoutDropCandidates.targets(source: entries[5], entries: destination,
                components: [], features: rows, width: 928)
            for candidate in candidates {
                XCTAssertEqual(candidate.previewFrame, PanelLayoutDropFootprint.frame(source: entries[5], offset: candidate.offset,
                    entries: destination, components: [], features: rows, width: 928))
            }
            let geometry = PanelLayoutDropGeometry(frames: [], width: 928, candidates: candidates)
            for column in 0..<3 {
                let origin = MenuBarPanelWidth.columnOrigin(column, surfaceWidth: 928) + MenuBarPanelWidth.columnInset(forSurfaceWidth: 928)
                let target = geometry.target(at: CGPoint(x: origin + 100, y: 150), rightToLeft: false)
                XCTAssertEqual(try XCTUnwrap(target.previewFrame).minX, origin)
                let frame = try XCTUnwrap(target.previewFrame)
                let stable = geometry.target(at: CGPoint(x: frame.midX + 1, y: frame.minY + 25),
                    rightToLeft: false, previousOffset: target.offset)
                XCTAssertEqual(stable.offset, target.offset)
            }
        }
        let wideRows = rows.filter { $0.id != entries[5].id } + [row(entries[5].id, compact: false, width: .custom(500), detail: detail)]
        let wideCandidates = PanelLayoutDropCandidates.targets(source: entries[5], entries: entries,
            components: [], features: wideRows, width: 928)
        let wideGeometry = PanelLayoutDropGeometry(frames: [], width: 928, candidates: wideCandidates)
        let wideTarget = wideGeometry.target(at: CGPoint(x: 464, y: 24), rightToLeft: false)
        XCTAssertEqual(wideTarget.previewFrame?.minX, MenuBarPanelWidth.columnOrigin(1, surfaceWidth: 928) + 4)
        XCTAssertEqual(wideTarget.previewFrame?.width, 500)
        let lowerGrab = wideGeometry.target(at: CGPoint(x: 464, y: try XCTUnwrap(wideTarget.previewFrame).height * 0.8),
            rightToLeft: false, verticalAnchorFraction: 0.8)
        XCTAssertEqual(lowerGrab.offset, wideTarget.offset)
    }
}
