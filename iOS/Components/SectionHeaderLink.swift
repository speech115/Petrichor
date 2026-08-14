//
// SectionHeaderLink (iOS)
//
// The section title that is itself a link: the chevron sits flush against
// the word and the whole row is tappable. There is no "See All" label in
// the corner - the section title is the entry to the full list. Sections
// without a destination use a plain Text instead.
//

import SwiftUI

struct SectionHeaderLink<Value: Hashable>: View {
    let title: String
    let value: Value
    var zoomID: DetailZoomID?
    var zoomNamespace: Namespace.ID?

    var body: some View {
        NavigationLink(value: value) {
            label
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var label: some View {
        let base = HStack(spacing: 4) {
            Text(title)
                .font(.title2.weight(.bold))
            // Decoration: the link's label is the section title alone.
            Image(systemName: "chevron.right")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())

        // Zoom source lives on the label, not the link: on the link itself
        // matchedTransitionSource swallows the tap and the header stops
        // navigating.
        if let zoomID, let zoomNamespace {
            base.detailZoomSource(zoomID, in: zoomNamespace, cornerRadius: 0)
        } else {
            base
        }
    }
}

/// The plain section title used when a section has no full-list destination.
struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title2.weight(.bold))
            .padding(.horizontal, 16)
    }
}
