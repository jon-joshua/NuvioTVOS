import SwiftUI

/// A horizontal row that keeps one item pinned to the leading margin: the
/// tvOS "focused card sits under the row title" layout, done by the system.
/// Owns only the scroll mechanics — lazy layout, the pin, the animation.
/// The caller owns the cards, their size, and their focus wiring, and drives
/// `pinnedID` from its focus callback (and sets it to the first item to reset).
struct PinnedHorizontalRow<Item: Identifiable, Card: View>: View {
    let items: [Item]
    let spacing: CGFloat
    /// Distance from the row's leading edge to the pinned item.
    let leadingMargin: CGFloat
    /// Extend the scrollable area past the row's trailing edge (e.g. to the
    /// physical screen edge) so cards run off-screen instead of stopping short.
    var trailingBleed: CGFloat = 0
    var animation: Animation? = NuvioMotion.scroll
    @Binding var pinnedID: Item.ID?
    @ViewBuilder let card: (Int, Item) -> Card

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    card(index, item)
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollPosition(id: $pinnedID, anchor: .leading)
        .contentMargins(.leading, leadingMargin, for: .scrollContent)
        .padding(.trailing, -trailingBleed)
        .animation(animation, value: pinnedID)
    }
}
