import CryptoKit
import CoreFoundation
import Foundation

enum MenuBarPanelThemeAppearance: String, Codable, CaseIterable, Sendable {
    case light
    case dark
}

enum MenuBarPanelThemeOrigin: String, Codable, Sendable {
    case builtIn
    case imported
}

struct MenuBarPanelThemeColor: Codable, Equatable, Hashable, Sendable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: String) throws {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        if value.lowercased().hasPrefix("0x") {
            value.removeFirst(2)
        }

        guard value.count == 6, let packed = UInt32(value, radix: 16) else {
            throw MenuBarPanelThemeImportError.invalidColor(hex)
        }

        red = UInt8((packed >> 16) & 0xFF)
        green = UInt8((packed >> 8) & 0xFF)
        blue = UInt8(packed & 0xFF)
    }

    var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var relativeLuminance: Double {
        func linearize(_ component: UInt8) -> Double {
            let value = Double(component) / 255
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * linearize(red)
            + 0.7152 * linearize(green)
            + 0.0722 * linearize(blue)
    }

    func contrastRatio(with other: MenuBarPanelThemeColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    func mixed(with other: MenuBarPanelThemeColor, amount: Double) -> MenuBarPanelThemeColor {
        let amount = min(max(amount, 0), 1)
        let inverse = 1 - amount

        func component(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
            UInt8((Double(lhs) * inverse + Double(rhs) * amount).rounded())
        }

        return MenuBarPanelThemeColor(
            red: component(red, other.red),
            green: component(green, other.green),
            blue: component(blue, other.blue)
        )
    }

    func adjusted(
        toward target: MenuBarPanelThemeColor,
        minimumContrast: Double,
        against backgrounds: [MenuBarPanelThemeColor]
    ) -> MenuBarPanelThemeColor {
        guard !backgrounds.isEmpty else {
            return self
        }

        func meetsContrast(_ color: MenuBarPanelThemeColor) -> Bool {
            backgrounds.allSatisfy { color.contrastRatio(with: $0) >= minimumContrast }
        }

        guard !meetsContrast(self), meetsContrast(target) else {
            return self
        }

        var lowerBound = 0.0
        var upperBound = 1.0
        for _ in 0..<14 {
            let candidateAmount = (lowerBound + upperBound) / 2
            if meetsContrast(mixed(with: target, amount: candidateAmount)) {
                upperBound = candidateAmount
            } else {
                lowerBound = candidateAmount
            }
        }

        return mixed(with: target, amount: upperBound)
    }
}

struct MenuBarPanelThemeDefinition: Codable, Equatable, Hashable, Identifiable, Sendable {
    static let systemThemeID = "system-default"

    let id: String
    let name: String
    let author: String?
    let origin: MenuBarPanelThemeOrigin
    let palette: [String: MenuBarPanelThemeColor]

    var appearance: MenuBarPanelThemeAppearance {
        guard let background = color("base00"), let foreground = color("base05") else {
            return .light
        }
        return background.relativeLuminance > foreground.relativeLuminance ? .light : .dark
    }

    var isBase24: Bool {
        (0x10...0x17).contains { palette[String(format: "base%02X", $0)] != nil }
    }

    func color(_ key: String) -> MenuBarPanelThemeColor? {
        palette[key.uppercasedBaseKey]
    }
}

enum MenuBarPanelBuiltInThemes {
    static let all: [MenuBarPanelThemeDefinition] = [
        make(
            id: "one-light",
            name: "One Light",
            author: "Atom / Base16 community",
            colors: [
                "FAFAFA", "F0F0F1", "E5E5E6", "A0A1A7",
                "696C77", "383A42", "202227", "090A0B",
                "CA1243", "D75F00", "C18401", "50A14F",
                "0184BC", "4078F2", "A626A4", "986801"
            ]
        ),
        make(
            id: "vscode-light-modern",
            name: "VS Code Light Modern",
            author: "Microsoft",
            colors: [
                "FFFFFF", "F3F3F3", "E5E5E5", "8C8C8C",
                "616161", "242424", "1F1F1F", "000000",
                "C72E0F", "A15C00", "795E26", "008000",
                "16825D", "005FB8", "811F3F", "800000"
            ]
        ),
        make(
            id: "github-light",
            name: "GitHub Light",
            author: "GitHub",
            colors: [
                "FFFFFF", "F6F8FA", "EAEEF2", "8C959F",
                "6E7781", "24292F", "1F2328", "0D1117",
                "CF222E", "BC4C00", "9A6700", "1A7F37",
                "1B7C83", "0969DA", "8250DF", "A40E26"
            ]
        ),
        make(
            id: "solarized-light",
            name: "Solarized Light",
            author: "Ethan Schoonover",
            colors: [
                "FDF6E3", "EEE8D5", "93A1A1", "839496",
                "657B83", "586E75", "073642", "002B36",
                "DC322F", "CB4B16", "B58900", "859900",
                "2AA198", "268BD2", "6C71C4", "D33682"
            ]
        ),
        make(
            id: "catppuccin-latte",
            name: "Catppuccin Latte",
            author: "Catppuccin",
            colors: [
                "EFF1F5", "E6E9EF", "CCD0DA", "9CA0B0",
                "8C8FA1", "4C4F69", "DC8A78", "7287FD",
                "D20F39", "FE640B", "DF8E1D", "40A02B",
                "179299", "1E66F5", "8839EF", "DD7878"
            ]
        ),
        make(
            id: "one-dark",
            name: "One Dark",
            author: "Atom / Base16 community",
            colors: [
                "282C34", "353B45", "3E4451", "545862",
                "565C64", "ABB2BF", "B6BDCA", "C8CCD4",
                "E06C75", "D19A66", "E5C07B", "98C379",
                "56B6C2", "61AFEF", "C678DD", "BE5046"
            ]
        ),
        make(
            id: "vscode-dark-modern",
            name: "VS Code Dark Modern",
            author: "Microsoft",
            colors: [
                "1F1F1F", "252526", "2D2D30", "6A6A6A",
                "A0A0A0", "D4D4D4", "E5E5E5", "FFFFFF",
                "F48771", "CEA252", "DCDCAA", "89D185",
                "4EC9B0", "75BEFF", "C586C0", "D16969"
            ]
        ),
        make(
            id: "github-dark",
            name: "GitHub Dark",
            author: "GitHub",
            colors: [
                "0D1117", "161B22", "21262D", "484F58",
                "8B949E", "C9D1D9", "F0F6FC", "FFFFFF",
                "FF7B72", "D29922", "E3B341", "3FB950",
                "39C5CF", "58A6FF", "BC8CFF", "DB6D28"
            ]
        ),
        make(
            id: "solarized-dark",
            name: "Solarized Dark",
            author: "Ethan Schoonover",
            colors: [
                "002B36", "073642", "586E75", "657B83",
                "839496", "93A1A1", "EEE8D5", "FDF6E3",
                "DC322F", "CB4B16", "B58900", "859900",
                "2AA198", "268BD2", "6C71C4", "D33682"
            ]
        ),
        make(
            id: "catppuccin-mocha",
            name: "Catppuccin Mocha",
            author: "Catppuccin",
            colors: [
                "1E1E2E", "181825", "313244", "45475A",
                "585B70", "CDD6F4", "F5E0DC", "B4BEFE",
                "F38BA8", "FAB387", "F9E2AF", "A6E3A1",
                "94E2D5", "89B4FA", "CBA6F7", "F2CDCD"
            ]
        )
    ]

    private static func make(
        id: String,
        name: String,
        author: String,
        colors: [String]
    ) -> MenuBarPanelThemeDefinition {
        precondition(colors.count == 16)
        let palette = Dictionary(uniqueKeysWithValues: colors.enumerated().map { index, hex in
            let key = String(format: "base%02X", index)
            return (key, try! MenuBarPanelThemeColor(hex: hex))
        })
        return MenuBarPanelThemeDefinition(
            id: "builtin.\(id)",
            name: name,
            author: author,
            origin: .builtIn,
            palette: palette
        )
    }
}

enum MenuBarPanelThemeImportError: LocalizedError, Equatable {
    case fileTooLarge
    case unreadableFile
    case unsupportedDocument
    case missingName
    case missingColor(String)
    case invalidColor(String)
    case insufficientForegroundContrast(Double)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            return AppL10n.settings(
                "panelTheme.error.fileTooLarge",
                defaultValue: "主题文件过大。"
            )
        case .unreadableFile:
            return AppL10n.settings(
                "panelTheme.error.unreadableFile",
                defaultValue: "无法读取主题文件。"
            )
        case .unsupportedDocument:
            return AppL10n.settings(
                "panelTheme.error.unsupportedDocument",
                defaultValue: "不支持此主题格式。请选择 .itermcolors、Base16/Base24 YAML 或 JSON 文件。"
            )
        case .missingName:
            return AppL10n.settings(
                "panelTheme.error.missingName",
                defaultValue: "主题文件缺少名称（name 或 scheme）。"
            )
        case let .missingColor(key):
            return AppL10n.settingsFormat(
                "panelTheme.error.missingColor",
                defaultValue: "主题文件缺少必要颜色 %@。",
                key
            )
        case let .invalidColor(value):
            return AppL10n.settingsFormat(
                "panelTheme.error.invalidColor",
                defaultValue: "主题包含无效颜色：%@",
                value
            )
        case let .insufficientForegroundContrast(ratio):
            return AppL10n.settingsFormat(
                "panelTheme.error.insufficientContrast",
                defaultValue: "主题前景与背景对比度只有 %.2f:1，至少需要 4.5:1。",
                ratio
            )
        }
    }
}

