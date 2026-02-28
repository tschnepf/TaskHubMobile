import SwiftUI

enum WidgetDS {
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
    }

    enum Radius {
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let pill: CGFloat = 999
    }

    enum Typography {
        static let title = Font.system(.subheadline, design: .rounded).weight(.semibold)
        static let body = Font.system(.caption, design: .rounded).weight(.medium)
        static let meta = Font.system(.caption2, design: .rounded).weight(.medium)
    }

    enum Opacity {
        static let tintFillLight = 0.18
        static let tintFillDark = 0.24
        static let tintStrokeLight = 0.24
        static let tintStrokeDark = 0.32
    }
}
