import SwiftUI

/// Abstandsraster für App und Widgets (Vielfache von 4, plus 2 für Feinheiten).
/// Neue Abstände bitte hieraus nehmen statt freier Zahlen.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Feste Maße der Bausteine, damit Karten, Kacheln und Ränder überall gleich sind.
enum Layout {
    /// Seitenrand der Bildschirme und schwebenden Bedienfelder.
    static let screenMargin = Spacing.l
    /// Abstand zwischen Karten auf einer Seite.
    static let sectionSpacing = Spacing.m
    /// Innenabstand einer Karte.
    static let cardPadding = Spacing.l
    /// Abstand zwischen Überschrift und Inhalten in einer Karte.
    static let cardSpacing = Spacing.m
    static let cardRadius: CGFloat = 20
    /// Kacheln innerhalb einer Karte (Messwerte).
    static let tilePadding = Spacing.m
    static let tileSpacing = Spacing.s
    static let tileRadius: CGFloat = 14
}
