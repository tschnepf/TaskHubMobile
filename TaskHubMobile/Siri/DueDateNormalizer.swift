import Foundation

struct DueDateNormalizer {
    static func normalizeToLocalNoon(_ date: Date?, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard let date else { return nil }

        let localCalendar = calendar
        let components = localCalendar.dateComponents([.year, .month, .day], from: date)
        let noon = DateComponents(
            timeZone: localCalendar.timeZone,
            year: components.year,
            month: components.month,
            day: components.day,
            hour: 12,
            minute: 0,
            second: 0
        )
        return localCalendar.date(from: noon)
    }
}
