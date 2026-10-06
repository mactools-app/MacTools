import Foundation
import MacToolsPluginKit
import XCTest
@testable import SystemDataPlugin

final class SystemDataPresentationTests: XCTestCase {
    func testGroupsSortBySizeAndDefaultMissingResultsToAbsent() {
        let definitions = SystemDataTestFixtures.definitions
        let groups = SystemDataPresentation.makeGroups(
            definitions: definitions,
            results: [
                SystemDataJobResult(itemID: "b1", status: .absent),
            ]
        )

        // group-a has no result at all → absent item; group-b absent too.
        XCTAssertEqual(groups.map(\.id), ["group-a", "group-b"])
        XCTAssertEqual(groups[0].items.first?.status, .absent)
        XCTAssertEqual(groups[1].items.first?.status, .absent)
        XCTAssertEqual(groups.flatMap(\.items).count, 2)

        // With measured results the larger group sorts first.
        let measured = SystemDataPresentation.makeGroups(
            definitions: definitions,
            results: SystemDataTestFixtures.result().results
        )
        XCTAssertEqual(measured.map(\.id), ["group-a", "group-b"])
        XCTAssertEqual(measured.map(\.bytes), [1000, 500])
    }

    func testVisibleHidesAbsentEntriesAndDropsEmptyGroupsUnlessShowAll() {
        let definitions = SystemDataTestFixtures.definitions

        // a1 measured + b1 unreadable: found entries stay, including unreadable.
        let mixed = SystemDataPresentation.makeGroups(
            definitions: definitions,
            results: [
                SystemDataJobResult(itemID: "a1", status: .measured(bytes: 1000)),
                SystemDataJobResult(itemID: "b1", status: .unreadable),
            ]
        )
        let hidden = SystemDataPresentation.visible(groups: mixed, showAllItems: false)
        XCTAssertEqual(hidden.map(\.id), ["group-a", "group-b"])
        XCTAssertEqual(hidden.flatMap(\.items).map(\.id), ["a1", "b1"])
        XCTAssertEqual(hidden[1].items.first?.status, .unreadable)

        // b1 measured only: the absent group disappears while the toggle is off.
        let partial = SystemDataPresentation.makeGroups(
            definitions: definitions,
            results: [SystemDataJobResult(itemID: "b1", status: .measured(bytes: 500))]
        )
        XCTAssertEqual(
            SystemDataPresentation.visible(groups: partial, showAllItems: false).map(\.id),
            ["group-b"]
        )
        XCTAssertEqual(
            SystemDataPresentation.visible(groups: partial, showAllItems: true).map(\.id),
            ["group-b", "group-a"]
        )

        // Nothing found: every group is hidden until the toggle turns on.
        let empty = SystemDataPresentation.makeGroups(definitions: definitions, results: [])
        XCTAssertTrue(
            SystemDataPresentation.visible(groups: empty, showAllItems: false).isEmpty
        )
        XCTAssertEqual(
            SystemDataPresentation.visible(groups: empty, showAllItems: true).map(\.id),
            ["group-a", "group-b"]
        )
    }

    func testChildLabelPrefersResolvedDisplayName() {
        let definition = SystemDataGroupDefinition(
            id: "g",
            label: .literal("G"),
            systemImage: "folder",
            items: [
                SystemDataItemDefinition(
                    id: "parent",
                    label: .literal("Parent"),
                    path: "/tmp/parent",
                    badge: .review,
                    kind: .children()
                ),
            ]
        )
        let result = SystemDataJobResult(
            itemID: "parent",
            status: .measured(bytes: 150),
            children: [
                SystemDataChildMeasurement(
                    id: "parent.child.com.docker.docker",
                    name: "com.docker.docker",
                    path: "/tmp/parent/com.docker.docker",
                    bytes: 100,
                    displayName: "Docker"
                ),
                SystemDataChildMeasurement(
                    id: "parent.child.Plain",
                    name: "Plain",
                    path: "/tmp/parent/Plain",
                    bytes: 50
                ),
            ]
        )

        let groups = SystemDataPresentation.makeGroups(
            definitions: [definition],
            results: [result]
        )
        let localization = PluginLocalization(bundle: .main)
        XCTAssertEqual(
            groups[0].items.map { $0.label.resolve(localization) },
            ["Docker", "Plain"]
        )
        // Identity and reveal stay on the raw directory.
        XCTAssertEqual(groups[0].items.map(\.path), [
            "/tmp/parent/com.docker.docker",
            "/tmp/parent/Plain",
        ])
    }

