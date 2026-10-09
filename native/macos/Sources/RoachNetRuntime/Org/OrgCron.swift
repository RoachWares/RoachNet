import Foundation

/// Five-field cron (minute hour day-of-month month day-of-week) evaluated in a
/// time zone. Supports `*`, lists, ranges, steps, month/day names and the
/// @hourly/@daily/@weekly/@monthly/@yearly shortcuts. Day-of-month and
/// day-of-week combine with OR when both are restricted, as in Vixie cron.
struct OrgCron {
    let minutes: Set<Int>
    let hours: Set<Int>
    let days: Set<Int>
    let months: Set<Int>
    let weekdays: Set<Int>
    let dayRestricted: Bool
    let weekdayRestricted: Bool
    let timeZone: TimeZone

    private static let monthNames = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
    private static let dayNames = ["sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6]
    private static let shortcuts = ["@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *", "@weekly": "0 0 * * 0", "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *"]

    init(_ expression: String, timezone: String = "UTC") throws {
        guard let zone = TimeZone(identifier: timezone) else { throw orgInvalid("Unknown time zone \(timezone).") }
        timeZone = zone
        let trimmed = expression.trimmingCharacters(in: .whitespaces).lowercased()
        let expanded = OrgCron.shortcuts[trimmed] ?? trimmed
        let fields = expanded.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5 else { throw orgInvalid("Cron expressions need five fields.") }
        minutes = try OrgCron.parse(fields[0], 0, 59, [:])
        hours = try OrgCron.parse(fields[1], 0, 23, [:])
        days = try OrgCron.parse(fields[2], 1, 31, [:])
        months = try OrgCron.parse(fields[3], 1, 12, OrgCron.monthNames)
        let rawWeekdays = try OrgCron.parse(fields[4], 0, 7, OrgCron.dayNames)
        weekdays = Set(rawWeekdays.map { $0 == 7 ? 0 : $0 })
        dayRestricted = fields[2] != "*" && fields[2] != "?"
        weekdayRestricted = fields[4] != "*" && fields[4] != "?"
    }

    private static func value(_ token: String, _ names: [String: Int]) throws -> Int {
        if let number = Int(token) { return number }
        if let named = names[token] { return named }
        throw orgInvalid("Invalid cron value '\(token)'.")
    }

    private static func parse(_ field: String, _ low: Int, _ high: Int, _ names: [String: Int]) throws -> Set<Int> {
        var result = Set<Int>()
        for part in field.split(separator: ",").map(String.init) {
            let pieces = part.split(separator: "/", maxSplits: 1).map(String.init)
            let step = pieces.count == 2 ? (Int(pieces[1]) ?? 0) : 1
            guard step >= 1 else { throw orgInvalid("Invalid cron step in '\(part)'.") }
            var start = low, end = high
            let range = pieces[0]
            if range != "*" && range != "?" {
                let bounds = range.split(separator: "-", maxSplits: 1).map(String.init)
                start = try value(bounds[0], names)
                end = bounds.count == 2 ? try value(bounds[1], names) : (pieces.count == 2 ? high : start)
            }
            guard start >= low, end <= high, start <= end else { throw orgInvalid("Cron value out of range in '\(part)'.") }
            var current = start
            while current <= end { result.insert(current); current += step }
        }
        guard !result.isEmpty else { throw orgInvalid("Empty cron field.") }
        return result
    }

    func matches(_ components: DateComponents) -> Bool {
        guard let minute = components.minute, let hour = components.hour, let day = components.day,
              let month = components.month, let weekday = components.weekday else { return false }
        guard minutes.contains(minute), hours.contains(hour), months.contains(month) else { return false }
        let dayOK = days.contains(day), weekdayOK = weekdays.contains(weekday - 1)
        if dayRestricted && weekdayRestricted { return dayOK || weekdayOK }
        if dayRestricted { return dayOK }
        if weekdayRestricted { return weekdayOK }
        return true
    }

    /// The first matching minute strictly after `date`, searched up to ~4 years ahead.
    func next(after date: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = date.timeIntervalSince1970
        var candidate = Date(timeIntervalSince1970: (start / 60).rounded(.down) * 60 + 60)
        let limit = candidate.addingTimeInterval(4 * 366 * 86_400)
        while candidate < limit {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: candidate)
            guard let month = parts.month, let hour = parts.hour else { return nil }
            if !months.contains(month) {
                // Jump to the first day of next month.
                var next = DateComponents(); next.year = parts.year; next.month = month + 1; next.day = 1; next.hour = 0; next.minute = 0
                candidate = calendar.date(from: next) ?? candidate.addingTimeInterval(86_400)
                continue
            }
            let dayMatches = matchesDay(parts)
            if !dayMatches {
                var next = DateComponents(); next.year = parts.year; next.month = parts.month; next.day = (parts.day ?? 1) + 1; next.hour = 0; next.minute = 0
                candidate = calendar.date(from: next) ?? candidate.addingTimeInterval(86_400)
                continue
            }
            if !hours.contains(hour) {
                candidate = calendar.date(byAdding: .minute, value: 60 - (parts.minute ?? 0), to: candidate) ?? candidate.addingTimeInterval(3_600)
                continue
            }
            if matches(parts) { return candidate }
            candidate = candidate.addingTimeInterval(60)
        }
        return nil
    }

    private func matchesDay(_ parts: DateComponents) -> Bool {
        guard let day = parts.day, let weekday = parts.weekday else { return false }
        let dayOK = days.contains(day), weekdayOK = weekdays.contains(weekday - 1)
        if dayRestricted && weekdayRestricted { return dayOK || weekdayOK }
        if dayRestricted { return dayOK }
        if weekdayRestricted { return weekdayOK }
        return true
    }
}
