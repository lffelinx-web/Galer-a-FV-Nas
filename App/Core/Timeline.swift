import Foundation
import CoreGraphics

enum TimeScale: String, CaseIterable, Identifiable {
    case days, months, years
    var id: String { rawValue }
    var title: String { switch self { case .days: return "Días"; case .months: return "Meses"; case .years: return "Años" } }
}

struct TimelineSection: Identifiable, Equatable {
    let id: String
    let date: Date
    let title: String
    let items: [GalleryItem]
}

/// Groups a newest-first list of items by day, month or year.
enum Timeline {
    static func key(_ date: Date, scale: TimeScale, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let y = c.year ?? 0, m = c.month ?? 1, d = c.day ?? 1
        switch scale {
        case .days: return String(format: "d-%04d-%02d-%02d", y, m, d)
        case .months: return String(format: "m-%04d-%02d", y, m)
        case .years: return String(format: "y-%04d", y)
        }
    }

    static func sections(_ items: [GalleryItem], scale: TimeScale, calendar: Calendar = .current, now: Date = Date()) -> [TimelineSection] {
        var result: [TimelineSection] = []
        var currentKey: String?
        var currentDate = Date()
        var bucket: [GalleryItem] = []
        func flush() {
            guard let key = currentKey, !bucket.isEmpty else { return }
            result.append(TimelineSection(id: key, date: currentDate, title: Self.title(currentDate, scale: scale, calendar: calendar, now: now), items: bucket))
        }
        for item in items {
            let itemKey = Self.key(item.date, scale: scale, calendar: calendar)
            if itemKey != currentKey {
                flush()
                currentKey = itemKey; currentDate = item.date; bucket = []
            }
            bucket.append(item)
        }
        flush()
        return result
    }

    private static let formatters: [String: DateFormatter] = {
        var all: [String: DateFormatter] = [:]
        for format in ["EEEE d 'de' MMMM", "d 'de' MMMM 'de' y", "LLLL y", "y", "HH:mm"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "es_MX")
            formatter.dateFormat = format
            all[format] = formatter
        }
        return all
    }()

    static func format(_ date: Date, _ pattern: String, calendar: Calendar = .current) -> String {
        let formatter = formatters[pattern] ?? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "es_MX")
            formatter.dateFormat = pattern
            return formatter
        }()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date).capitalizedFirst
    }

    static func title(_ date: Date, scale: TimeScale, calendar: Calendar = .current, now: Date = Date()) -> String {
        switch scale {
        case .days:
            if calendar.isDate(date, inSameDayAs: now) { return "Hoy" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Ayer" }
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return format(date, sameYear ? "EEEE d 'de' MMMM" : "d 'de' MMMM 'de' y", calendar: calendar)
        case .months: return format(date, "LLLL y", calendar: calendar)
        case .years: return format(date, "y", calendar: calendar)
        }
    }

    /// The section of `scale` that contains `date`, to keep the place when the scale changes.
    static func section(containing date: Date, in sections: [TimelineSection], scale: TimeScale, calendar: Calendar = .current) -> TimelineSection? {
        let wanted = key(date, scale: scale, calendar: calendar)
        if let exact = sections.first(where: { $0.id == wanted }) { return exact }
        // Sections are newest first: the first one older than the date is the closest below it.
        return sections.first(where: { $0.date < date }) ?? sections.last
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: Mosaic

struct MosaicTile: Equatable {
    let index: Int
    let frame: CGRect
}

struct MosaicBlock: Equatable {
    let tiles: [MosaicTile]
    let height: CGFloat
}

/// The photo wall from the sketch: justified rows of 2–4 photos with, every few rows, a
/// featured block of a tall photo, a large one and two stacked, mirrored every other time.
enum Mosaic {
    static func layout(aspects: [Double], width: CGFloat, spacing: CGFloat = 4, rowHeight: CGFloat = 140, featureEvery: Int = 3) -> [MosaicBlock] {
        guard width > 0 else { return [] }
        var blocks: [MosaicBlock] = []
        var index = 0, row = 0
        let count = aspects.count
        while index < count {
            if featureEvery > 1, row % featureEvery == 1, count - index >= 4 {
                blocks.append(feature(start: index, width: width, spacing: spacing, height: (rowHeight * 1.35).rounded(), mirrored: (row / featureEvery) % 2 == 1))
                index += 4
            } else {
                let (block, used) = justified(aspects: aspects, start: index, width: width, spacing: spacing, rowHeight: rowHeight)
                blocks.append(block)
                index += used
            }
            row += 1
        }
        return blocks
    }

    static func clamp(_ aspect: Double) -> CGFloat {
        guard aspect.isFinite, aspect > 0 else { return 1 }
        return CGFloat(min(max(aspect, 0.7), 1.8))
    }

    private static func justified(aspects: [Double], start: Int, width: CGFloat, spacing: CGFloat, rowHeight: CGFloat) -> (MosaicBlock, Int) {
        var natural: [CGFloat] = []
        var index = start
        while index < aspects.count, natural.count < 4 {
            natural.append(clamp(aspects[index]) * rowHeight)
            index += 1
            if natural.reduce(0, +) + spacing * CGFloat(natural.count - 1) >= width { break }
        }
        let gaps = spacing * CGFloat(natural.count - 1)
        let sum = natural.reduce(0, +)
        var factor = (width - gaps) / sum
        // A short last row keeps its natural size instead of growing huge.
        let last = index >= aspects.count
        if last && factor > 1.6 { factor = 1 }
        let height = (rowHeight * factor).rounded()
        var tiles: [MosaicTile] = []
        var x: CGFloat = 0
        for (offset, value) in natural.enumerated() {
            let isLast = offset == natural.count - 1
            var w = (value * factor).rounded()
            if isLast && factor != 1 { w = width - x }
            tiles.append(MosaicTile(index: start + offset, frame: CGRect(x: x, y: 0, width: max(w, 1), height: height)))
            x += w + spacing
        }
        return (MosaicBlock(tiles: tiles, height: height), natural.count)
    }

    private static func feature(start: Int, width: CGFloat, spacing: CGFloat, height: CGFloat, mirrored: Bool) -> MosaicBlock {
        let side = ((width - spacing * 2) * 0.26).rounded()
        let big = width - spacing * 2 - side * 2
        let half = ((height - spacing) / 2).rounded()
        var frames = [
            CGRect(x: 0, y: 0, width: side, height: height),
            CGRect(x: side + spacing, y: 0, width: big, height: height),
            CGRect(x: width - side, y: 0, width: side, height: half),
            CGRect(x: width - side, y: half + spacing, width: side, height: height - half - spacing)
        ]
        if mirrored { frames = frames.map { CGRect(x: width - $0.maxX, y: $0.minY, width: $0.width, height: $0.height) } }
        return MosaicBlock(tiles: frames.enumerated().map { MosaicTile(index: start + $0.offset, frame: $0.element) }, height: height)
    }
}