    func testChildrenProbeCapsVisibleEntriesAndAggregatesRemainder() throws {
        let definition = SystemDataGroupDefinition(
            id: "g",
            label: .literal("G"),
            systemImage: "folder",
            items: [
                SystemDataItemDefinition(
                    id: "parent",
                    label: .literal("Parent"),
                    path: "/tmp/parent",
                    badge: .review,
                    kind: .children()
                ),
            ]
        )

        let totalChildren = SystemDataPresentation.maximumChildrenPerGroup + 5
        let children = (0..<totalChildren).map { index in
            SystemDataChildMeasurement(
                id: "parent.child.\(index)",
                name: "child-\(index)",
                path: "/tmp/parent/child-\(index)",
                // Descending sizes keep the order deterministic.
                bytes: Int64(totalChildren - index)
            )
        }
        let result = SystemDataJobResult(
            itemID: "parent",
            status: .measured(bytes: children.reduce(0) { $0 + $1.bytes }),
            children: children
        )

        let groups = SystemDataPresentation.makeGroups(definitions: [definition], results: [result])
        let unwrapped = try XCTUnwrap(groups.first?.items)

        XCTAssertEqual(
            unwrapped.count,
            SystemDataPresentation.maximumChildrenPerGroup + 1
        )
        XCTAssertEqual(unwrapped.first?.label, .literal("child-0"))

        // The remaining entry keeps its own id; display order is size-based,
        // so look it up instead of assuming it trails the list.
        let remaining = unwrapped.first { $0.id == "parent.remaining" }
        XCTAssertEqual(
            remaining?.label,
            .localized(key: "item.remaining", fallback: "其余项目")
        )

        // Remainder bytes: children beyond the cap sum to their total.
        let visibleBytes = children
            .prefix(SystemDataPresentation.maximumChildrenPerGroup)
            .reduce(Int64(0)) { $0 + $1.bytes }
        let totalBytes = children.reduce(Int64(0)) { $0 + $1.bytes }
        XCTAssertEqual(remaining?.bytes, totalBytes - visibleBytes)

        // Group total still equals the whole probe result.
        XCTAssertEqual(groups.first?.bytes, totalBytes)
    }

    func testUnreadableChildrenStayVisiblePastTheCap() throws {
        let definition = SystemDataGroupDefinition(
            id: "g",
            label: .literal("G"),
            systemImage: "folder",
            items: [
                SystemDataItemDefinition(
                    id: "parent",
                    label: .literal("Parent"),
                    path: "/tmp/parent",
                    badge: .review,
                    kind: .children()
                ),
            ]
        )
        let readableCount = SystemDataPresentation.maximumChildrenPerGroup
        var children = (0..<readableCount).map { index in
            SystemDataChildMeasurement(
                id: "parent.child.\(index)",
                name: "child-\(index)",
                path: "/tmp/parent/child-\(index)",
                bytes: Int64(readableCount - index)
            )
        }
        let blocked = (0..<3).map { index in
            SystemDataChildMeasurement(
                id: "parent.blocked.\(index)",
                name: "blocked-\(index)",
                path: "/tmp/parent/blocked-\(index)",
                bytes: 0,
                isUnreadable: true
            )
        }
        children.append(contentsOf: blocked)
        let result = SystemDataJobResult(
            itemID: "parent",
            status: .measured(bytes: children.reduce(0) { $0 + $1.bytes }),
            children: children
        )

        let groups = SystemDataPresentation.makeGroups(definitions: [definition], results: [result])
        let items = try XCTUnwrap(groups.first?.items)

        // Blocked children surface ahead of the size cap instead of being
        // folded into a measured-zero remainder row.
        for child in blocked {
            let item = try XCTUnwrap(items.first { $0.id == child.id })
            XCTAssertEqual(item.status, .unreadable)
        }
        // The remainder only holds readable children and measures them.
        let remaining = try XCTUnwrap(items.first { $0.id == "parent.remaining" })
        XCTAssertEqual(remaining.status, .measured(bytes: 6))
        XCTAssertNil(items.first { $0.id == "parent.remainingUnreadable" })
        // Group totals still add up to the whole probe result.
        XCTAssertEqual(groups.first?.bytes, children.reduce(0) { $0 + $1.bytes })
    }

