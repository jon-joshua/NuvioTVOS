import SwiftUI

/// Motion tokens. Semantic names, not durations: a call site says what is
/// moving, the token says how. Tune the feel here, never at a call site.
/// The tvOS counterpart of the Android app's `NuvioTokens.Motion`.
enum NuvioMotion {
    /// Focus highlight on a control: the platform's own quickness.
    static let focus: Animation = .easeOut(duration: 0.14)
    /// A card growing on focus.
    static let focusScale: Animation = .spring(response: 0.28, dampingFraction: 0.75)
    /// A row pinning the focused card. Per press, so it must feel immediate.
    static let scroll: Animation = .easeOut(duration: 0.22)
    /// The navigation rail opening or closing, and the page shifting with it.
    static let drawer: Animation = .easeInOut(duration: 0.38)
    /// The whole page settling: rows resetting to the start, the list
    /// returning to the top.
    static let settle: Animation = .easeInOut(duration: 0.45)
    /// One screen replacing another: a tab change, entering or leaving Search.
    static let screen: Animation = .easeInOut(duration: 0.30)
}