enum MenuBarPanelThemeImporter {
    static let maximumFileSize = 256 * 1024

    static func decode(contentsOf url: URL) throws -> MenuBarPanelThemeDefinition {
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = resourceValues?.fileSize, size > maximumFileSize {
            throw MenuBarPanelThemeImportError.fileTooLarge
        }

        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            throw MenuBarPanelThemeImportError.unreadableFile
        }
        defer { try? fileHandle.close() }

        let data: Data
        do {
            data = try fileHandle.read(upToCount: maximumFileSize + 1) ?? Data()
        } catch {
            throw MenuBarPanelThemeImportError.unreadableFile
        }
        guard data.count <= maximumFileSize else {
            throw MenuBarPanelThemeImportError.fileTooLarge
        }

        return try decode(data: data, suggestedName: suggestedThemeName(for: url))
    }

    static func decode(
        data: Data,
        suggestedName: String? = nil
    ) throws -> MenuBarPanelThemeDefinition {
        guard data.count <= maximumFileSize else {
            throw MenuBarPanelThemeImportError.fileTooLarge
        }

        let prefix = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: documentLeadingCharacters)
        if data.starts(with: Data("bplist".utf8))
            || prefix.hasPrefix("<?xml")
            || prefix.hasPrefix("<!DOCTYPE")
            || prefix.hasPrefix("<plist") {
            return try decodeITermColors(data: data, suggestedName: suggestedName)
        }

        if prefix.hasPrefix("{") || prefix.hasPrefix("[") {
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else {
                throw MenuBarPanelThemeImportError.unsupportedDocument
            }
            let fields = flattenedJSONFields(dictionary)
            guard containsBasePalette(fields) else {
                throw MenuBarPanelThemeImportError.unsupportedDocument
            }
            return try decodeBaseTheme(fields: fields)
        }

        guard let source = String(data: data, encoding: .utf8) else {
            throw MenuBarPanelThemeImportError.unsupportedDocument
        }
        let fields = parseYAMLFields(source)
        guard containsBasePalette(fields) else {
            throw MenuBarPanelThemeImportError.unsupportedDocument
        }
        return try decodeBaseTheme(fields: fields)
    }

    private static func decodeBaseTheme(
        fields: [String: String]
    ) throws -> MenuBarPanelThemeDefinition {
        let name = fields["name"] ?? fields["scheme"]
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw MenuBarPanelThemeImportError.missingName
        }

        var palette: [String: MenuBarPanelThemeColor] = [:]
        for index in 0...0x17 {
            let key = String(format: "base%02X", index)
            guard let value = fields[key.lowercased()] else {
                if index <= 0x0F {
                    throw MenuBarPanelThemeImportError.missingColor(key)
                }
                continue
            }
            palette[key] = try MenuBarPanelThemeColor(hex: value)
        }

        return try importedTheme(
            name: name,
            author: fields["author"],
            palette: palette
        )
    }

    private static func decodeITermColors(
        data: Data,
        suggestedName: String?
    ) throws -> MenuBarPanelThemeDefinition {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let object = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ), let dictionary = object as? [String: Any] else {
            throw MenuBarPanelThemeImportError.unsupportedDocument
        }

        let hasITermColorKeys = dictionary["Background Color"] != nil
            || dictionary.keys.contains { $0.hasPrefix("Ansi ") && $0.hasSuffix(" Color") }
        guard hasITermColorKeys else {
            throw MenuBarPanelThemeImportError.unsupportedDocument
        }

        let background = try itermColor(named: "Background Color", in: dictionary)
        let foreground = try itermColor(named: "Foreground Color", in: dictionary)
        let ansi = try (0..<16).map { index in
            try itermColor(named: "Ansi \(index) Color", in: dictionary)
        }
        let selection = try optionalITermColor(named: "Selection Color", in: dictionary)
        let bold = try optionalITermColor(named: "Bold Color", in: dictionary)

        let endpointCandidates = [foreground, bold, ansi[0], ansi[7], ansi[8], ansi[15]]
            .compactMap { $0 }
        let contrastEndpoint = endpointCandidates.max { lhs, rhs in
            lhs.contrastRatio(with: background) < rhs.contrastRatio(with: background)
        } ?? foreground
        let selectedSurface = constrainedSurface(
            selection ?? background.mixed(with: foreground, amount: 0.14),
            background: background,
            foreground: foreground
        )

        // iTerm palettes define terminal roles rather than Base16 UI surfaces.
        // Derive a restrained neutral ramp from the configured background and
        // foreground, then preserve the ANSI hues for semantic status colors.
        var palette: [String: MenuBarPanelThemeColor] = [
            "base00": background,
            "base01": background.mixed(with: foreground, amount: 0.07),
            "base02": selectedSurface,
            "base03": background.mixed(with: foreground, amount: 0.46),
            "base04": background.mixed(with: foreground, amount: 0.72),
            "base05": foreground,
            "base06": bold ?? foreground.mixed(with: contrastEndpoint, amount: 0.35),
            "base07": contrastEndpoint,
            "base08": ansi[1],
            "base09": ansi[9],
            "base0A": ansi[3],
            "base0B": ansi[2],
            "base0C": ansi[6],
            "base0D": ansi[4],
            "base0E": ansi[5],
            "base0F": ansi[14]
        ]
        for index in 8..<16 {
            palette[String(format: "base%02X", 0x10 + index - 8)] = ansi[index]
        }

        let name = normalizedNonemptyString(dictionary["Name"] as? String)
            ?? normalizedNonemptyString(suggestedName)
        guard let name else {
            throw MenuBarPanelThemeImportError.missingName
        }

        return try importedTheme(
            name: name,
            author: normalizedNonemptyString(dictionary["Author"] as? String),
            palette: palette
        )
    }

    private static func importedTheme(
        name: String,
        author: String?,
        palette: [String: MenuBarPanelThemeColor]
    ) throws -> MenuBarPanelThemeDefinition {
        guard let background = palette["base00"], let foreground = palette["base05"] else {
            throw MenuBarPanelThemeImportError.unsupportedDocument
        }
        let contrast = foreground.contrastRatio(with: background)
        guard contrast >= 4.5 else {
            throw MenuBarPanelThemeImportError.insufficientForegroundContrast(contrast)
        }

        let normalized = (0...0x17).compactMap { index -> String? in
            let key = String(format: "base%02X", index)
            return palette[key].map { "\(key)=\($0.hex)" }
        }.joined(separator: "|")
        let digest = SHA256.hash(data: Data("\(name)|\(normalized)".utf8))
        let digestPrefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()

        return MenuBarPanelThemeDefinition(
            id: "imported.\(digestPrefix)",
            name: name,
            author: author,
            origin: .imported,
            palette: palette
        )
    }

    private static func itermColor(
        named name: String,
        in dictionary: [String: Any]
    ) throws -> MenuBarPanelThemeColor {
        guard let value = dictionary[name] else {
            throw MenuBarPanelThemeImportError.missingColor(name)
        }
        guard let components = value as? [String: Any] else {
            throw MenuBarPanelThemeImportError.invalidColor(name)
        }

        func component(_ key: String) throws -> UInt8 {
            guard let number = components[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw MenuBarPanelThemeImportError.invalidColor(name)
            }
            let value = number.doubleValue
            guard value.isFinite, (0...1).contains(value) else {
                throw MenuBarPanelThemeImportError.invalidColor(name)
            }
            return UInt8((value * 255).rounded())
        }

        return try MenuBarPanelThemeColor(
            red: component("Red Component"),
            green: component("Green Component"),
            blue: component("Blue Component")
        )
    }

    private static func optionalITermColor(
        named name: String,
        in dictionary: [String: Any]
    ) throws -> MenuBarPanelThemeColor? {
        guard dictionary[name] != nil else {
            return nil
        }
        return try itermColor(named: name, in: dictionary)
    }

    private static func constrainedSurface(
        _ target: MenuBarPanelThemeColor,
        background: MenuBarPanelThemeColor,
        foreground: MenuBarPanelThemeColor
    ) -> MenuBarPanelThemeColor {
        guard foreground.contrastRatio(with: target) < 4.5 else {
            return target
        }

        var lowerBound = 0.0
        var upperBound = 1.0
        for _ in 0..<12 {
            let amount = (lowerBound + upperBound) / 2
            let candidate = background.mixed(with: target, amount: amount)
            if foreground.contrastRatio(with: candidate) >= 4.5 {
                lowerBound = amount
            } else {
                upperBound = amount
            }
        }
        return background.mixed(with: target, amount: lowerBound)
    }

    private static func containsBasePalette(_ fields: [String: String]) -> Bool {
        fields.keys.contains { key in
            guard key.hasPrefix("base"), key.count == 6 else {
                return false
            }
            return Int(key.dropFirst(4), radix: 16) != nil
        }
    }

    private static func suggestedThemeName(for url: URL) -> String? {
        var nameURL = url.deletingPathExtension()
        if nameURL.pathExtension.lowercased() == "itermcolors" {
            nameURL.deletePathExtension()
        }
        return normalizedNonemptyString(nameURL.lastPathComponent)
    }

    private static func normalizedNonemptyString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static let documentLeadingCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}"))

    private static func flattenedJSONFields(_ dictionary: [String: Any]) -> [String: String] {
        var fields: [String: String] = [:]
        for (key, value) in dictionary {
            if let string = value as? String {
                fields[key.lowercased()] = string
            } else if let nested = value as? [String: Any], key.lowercased() == "palette" {
                for (nestedKey, nestedValue) in nested {
                    if let string = nestedValue as? String {
                        fields[nestedKey.lowercased()] = string
                    }
                }
            }
        }
        return fields
    }

    private static func parseYAMLFields(_ source: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in source.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else {
                continue
            }

            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            guard key != "palette" else {
                continue
            }
            let rawValue = String(trimmed[trimmed.index(after: colon)...])
            let value = cleanedYAMLScalar(rawValue)
            if !value.isEmpty {
                fields[key] = value
            }
        }
        return fields
    }

    private static func cleanedYAMLScalar(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespaces)
        if let quote = value.first, quote == "\"" || quote == "'" {
            value.removeFirst()
            if let closingQuote = value.firstIndex(of: quote) {
                return String(value[..<closingQuote])
            }
            return value
        }

        if value.hasPrefix("#"), value.dropFirst().count >= 6 {
            return String(value.prefix(7))
        }
        if let commentRange = value.range(of: " #") {
            value = String(value[..<commentRange.lowerBound])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }
}

private extension String {
    var uppercasedBaseKey: String {
        guard lowercased().hasPrefix("base") else {
            return self
        }
        return "base" + dropFirst(4).uppercased()
    }
}
