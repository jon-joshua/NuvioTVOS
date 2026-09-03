import SwiftUI

/// Plex-style navigation rail overlaid on the left edge: an icon column that
/// expands to icon + label while it has focus, over a gradient scrim so
/// content art can bleed underneath and stay legible. The TV pattern
/// Netflix, Plex and the Android Nuvio app use; tvOS has no widget for it,
/// so it is a focus section of plain buttons.
///
/// Host it in a `ZStack` above the content and inset the content's leading
/// safe area by `collapsedWidth`; the rail never pushes the content, which
/// is what keeps the expand animation cheap.
///
/// `isFocused` reports whether focus is anywhere on the rail; setting
/// `focusRequest` moves focus to the selected item (used by Menu).
enum NavigationRailMetrics {
    static let collapsedWidth: CGFloat = 25
    /// Where every screen's content starts, measured from the safe-area edge:
    /// clear of the collapsed rail's icons with some air. Screens read this
    /// instead of choosing their own leading inset.
    static let contentLeading: CGFloat = 50
    /// tvOS lays content out inside an 80pt horizontal safe area at 1080p.
    static let safeAreaLeading: CGFloat = 80
    /// Leading padding that centres the icon glyphs in the lane between the
    /// physical edge and the content: lane centre minus the glyph centre
    /// (18pt button padding + half a 44pt icon).
    static var edgeInset: CGFloat { (safeAreaLeading + contentLeading) / 2 - 40 }
    /// How far the page slides right while the rail is open.
    static let openShift: CGFloat = 250
    /// Gap between the expanded rail's highlight and the shifted content.
    static let expandedGap: CGFloat = 24
    /// The rail fills everything up to the shifted content: the slide plus
    /// the content's own gutter, minus the gap.
    static var expandedWidth: CGFloat { openShift + safeAreaLeading + contentLeading - expandedGap }
}

struct NavigationRail<Icon: View>: View {
    @Binding var selection: TVTab
    @Binding var isFocused: Bool
    @Binding var focusRequest: Bool
    let title: (TVTab) -> String
    @ViewBuilder let icon: (TVTab) -> Icon

    @FocusState private var focusedTab: TVTab?

    private var isExpanded: Bool { focusedTab != nil }
    private var width: CGFloat { isExpanded ? NavigationRailMetrics.expandedWidth : NavigationRailMetrics.collapsedWidth }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(TVTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 20) {
                        icon(tab)
                            .font(.system(size: 30, weight: .semibold))
                            .frame(width: 44, height: 44)
                        if isExpanded {
                            Text(title(tab))
                                .font(.system(size: 26, weight: .semibold))
                                .lineLimit(1)
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        }
                    }
                    .foregroundColor(color(for: tab))
                    .padding(.vertical, 12)
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(focusedTab == tab ? 0.16 : 0))
                    )
                }
                .buttonStyle(RailButtonStyle())
                .focused($focusedTab, equals: tab)
                .accessibilityLabel(title(tab))
            }
        }
        .padding(.leading, NavigationRailMetrics.edgeInset)
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: .infinity)
        .ignoresSafeArea(edges: .leading)
        .background(alignment: .leading) { scrim }
        .focusSection()
        .animation(NuvioMotion.drawer, value: isExpanded)
        .onChange(of: focusedTab) { _, tab in isFocused = tab != nil }
        .onChange(of: focusRequest) { _, requested in
            guard requested else { return }
            focusedTab = selection
            focusRequest = false
        }
    }

    /// Left-edge gradient: keeps icons legible over art bleeding under the
    /// rail, and deepens while expanded to fade the content behind the labels.
    private var scrim: some View {
        LinearGradient(
            colors: [
                .black.opacity(isExpanded ? 0.92 : 0.70),
                .black.opacity(isExpanded ? 0.72 : 0.35),
                .clear
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: width + 160)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func color(for tab: TVTab) -> Color {
        if tab == selection { return .accentColor }
        return focusedTab == tab ? .white : .white.opacity(0.55)
    }
}

/// Renders only the label: no system platter, no lift. The rail draws its
/// own focus highlight and tint.
private struct RailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

// MARK: - Page shift, for screens that want their backdrop to hold still

private struct NavigationRailShiftKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// How far the page is currently slid right for the open rail. A screen
    /// that draws a full-bleed backdrop counter-offsets it by this amount so
    /// only its content moves, Plex-style. Zero while the rail is closed.
    var navigationRailShift: CGFloat {
        get { self[NavigationRailShiftKey.self] }
        set { self[NavigationRailShiftKey.self] = newValue }
    }
}