    func testRemainderKeepsExplicitUnreadableRowPastTheCap() throws {
        let definition = SystemDataGroupDefinition(
            id: "g",
            label: .literal("G"),
            systemImage: "folder",
            items: [
                SystemDataItemDefinition(
                    id: "parent",
                    label: .literal("Parent"),
                    path: "/tmp/parent",
                    badge: .review,
                    kind: .children()
                ),
            ]
        )
        let count = SystemDataPresentation.maximumChildrenPerGroup + 5
        let children = (0..<count).map { index in
            SystemDataChildMeasurement(
                id: "parent.blocked.\(index)",
                name: "blocked-\(index)",
                path: "/tmp/parent/blocked-\(index)",
                bytes: 0,
                isUnreadable: true
            )
        }
        let result = SystemDataJobResult(
            itemID: "parent",
            status: .measured(bytes: 0),
            children: children
        )

        let groups = SystemDataPresentation.makeGroups(definitions: [definition], results: [result])
        let items = try XCTUnwrap(groups.first?.items)

        // No fake measured row: the aggregate reports unreadable explicitly.
        XCTAssertNil(items.first { $0.id == "parent.remaining" })
        let aggregate = try XCTUnwrap(items.first { $0.id == "parent.remainingUnreadable" })
        XCTAssertEqual(aggregate.status, .unreadable)
        XCTAssertEqual(
            aggregate.label,
            .localized(key: "item.unreadableRemaining", fallback: "其余无法读取项")
        )
        // Unreadable rows never fabricate bytes for the group total.
        XCTAssertEqual(groups.first?.bytes, 0)
    }

    func testGroupBadgeUsesStrongestItemBadge() {
        let definitions = SystemDataTestFixtures.definitions
        let groups = SystemDataPresentation.makeGroups(
            definitions: definitions,
            results: SystemDataTestFixtures.result().results
        )
        // group-a: single safe item. group-b: review children badge.
        XCTAssertEqual(groups.first { $0.id == "group-a" }?.badge, .safe)
        XCTAssertEqual(groups.first { $0.id == "group-b" }?.badge, .review)
    }

