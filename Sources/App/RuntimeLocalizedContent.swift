import MacToolsPluginKit
import SwiftUI

/// Native hosting boundaries do not inherit the presenting view's runtime language.
struct RuntimeLocalizedContent<Content: View>: View {
    @ObservedObject private var runtimeLocale = PluginRuntimeLocalization.source
    let content: Content

    var body: some View {
        let _ = runtimeLocale.revision
        let locale = runtimeLocale.locale
        content
            .environment(\.locale, locale)
            .environment(
                \.layoutDirection,
                locale.language.characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
            )
    }
}
