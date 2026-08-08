//
// RootTitle (iOS)
//
// The tab-root title, placed the way Apple Music places its own: large, at
// the top left, on the same line as the buttons at the top right.
//
// `.toolbarTitleDisplayMode(.inlineLarge)` is exactly that layout — a large
// title that stays inside the bar instead of claiming a row below it, which
// `.large` does. Putting a big `Text` in the leading toolbar slot by hand
// looks the same in a mockup but is not: the bar decides that item does not
// fit and collapses it into an overflow "…" button.
//

import SwiftUI

private struct RootTitle: ViewModifier {
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inlineLarge)
    }
}

extension View {
    /// Title for a tab's root screen. Pushed screens keep the ordinary
    /// navigation title with its back button.
    func rootTitle(_ title: String) -> some View {
        modifier(RootTitle(title: title))
    }
}
