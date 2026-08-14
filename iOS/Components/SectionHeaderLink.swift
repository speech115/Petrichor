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
    /// The single caller always zooms the header into its playlist detail, so
    /// these are non-optional: the source/id pair can't be half-set.
    let zoomID: DetailZoomID
    let zoomNamespace: Namespace.ID

    var body: some View {
        NavigationLink(value: value) {
            HStack(spacing: 4) {
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
            // navigating. Zero radius — a text header has no cover to round.
            .detailZoomSource(zoomID, in: zoomNamespace, cornerRadius: 0)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
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
