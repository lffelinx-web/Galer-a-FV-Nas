import Foundation

/// Finds photos from a few words: a year («2023»), a month («mayo»), a day («14»), «hoy» or
/// «ayer», a kind («videos», «capturas», «raw», «live», «favoritos», «iphone», «nas»), a
/// place («Guadalajara», «Jalisco») or any part of a file or folder name. Every word must match.
enum Search {
    private static let months: [[String]] = [
        ["enero", "january", "jan", "ene"], ["febrero", "february", "feb"], ["marzo", "march", "mar"],
        ["abril", "april", "abr", "apr"], ["mayo", "may"], ["junio", "june", "jun"], ["julio", "july", "jul"],
        ["agosto", "august", "ago", "aug"], ["septiembre", "setiembre", "september", "sep", "sept"],
        ["octubre", "october", "oct"], ["noviembre", "november", "nov"], ["diciembre", "december", "dic", "dec"]
    ]
    private static let ignored: Set<String> = ["de", "del", "la", "el", "en", "y", "los", "las", "of", "the"]

    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "es")).lowercased()
    }

    /// The matching items, in the order given (newest first).
    /// `place` gives the name of the place of an item, already normalized.
    static func run(_ query: String, in items: [GalleryItem], favorites: @escaping (GalleryItem) -> Bool,
                    place: @escaping (GalleryItem) -> String? = { _ in nil },
                    calendar: Calendar = .current, now: Date = Date()) -> [GalleryItem] {
        let words = normalize(query).split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init).filter { !ignored.contains($0) }
        guard !words.isEmpty else { return [] }
        let tests = words.map { test(for: $0, favorites: favorites, place: place, calendar: calendar, now: now) }
        return items.filter { item in tests.allSatisfy { $0(item) } }
    }

    private static func test(for word: String, favorites: @escaping (GalleryItem) -> Bool, place: @escaping (GalleryItem) -> String?,
                             calendar: Calendar, now: Date) -> (GalleryItem) -> Bool {
        switch word {
        case "video", "videos": return { $0.isVideo }
        case "foto", "fotos", "imagen", "imagenes": return { !$0.isVideo }
        case "captura", "capturas", "pantallazo", "pantallazos", "screenshot", "screenshots": return { $0.isScreenshot }
        case "live", "livephoto", "livephotos": return { $0.kind == .livePhoto }
        case "raw": return { $0.isRAW }
        case "favorito", "favoritos", "favorita", "favoritas": return favorites
        case "iphone", "telefono", "celular": return { !$0.isNAS }
        case "nas": return { $0.isNAS }
        case "hoy": return { calendar.isDate($0.date, inSameDayAs: now) }
        case "ayer":
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
            return { calendar.isDate($0.date, inSameDayAs: yesterday) }
        default: break
        }
        if word.count == 4, let year = Int(word), (1900...2200).contains(year) {
            return { calendar.component(.year, from: $0.date) == year }
        }
        if word.count <= 2, let day = Int(word), (1...31).contains(day) {
            return { calendar.component(.day, from: $0.date) == day }
        }
        if let month = months.firstIndex(where: { $0.contains(word) }) {
            return { calendar.component(.month, from: $0.date) == month + 1 }
        }
        return { item in
            normalize(item.name).contains(word) || normalize(item.folder ?? "").contains(word) || (place(item)?.contains(word) ?? false)
        }
    }
}
