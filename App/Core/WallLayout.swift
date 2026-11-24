import Foundation
import CoreGraphics

/// One thing on the photo wall, already placed: a photo, a day or month title, or a year card.
struct WallElement {
    enum Kind {
        case tile(GalleryItem, corner: CGFloat)
        case header(TimelineSection)
        /// A month or a year: a large cover photo with its title.
        case card(TimelineSection)
    }
    let kind: Kind
    let frame: CGRect
    let date: Date
}

/// A horizontal strip of the wall. Strips are stacked top to bottom without gaps in the
/// list, so finding what is on screen is a binary search.
struct WallBand {
    let minY: CGFloat
    let maxY: CGFloat
    let range: Range<Int>
}

/// The whole wall measured in advance: every frame of every photo. Built off the main
/// thread; the collection view only asks for what is on screen.
struct WallLayout {
    static let spacing: CGFloat = 4

    var elements: [WallElement] = []
    var bands: [WallBand] = []
    var height: CGFloat = 0
    var sectionTop: [String: CGFloat] = [:]
    var sections: [TimelineSection] = []
    var scale = TimeScale.days
    /// Where to open the new layout, so changing the scale keeps your place.
    var initialY: CGFloat?

    static func build(_ items: [GalleryItem], scale: TimeScale, width: CGFloat, focus: Date? = nil, calendar: Calendar = .current) -> WallLayout {
        var layout = WallLayout()
        layout.scale = scale
        guard width > 0 else { return layout }
        let sections = Timeline.sections(items, scale: scale, calendar: calendar)
        layout.sections = sections
        let pad = spacing
        let inner = width - pad * 2
        var y: CGFloat = 0
        var elements: [WallElement] = []
        var bands: [WallBand] = []
        elements.reserveCapacity(items.count + sections.count)

        func add(_ new: [WallElement], top: CGFloat, bottom: CGFloat) {
            guard !new.isEmpty else { return }
            let start = elements.count
            elements.append(contentsOf: new)
            bands.append(WallBand(minY: top, maxY: bottom, range: start..<elements.count))
        }

        for section in sections {
            layout.sectionTop[section.id] = y
            switch scale {
            case .days:
                let headerHeight: CGFloat = 44
                add([WallElement(kind: .header(section), frame: CGRect(x: 0, y: y, width: width, height: headerHeight), date: section.date)], top: y, bottom: y + headerHeight)
                y += headerHeight
                for block in Mosaic.layout(aspects: section.items.map(\.aspect), width: inner, spacing: spacing) {
                    let tiles = block.tiles.map { tile in
                        WallElement(kind: .tile(section.items[tile.index], corner: 8),
                                    frame: tile.frame.offsetBy(dx: pad, dy: y), date: section.items[tile.index].date)
                    }
                    add(tiles, top: y, bottom: y + block.height + spacing)
                    y += block.height + spacing
                }
            case .months, .years:
                let cardHeight: CGFloat = scale == .years ? 300 : 232
                if y == 0 { y = 6 }
                add([WallElement(kind: .card(section), frame: CGRect(x: pad + 4, y: y, width: inner - 8, height: cardHeight), date: section.date)],
                    top: y, bottom: y + cardHeight + 12)
                y += cardHeight + 12
            }
        }
        layout.elements = elements
        layout.bands = bands
        layout.height = y
        if let focus, let section = Timeline.section(containing: focus, in: sections, scale: scale, calendar: calendar) {
            layout.initialY = layout.sectionTop[section.id]
        }
        return layout
    }

    /// Where the section that holds `date` starts, or the closest one before it.
    func top(for date: Date, calendar: Calendar = .current) -> CGFloat? {
        Timeline.section(containing: date, in: sections, scale: scale, calendar: calendar).flatMap { sectionTop[$0.id] }
    }

    /// The first band that reaches `y`.
    func bandIndex(at y: CGFloat) -> Int? {
        guard !bands.isEmpty else { return nil }
        var low = 0, high = bands.count - 1
        while low < high {
            let mid = (low + high) / 2
            if bands[mid].maxY <= y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The elements that intersect `rect`, for the collection view.
    func indices(in rect: CGRect) -> [Int] {
        guard var band = bandIndex(at: rect.minY) else { return [] }
        var result: [Int] = []
        while band < bands.count, bands[band].minY <= rect.maxY {
            for index in bands[band].range where elements[index].frame.intersects(rect) { result.append(index) }
            band += 1
        }
        return result
    }

    /// The date shown at `y`, to keep the place when the scale changes.
    func date(at y: CGFloat) -> Date? {
        guard let band = bandIndex(at: max(y, 0)), let first = bands[band].range.first else { return nil }
        return elements[first].date
    }
}