    func testSummaryCountsMeasuredItems() {
        let groups = SystemDataPresentation.makeGroups(
            definitions: SystemDataTestFixtures.definitions,
            results: [
                SystemDataJobResult(itemID: "a1", status: .measured(bytes: 10)),
                SystemDataJobResult(itemID: "b1", status: .unreadable),
            ]
        )
        let summary = SystemDataPresentation.makeSummary(
            groups: groups,
            availableBytes: 42,
            capacityBytes: 100,
            scannedAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(summary.itemCount, 2)
        XCTAssertEqual(summary.measuredItemCount, 1)
        XCTAssertEqual(summary.totalBytes, 10)
        XCTAssertEqual(summary.scannedAt, Date(timeIntervalSince1970: 0))
    }

    func testByteFormattingProducesStableMetricText() {
        XCTAssertEqual(SystemDataFormatting.bytes(0), "0 B")
        XCTAssertEqual(SystemDataFormatting.bytes(512), "512 B")
        XCTAssertEqual(SystemDataFormatting.bytes(1536), "1.5 KB")
        XCTAssertEqual(SystemDataFormatting.bytes(1024 * 1024 * 1024), "1.0 GB")
        XCTAssertEqual(SystemDataFormatting.bytes(10 * 1024 * 1024 * 1024), "10 GB")
        XCTAssertEqual(SystemDataFormatting.metric(1536).value, "1.5")
        XCTAssertEqual(SystemDataFormatting.metric(1536).unit, "KB")
        XCTAssertEqual(SystemDataFormatting.metric(0).value, "0")
    }

    func testBadgeSeverityMergeIsStrongestWins() {
        XCTAssertLessThan(SystemDataBadge.safe, SystemDataBadge.review)
        XCTAssertLessThan(SystemDataBadge.review, SystemDataBadge.manual)
        XCTAssertEqual(
            SystemDataBadge.safe.merged(with: .review),
            .review
        )
        XCTAssertEqual(
            SystemDataBadge.manual.merged(with: .safe),
            .manual
        )
    }

    func testCatalogExpandsHomeDirectoryPrefix() {
        let home = "/Users/example"
        XCTAssertEqual(SystemDataCatalog.expand(path: "~/Library", home: home), "/Users/example/Library")
        XCTAssertEqual(SystemDataCatalog.expand(path: "~", home: home), home)
        XCTAssertEqual(SystemDataCatalog.expand(path: "/var/log", home: home), "/var/log")
        XCTAssertEqual(SystemDataCatalog.expand(path: "relative", home: home), "relative")
    }

    func testCatalogItemIDsAreUniqueAcrossGroups() {
        var seen: Set<String> = []
        for group in SystemDataCatalog.groups {
            for item in group.items {
                XCTAssertTrue(
                    seen.insert(item.id).inserted,
                    "duplicate catalog item id: \(item.id)"
                )
            }
        }
        // trash, caches, temporary, and packages merged into system/developer.
        XCTAssertGreaterThanOrEqual(SystemDataCatalog.groups.count, 9)
    }

    func testDynamicPathItemsDeclareTheirTools() {
        let items = SystemDataCatalog.groups.flatMap(\.items)
        let gomod = items.first { $0.id == "developer.gomod" }
        XCTAssertEqual(gomod?.path, "~/go/pkg/mod")
        XCTAssertEqual(
            gomod?.pathResolver,
            .toolOutput(executable: "go", arguments: ["env", "GOMODCACHE"])
        )

        let uv = items.first { $0.id == "developer.uvcache" }
        XCTAssertEqual(uv?.path, "~/.cache/uv")
        XCTAssertEqual(
            uv?.pathResolver,
            .toolOutput(executable: "uv", arguments: ["cache", "dir"])
        )
    }

    func testAppDataExcludesDirectoriesClaimedByOtherItems() throws {
        let items = SystemDataCatalog.groups.flatMap(\.items)
        let appData = try XCTUnwrap(items.first { $0.id == "appdata.root" })
        // MobileSync is claimed by the backups group and the Apple container
        // by the containers group; scanning either again would double-count
        // its bytes inside Application Support.
        XCTAssertEqual(
            appData.kind,
            .children(excluding: ["MobileSync", "com.apple.container"])
        )
        let appleContainer = try XCTUnwrap(items.first { $0.id == "docker.applecontainer" })
        XCTAssertEqual(
            appleContainer.path,
            "~/Library/Application Support/com.apple.container"
        )
    }

    func testResolvedPathOverridesDefinitionTemplate() {
        let overridden = SystemDataPresentation.makeGroups(
            definitions: SystemDataTestFixtures.definitions,
            results: [
                SystemDataJobResult(
                    itemID: "a1",
                    status: .measured(bytes: 42),
                    resolvedPath: "/custom/module-cache"
                ),
            ]
        )
        XCTAssertEqual(
            overridden.first { $0.id == "group-a" }?.items.first?.path,
            "/custom/module-cache"
        )

        // Without a dynamic resolution the display keeps the static template,
        // so Finder reveal still expands `~` the same way.
        let templated = SystemDataPresentation.makeGroups(
            definitions: SystemDataTestFixtures.definitions,
            results: [SystemDataJobResult(itemID: "a1", status: .measured(bytes: 1))]
        )
        XCTAssertEqual(
            templated.first { $0.id == "group-a" }?.items.first?.path,
            "/tmp/system-data-fixture/a1"
        )
    }
}
