import SwiftUI
import MacToolsPluginKit

enum SettingsPageWidthPolicy {
    case standard
    case general
    case expansive

    var maximumContentWidth: CGFloat {
        switch self {
        case .standard:
            // Complex plugin workspaces and tables can use the wider column.
            960
        case .general:
            // Ordinary preferences benefit from a denser macOS-style column.
            720
        case .expansive:
            // Self-managed workspaces own their layout and can use the viewport.
            .infinity
        }
    }
}

enum SettingsPageLayout {
    static let horizontalInset: CGFloat = 20
    static let verticalInset: CGFloat = 20
    static let introductionContentSpacing: CGFloat = 20

    /// A grouped Form adds 10pt of native card chrome on each side of an
    /// explicitly sized direct row. The host owns this adjustment so plugins
    /// only describe sections and the visible card follows the outer guide.
    static let groupedSectionHorizontalChrome: CGFloat = 20

    static func readableContentWidth(
        for viewportWidth: CGFloat,
        policy: SettingsPageWidthPolicy = .standard
    ) -> CGFloat {
        min(
            max(viewportWidth - horizontalInset * 2, 0),
            policy.maximumContentWidth
        )
    }

    static func groupedSectionLayoutWidth(
        for viewportWidth: CGFloat,
        policy: SettingsPageWidthPolicy = .standard
    ) -> CGFloat {
        max(
            readableContentWidth(
                for: viewportWidth,
                policy: policy
            ) - groupedSectionHorizontalChrome,
            0
        )
    }
}

struct SettingsPageIntroductionConfiguration {
    let description: String
    let descriptionColor: Color
    let descriptionLineLimit: Int?

    init(
        description: String,
        descriptionColor: Color = .secondary,
        descriptionLineLimit: Int? = nil
    ) {
        self.description = description
        self.descriptionColor = descriptionColor
        self.descriptionLineLimit = descriptionLineLimit
    }
}

/// The page shell for readable settings workspaces. It owns the semantic
/// window background and shared content guide; scrolling and page-level
/// introductions remain the responsibility of the supplied content container.
struct SettingsPageScaffold<Content: View>: View {
    private let widthPolicy: SettingsPageWidthPolicy
    private let content: Content

    init(
        widthPolicy: SettingsPageWidthPolicy = .standard,
        @ViewBuilder content: () -> Content
    ) {
        self.widthPolicy = widthPolicy
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(
                maxWidth: widthPolicy.maximumContentWidth,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .padding(.horizontal, SettingsPageLayout.horizontalInset)
            .padding(.vertical, SettingsPageLayout.verticalInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SettingsStyle.contentBackground, ignoresSafeAreaEdges: .all)
    }
}

/// The page shell for native grouped forms. The compact introduction remains
/// an unboxed section header so grouped Form never draws a card behind it.
struct SettingsGroupedFormPageScaffold<IntroductionAccessory: View, Content: View>: View {
    let introduction: SettingsPageIntroductionConfiguration
    private let widthPolicy: SettingsPageWidthPolicy
    private let introductionAccessory: IntroductionAccessory
    private let content: (SettingsGroupedFormWidths) -> Content

    init(
        introduction: SettingsPageIntroductionConfiguration,
        widthPolicy: SettingsPageWidthPolicy = .standard,
        @ViewBuilder introductionAccessory: () -> IntroductionAccessory,
        @ViewBuilder content: @escaping (SettingsGroupedFormWidths) -> Content
    ) {
        self.introduction = introduction
        self.widthPolicy = widthPolicy
        self.introductionAccessory = introductionAccessory()
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let widths = SettingsGroupedFormWidths(
                viewportWidth: geometry.size.width,
                widthPolicy: widthPolicy
            )

            Form {
                Section {
                    EmptyView()
                } header: {
                    SettingsPageIntroduction(configuration: introduction) {
                        introductionAccessory
                    }
                    .frame(width: widths.readableContent, alignment: .leading)
                    .padding(.bottom, PluginSettingsTheme.Spacing.controlCluster)
                }

                content(widths)
            }
            .settingsGroupedFormStyle()
            .contentMargins(
                .bottom,
                SettingsPageLayout.verticalInset,
                for: .scrollContent
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SettingsStyle.contentBackground, ignoresSafeAreaEdges: .all)
    }
}

struct SettingsGroupedFormWidths {
    let readableContent: CGFloat
    let sectionLayout: CGFloat

