import Foundation

/// Guesses when a NAS photo was taken without downloading it: first from the file name
/// (`IMG_20230514_101530.jpg`, `WhatsApp Image 2023-05-14 at 10.15.30.jpeg`), then from
/// folders such as `2023/05` or `2023/Mayo`.
enum DateGuess {
    private static let nameExpression = try! NSRegularExpression(pattern:
        "(?<!\\d)((?:19|20)\\d{2})[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\\d|3[01])(?:[ _T.-]*(?:at[ _]*)?([01]\\d|2[0-3])[-_.:h]?([0-5]\\d)[-_.:m]?([0-5]\\d)\\d{0,3})?(?!\\d)",
        options: [.caseInsensitive])
    private static let yearMonthExpression = try! NSRegularExpression(pattern: "(?<!\\d)((?:19|20)\\d{2})[-_. ]+(0?[1-9]|1[0-2])(?!\\d)")
    private static let yearExpression = try! NSRegularExpression(pattern: "(?<!\\d)((?:19|20)\\d{2})(?!\\d)")
    private static let monthNames: [[String]] = [
        ["enero", "january", "ene", "jan"], ["febrero", "february", "feb"], ["marzo", "march", "mar"],
        ["abril", "april", "abr", "apr"], ["mayo", "may"], ["junio", "june", "jun"], ["julio", "july", "jul"],
        ["agosto", "august", "ago", "aug"], ["septiembre", "setiembre", "september", "sep", "sept"],
        ["octubre", "october", "oct"], ["noviembre", "november", "nov"], ["diciembre", "december", "dic", "dec"]
    ]

    static func date(fileName: String, folders: [String], calendar: Calendar = .current, now: Date = Date()) -> Date? {
        let latest = calendar.component(.year, from: now) + 1
        if let date = fromName(fileName, calendar: calendar, latestYear: latest) { return date }
        return fromFolders(folders, calendar: calendar, latestYear: latest)
    }

    /// The date of a NAS file without reading it, and whether it is exact. The date of the
    /// file on the NAS is trusted when the folder agrees with it (`2026/11` and 22 November):
    /// Synology's iPhone backup gives each file the date it was taken. A folder alone only
    /// says the month, so it is used when the file date does not fit (copied years later).
    static func resolve(fileName: String, folders: [String], modified: Date?, calendar: Calendar = .current, now: Date = Date()) -> (date: Date?, exact: Bool) {
        let latest = calendar.component(.year, from: now) + 1
        if let date = fromName(fileName, calendar: calendar, latestYear: latest) { return (date, false) }
        guard let folder = folderGuess(folders, calendar: calendar, latestYear: latest) else { return (modified, false) }
        if let modified {
            let a = calendar.dateComponents([.year, .month], from: modified), b = calendar.dateComponents([.year, .month], from: folder.date)
            if a.year == b.year && (!folder.month || a.month == b.month) { return (modified, true) }
        }
        return (folder.date, false)
    }

    static func fromName(_ name: String, calendar: Calendar, latestYear: Int) -> Date? {
        let range = NSRange(name.startIndex..., in: name)
        for match in nameExpression.matches(in: name, range: range) {
            func number(_ group: Int) -> Int? {
                guard let r = Range(match.range(at: group), in: name) else { return nil }
                return Int(name[r])
            }
            guard let year = number(1), let month = number(2), let day = number(3), (1990...latestYear).contains(year) else { continue }
            if let date = make(year, month, day, number(4) ?? 12, number(5) ?? 0, number(6) ?? 0, calendar: calendar) { return date }
        }
        return nil
    }

    static func fromFolders(_ folders: [String], calendar: Calendar, latestYear: Int) -> Date? {
        folderGuess(folders, calendar: calendar, latestYear: latestYear)?.date
    }

    /// `month` is false when the folders only name a year.
    static func folderGuess(_ folders: [String], calendar: Calendar, latestYear: Int) -> (date: Date, month: Bool)? {
        // The deepest folder that names a year wins: `Fotos/2023/05 Mayo` → May 2023.
        for (index, folder) in folders.enumerated().reversed() {
            let range = NSRange(folder.startIndex..., in: folder)
            if let match = yearMonthExpression.firstMatch(in: folder, range: range),
               let y = Range(match.range(at: 1), in: folder), let m = Range(match.range(at: 2), in: folder),
               let year = Int(folder[y]), let month = Int(folder[m]), (1990...latestYear).contains(year) {
                return make(year, month, 1, 12, 0, 0, calendar: calendar).map { ($0, true) }
            }
            guard let match = yearExpression.firstMatch(in: folder, range: range), let y = Range(match.range(at: 1), in: folder),
                  let year = Int(folder[y]), (1990...latestYear).contains(year) else { continue }
            let rest = folder[y.upperBound...]
            let next = index + 1 < folders.count ? folders[index + 1] : ""
            let monthNumber = Self.month(in: String(rest)) ?? Self.month(in: next)
            return make(year, monthNumber ?? 1, 1, 12, 0, 0, calendar: calendar).map { ($0, monthNumber != nil) }
        }
        return nil
    }

    /// A month written at the start of a folder name: `05`, `5 - Playa`, `Mayo`, `May 2023`.
    static func month(in text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty {
            guard digits.count <= 2, let value = Int(digits), (1...12).contains(value) else { return nil }
            return value
        }
        let word = trimmed.prefix(while: \.isLetter).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard word.count >= 3 else { return nil }
        return monthNames.firstIndex { $0.contains(word) }.map { $0 + 1 }
    }

    private static func make(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int, calendar: Calendar) -> Date? {
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { return nil }
        // Rejects days that roll over, such as 31 April.
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        return check.year == year && check.month == month && check.day == day ? date : nil
    }
}
