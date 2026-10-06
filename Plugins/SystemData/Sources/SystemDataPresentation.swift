import Foundation

/// Turns raw scan results into the bounded, sorted model the panel and the
/// workspace render.
public enum SystemDataPresentation {
    /// Children probes collapse to this many entries per group; the rest are
    /// folded into one "remaining items" entry so snapshots stay small.
    public static let maximumChildrenPerGroup = 20

    public static func makeGroups(
        definitions: [SystemDataGroupDefinition],
        results: [SystemDataJobResult]
    ) -> [SystemDataGroup] {
        var resultsByID: [String: SystemDataJobResult] = [:]
        for result in results where resultsByID[result.itemID] == nil {
            resultsByID[result.itemID] = result
        }

        var groups: [SystemDataGroup] = []
        for definition in definitions {
            var items: [SystemDataItem] = []
            for itemDefinition in definition.items {
                switch itemDefinition.kind {
                case .path:
                    let result = resultsByID[itemDefinition.id]
                    items.append(
                        SystemDataItem(
                            id: itemDefinition.id,
                            label: itemDefinition.label,
                            path: result?.resolvedPath ?? itemDefinition.path,
                            badge: itemDefinition.badge,
                            status: result?.status ?? .absent
                        )
                    )
                case .children:
                    items.append(
                        contentsOf: childItems(
                            for: itemDefinition,
                            result: resultsByID[itemDefinition.id]
                        )
                    )
                }
            }
            groups.append(
                SystemDataGroup(
                    id: definition.id,
                    label: definition.label,
                    systemImage: definition.systemImage,
                    items: sorted(items)
                )
            )
        }
        return groups.sorted { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.id < rhs.id
        }
    }

    /// Display filter for the "show all items" preference: with it off,
    /// entries that were not found disappear and groups left without entries
    /// are dropped. Summary and badge math keep using the unfiltered groups.
    public static func visible(
        groups: [SystemDataGroup],
        showAllItems: Bool
    ) -> [SystemDataGroup] {
        guard !showAllItems else { return groups }
        return groups.compactMap { group in
            let items = group.items.filter { $0.status != .absent }
            guard !items.isEmpty else { return nil }
            return SystemDataGroup(
                id: group.id,
                label: group.label,
                systemImage: group.systemImage,
                items: items
            )
        }
    }

    public static func makeSummary(
        groups: [SystemDataGroup],
        availableBytes: Int64?,
        capacityBytes: Int64?,
        scannedAt: Date
    ) -> SystemDataScanSummary {
        let items = groups.flatMap(\.items)
        return SystemDataScanSummary(
            totalBytes: groups.reduce(0) { $0 + $1.bytes },
            availableBytes: availableBytes,
            capacityBytes: capacityBytes,
            itemCount: items.count,
            measuredItemCount: items.filter { $0.status.isMeasured }.count,
            scannedAt: scannedAt
        )
    }

    // MARK: - Children

    private static func childItems(
        for definition: SystemDataItemDefinition,
        result: SystemDataJobResult?
    ) -> [SystemDataItem] {
        guard let result else {
            return [
                SystemDataItem(
                    id: definition.id,
                    label: definition.label,
                    path: definition.path,
                    badge: definition.badge,
                    status: .absent
                ),
            ]
        }

        guard !result.children.isEmpty else {
            return [
                SystemDataItem(
                    id: definition.id,
                    label: definition.label,
                    path: result.resolvedPath ?? definition.path,
                    badge: definition.badge,
                    status: result.status
                ),
            ]
        }

        let ordered = result.children.sorted { lhs, rhs in
            // Surface policy-blocked entries first so the size-based cap can
            // never fold them into a fake "measured zero" remainder row.
            if lhs.isUnreadable != rhs.isUnreadable { return lhs.isUnreadable }
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.id < rhs.id
        }
        let visible = ordered.prefix(maximumChildrenPerGroup)
        let remainder = ordered.dropFirst(maximumChildrenPerGroup)

        var items = visible.map { child in
            SystemDataItem(
                id: child.id,
                label: child.isSyntheticFiles
                    ? SystemDataLabel.localized(key: "item.otherFiles", fallback: "其他文件")
                    : SystemDataLabel.literal(child.displayName ?? child.name),
                path: child.path,
                badge: definition.badge,
                status: child.isUnreadable ? .unreadable : .measured(bytes: child.bytes)
            )
        }
        let readableRemainder = remainder.filter { !$0.isUnreadable }
        if !readableRemainder.isEmpty {
            let remainingBytes = readableRemainder.reduce(Int64(0)) { $0 + $1.bytes }
            items.append(
                SystemDataItem(
                    id: definition.id + ".remaining",
                    label: .localized(key: "item.remaining", fallback: "其余项目"),
                    path: definition.path,
                    badge: definition.badge,
                    status: .measured(bytes: remainingBytes)
                )
            )
        }
        if remainder.contains(where: \.isUnreadable) {
            // Blocked entries keep an explicit unreadable row instead of being
            // reported as successfully measured zero bytes. Unreadable-first
            // ordering keeps this path reachable only past the cap.
            items.append(
                SystemDataItem(
                    id: definition.id + ".remainingUnreadable",
                    label: .localized(key: "item.unreadableRemaining", fallback: "其余无法读取项"),
                    path: definition.path,
                    badge: definition.badge,
                    status: .unreadable
                )
            )
        }
        return items
    }

    // MARK: - Sorting

    /// Measured items first, largest first; unavailable entries trail in a
    /// stable order so the list does not shuffle between renders.
    private static func sorted(_ items: [SystemDataItem]) -> [SystemDataItem] {
        items.sorted { lhs, rhs in
            if lhs.status.isMeasured != rhs.status.isMeasured {
                return lhs.status.isMeasured
            }
            if lhs.bytes != rhs.bytes {
                return lhs.bytes > rhs.bytes
            }
            return lhs.id < rhs.id
        }
    }
}