    init(
        viewportWidth: CGFloat,
        widthPolicy: SettingsPageWidthPolicy
    ) {
        readableContent = SettingsPageLayout.readableContentWidth(
            for: viewportWidth,
            policy: widthPolicy
        )
        sectionLayout = SettingsPageLayout.groupedSectionLayoutWidth(
            for: viewportWidth,
            policy: widthPolicy
        )
    }
}

struct SettingsGroupedFormLayout<Content: View>: View {
    private let widthPolicy: SettingsPageWidthPolicy
    private let content: (SettingsGroupedFormWidths) -> Content

    init(
        widthPolicy: SettingsPageWidthPolicy = .standard,
        @ViewBuilder content: @escaping (SettingsGroupedFormWidths) -> Content
    ) {
        self.widthPolicy = widthPolicy
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            let widths = SettingsGroupedFormWidths(
                viewportWidth: geometry.size.width,
                widthPolicy: widthPolicy
            )

            Form {
                content(widths)
            }
            .settingsGroupedFormStyle()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SettingsStyle.contentBackground, ignoresSafeAreaEdges: .all)
    }
}

extension View {
    func settingsGroupedFormRowWidth(_ width: CGFloat) -> some View {
        frame(width: width)
    }
}

extension SettingsGroupedFormPageScaffold where IntroductionAccessory == EmptyView {
    init(
        introduction: SettingsPageIntroductionConfiguration,
        widthPolicy: SettingsPageWidthPolicy = .standard,
        @ViewBuilder content: @escaping (SettingsGroupedFormWidths) -> Content
    ) {
        self.init(
            introduction: introduction,
            widthPolicy: widthPolicy,
            introductionAccessory: { EmptyView() },
            content: content
        )
    }
}

/// A single header treatment for every grouped Form section owned by the host.
/// The explicit outer width keeps first and later headers aligned while direct
/// rows independently report the narrower width needed by native card chrome.
struct SettingsGroupedFormSectionHeader<Accessory: View>: View {
    let title: String?
    let systemImage: String?
    let layoutWidth: CGFloat
    private let accessory: Accessory

    init(
        title: String?,
        systemImage: String? = nil,
        layoutWidth: CGFloat,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.systemImage = systemImage
        self.layoutWidth = layoutWidth
        self.accessory = accessory()
    }

    var body: some View {
        HStack(
            alignment: .center,
            spacing: PluginSettingsTheme.Spacing.controlCluster
        ) {
            if let title {
                sectionLabel(title)
                    .font(PluginSettingsTheme.Typography.sectionTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: PluginSettingsTheme.Spacing.controlCluster)
            accessory
        }
        .frame(width: layoutWidth, alignment: .leading)
        .textCase(nil)
    }

    @ViewBuilder
    private func sectionLabel(_ title: String) -> some View {
        if let systemImage {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
                    .frame(width: PluginSettingsTheme.Size.rowIcon)
            }
        } else {
            Text(title)
        }
    }
}

extension SettingsGroupedFormSectionHeader where Accessory == EmptyView {
    init(
        title: String?,
        systemImage: String? = nil,
        layoutWidth: CGFloat
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            layoutWidth: layoutWidth,
            accessory: { EmptyView() }
        )
    }
}

struct SettingsPageIntroduction<Accessory: View>: View {
    let configuration: SettingsPageIntroductionConfiguration
    private let accessory: Accessory

    init(
        configuration: SettingsPageIntroductionConfiguration,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.configuration = configuration
        self.accessory = accessory()
    }

    var body: some View {
        HStack(
            alignment: .center,
            spacing: PluginSettingsTheme.Spacing.rowContentControl
        ) {
            Label {
                Text(configuration.description)
                    .lineLimit(configuration.descriptionLineLimit)
                    .truncationMode(.middle)
                    .help(configuration.description)
            } icon: {
                Image(systemName: "info.circle")
                    .frame(width: PluginSettingsTheme.Size.rowIcon)
            }
            .font(PluginSettingsTheme.Typography.pageDescription)
            .foregroundStyle(configuration.descriptionColor)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)

            Spacer(minLength: PluginSettingsTheme.Spacing.controlCluster)

            accessory
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textCase(nil)
    }
}

extension SettingsPageIntroduction where Accessory == EmptyView {
    init(configuration: SettingsPageIntroductionConfiguration) {
        self.init(configuration: configuration, accessory: { EmptyView() })
    }
}

@MainActor
extension Form {
    /// Makes the grouped form share the scaffold's semantic window background
    /// while preserving native section cards and row styling.
    func settingsGroupedFormStyle() -> some View {
        self
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
    }
}
