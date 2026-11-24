import XCTest
@testable import LFAZGaleria

final class TimelineTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func item(_ id: String, _ y: Int, _ m: Int, _ d: Int, aspect: Double = 1) -> GalleryItem {
        let date = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
        return GalleryItem(id: id, source: .phone(id), date: date, kind: .photo, aspect: aspect, duration: nil, name: id, bytes: nil, folder: nil)
    }

    func testGroupsByScale() {
        let items = [item("a", 2024, 3, 2), item("b", 2024, 3, 2), item("c", 2024, 3, 1), item("d", 2023, 12, 25)]
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let days = Timeline.sections(items, scale: .days, calendar: calendar, now: now)
        XCTAssertEqual(days.map(\.id), ["d-2024-03-02", "d-2024-03-01", "d-2023-12-25"])
        XCTAssertEqual(days[0].items.map(\.id), ["a", "b"])
        XCTAssertEqual(Timeline.sections(items, scale: .months, calendar: calendar, now: now).map(\.id), ["m-2024-03", "m-2023-12"])
        XCTAssertEqual(Timeline.sections(items, scale: .years, calendar: calendar, now: now).map(\.id), ["y-2024", "y-2023"])
    }

    func testTodayTitle() {
        let now = calendar.date(from: DateComponents(year: 2024, month: 3, day: 2, hour: 18))!
        let sections = Timeline.sections([item("a", 2024, 3, 2), item("b", 2024, 3, 1)], scale: .days, calendar: calendar, now: now)
        XCTAssertEqual(sections.map(\.title).prefix(2), ["Hoy", "Ayer"])
        XCTAssertEqual(Timeline.sections([item("a", 2023, 5, 14)], scale: .years, calendar: calendar, now: now).first?.title, "2023")
    }

    func testSectionContainingDateFallsBackToNearestOlder() {
        let items = [item("a", 2024, 3, 2), item("c", 2024, 1, 10), item("d", 2023, 12, 25)]
        let months = Timeline.sections(items, scale: .months, calendar: calendar)
        let february = calendar.date(from: DateComponents(year: 2024, month: 2, day: 5))!
        XCTAssertEqual(Timeline.section(containing: february, in: months, scale: .months, calendar: calendar)?.id, "m-2024-01")
        XCTAssertEqual(Timeline.section(containing: items[0].date, in: months, scale: .months, calendar: calendar)?.id, "m-2024-03")
    }
}

final class MosaicTests: XCTestCase {
    func testPlacesEveryPhotoOnceInsideTheWidth() {
        let aspects = (0..<137).map { [0.5, 0.75, 1, 1.33, 1.5, 2.4][$0 % 6] }
        let width: CGFloat = 385
        let blocks = Mosaic.layout(aspects: aspects, width: width)
        let indexes = blocks.flatMap { $0.tiles.map(\.index) }
        XCTAssertEqual(indexes, Array(0..<137))
        for block in blocks {
            XCTAssertFalse(block.tiles.isEmpty)
            for tile in block.tiles {
                XCTAssertGreaterThanOrEqual(tile.frame.minX, 0)
                XCTAssertLessThanOrEqual(tile.frame.maxX, width + 0.5)
                XCTAssertLessThanOrEqual(tile.frame.maxY, block.height + 0.5)
                XCTAssertGreaterThan(tile.frame.width, 20)
            }
        }
    }

    func testFullRowsFillTheWidth() {
        let blocks = Mosaic.layout(aspects: Array(repeating: 1.0, count: 40), width: 390, featureEvery: 0)
        for block in blocks.dropLast() { XCTAssertEqual(block.tiles.last!.frame.maxX, 390, accuracy: 0.5) }
    }

    func testFeatureBlockUsesFourPhotos() {
        let blocks = Mosaic.layout(aspects: Array(repeating: 1.0, count: 12), width: 390)
        XCTAssertEqual(blocks[1].tiles.count, 4)
    }

    func testEmptyAndSingle() {
        XCTAssertTrue(Mosaic.layout(aspects: [], width: 390).isEmpty)
        XCTAssertEqual(Mosaic.layout(aspects: [1], width: 390).first?.tiles.count, 1)
    }
}

