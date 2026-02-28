import SwiftUI

enum DS {
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
    }

    enum Radius {
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 18
        static let pill: CGFloat = 999
    }

    enum Motion {
        static let quick = Animation.spring(response: 0.22, dampingFraction: 0.88)
        static let smooth = Animation.spring(response: 0.35, dampingFraction: 0.84)
    }

    enum Typography {
        static let headline = Font.system(.title3, design: .rounded).weight(.semibold)
        static let body = Font.system(.body, design: .rounded)
        static let caption = Font.system(.caption, design: .rounded).weight(.medium)
    }

    enum Colors {
        static let surface = Color(.secondarySystemBackground)
        static let elevated = Color(.tertiarySystemBackground)
        static let accent = Color(red: 0.01, green: 0.54, blue: 0.55)
        static let accentAlt = Color(red: 0.07, green: 0.35, blue: 0.94)
        static let danger = Color(red: 0.73, green: 0.13, blue: 0.13)
        static let success = Color(red: 0.12, green: 0.58, blue: 0.22)
        static let warning = Color(red: 0.91, green: 0.53, blue: 0.05)
    }
}