final class NASTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(MediaFormat.kind(ofExtension: "HEIC"), .photo)
        XCTAssertEqual(MediaFormat.kind(ofExtension: "dng"), .photo)
        XCTAssertEqual(MediaFormat.kind(ofExtension: "MOV"), .video)
        XCTAssertNil(MediaFormat.kind(ofExtension: "txt"))
    }

    func testHiddenNames() {
        XCTAssertTrue(NASScanner.hidden("@eaDir"))
        XCTAssertTrue(NASScanner.hidden("#recycle"))
        XCTAssertTrue(NASScanner.hidden("._IMG_1.jpg"))
        XCTAssertFalse(NASScanner.hidden("2023"))
    }

    func testLivePhotoMovieIsHidden() {
        func make(_ name: String, _ kind: MediaKind) -> GalleryItem {
            GalleryItem(id: name, source: .nas(URL(string: "https://nas.example.com/photo/2023/\(name)")!), date: Date(), kind: kind,
                        aspect: 1, duration: nil, name: name, bytes: nil, folder: "2023")
        }
        let items = [make("IMG_1.HEIC", .photo), make("IMG_1.MOV", .video), make("IMG_2.MOV", .video)]
        XCTAssertEqual(NASScanner.removeLivePhotoVideos(items).map(\.name), ["IMG_1.HEIC", "IMG_2.MOV"])
    }

    func testSynologyThumbnailPath() {
        let url = URL(string: "https://nas.example.com:5006/photo/2023/Mi%20foto.jpg")!
        XCTAssertEqual(NASImageLoader.synologyThumbnailURL(url).absoluteString,
                       "https://nas.example.com:5006/photo/2023/@eaDir/Mi%20foto.jpg/SYNOPHOTO_THUMB_XL.jpg")
        let root = URL(string: "https://nas.example.com:5006/photo/")!
        XCTAssertTrue(URLPolicy.allowed(NASImageLoader.synologyThumbnailURL(url), root: root))
    }

    func testFolderTree() {
        func make(_ folder: String, _ name: String) -> GalleryItem {
            GalleryItem(id: folder + name, source: .nas(URL(string: "https://nas.example.com/photo/\(name)")!), date: Date(), kind: .photo,
                        aspect: 1, duration: nil, name: name, bytes: nil, folder: folder)
        }
        let items = [make("", "a.jpg"), make("2023", "b.jpg"), make("2023/Playa", "c.jpg"), make("2024", "d.jpg")]
        let root = FolderTree.children(of: "", in: items)
        XCTAssertEqual(root.folders.map(\.name), ["2023", "2024"])
        XCTAssertEqual(root.folders.first?.count, 2)
        XCTAssertEqual(root.files.map(\.name), ["a.jpg"])
        let year = FolderTree.children(of: "2023", in: items)
        XCTAssertEqual(year.folders.map(\.path), ["2023/Playa"])
        XCTAssertEqual(year.files.map(\.name), ["b.jpg"])
    }
}

final class WebDAVTests: XCTestCase {
    /// A folder with thousands of photos returns a listing of several megabytes.
    func testParsesLargeFolderListing() throws {
        let folder = URL(string: "https://nas.example.com:5006/home/Photos/")!
        var xml = "<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\">"
        for index in 0..<12_000 {
            xml += "<d:response><d:href>/home/Photos/IMG_\(String(format: "%05d", index)).HEIC</d:href><d:propstat><d:prop>"
            xml += "<d:displayname>IMG_\(String(format: "%05d", index)).HEIC</d:displayname><d:resourcetype/><d:getcontentlength>2345678</d:getcontentlength>"
            xml += "<d:getlastmodified>Sun, 14 May 2023 10:15:30 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        }
        xml += "</d:multistatus>"
        let data = Data(xml.utf8)
        XCTAssertGreaterThan(data.count, 2_000_000)
        let entries = try DAVParser.parse(data, folder: folder)
        XCTAssertEqual(entries.count, 12_000)
        XCTAssertEqual(entries.first?.kind, .photo)
    }
}
