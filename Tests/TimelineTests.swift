import XCTest
import UIKit
import ImageIO
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

final class WallLayoutTests: XCTestCase {
    private func items(_ count: Int) -> [GalleryItem] {
        (0..<count).map { index in
            GalleryItem(id: "i\(index)", source: .phone("i\(index)"), date: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 20_000),
                        kind: .photo, aspect: [0.75, 1, 1.5][index % 3], duration: nil, name: "", bytes: nil, folder: nil)
        }
    }

    func testEveryPhotoIsPlacedOnceAndPeriodsAreCards() {
        let all = items(500)
        let days = WallLayout.build(all, scale: .days, width: 393)
        var ids: [String] = []
        for element in days.elements { if case .tile(let item, _) = element.kind { ids.append(item.id) } }
        XCTAssertEqual(ids.sorted(), all.map(\.id).sorted())
        XCTAssertTrue(days.elements.allSatisfy { $0.frame.maxX <= 393.5 && $0.frame.minX >= 0 })
        // Months and years: one card each.
        for scale in [TimeScale.months, .years] {
            let layout = WallLayout.build(all, scale: scale, width: 393)
            XCTAssertEqual(layout.elements.count, Timeline.sections(all, scale: scale).count, "\(scale)")
            XCTAssertTrue(layout.elements.allSatisfy { if case .card = $0.kind { return true } else { return false } })
        }
    }

    func testVisibleElementsMatchABruteForceSearch() {
        let layout = WallLayout.build(items(800), scale: .days, width: 390)
        for top in stride(from: CGFloat(0), to: layout.height, by: 731) {
            let rect = CGRect(x: 0, y: top, width: 390, height: 844)
            let expected = layout.elements.indices.filter { layout.elements[$0].frame.intersects(rect) }
            XCTAssertEqual(layout.indices(in: rect).sorted(), expected)
        }
    }

    func testFocusOpensAtTheSameDate() {
        let all = items(600)
        let target = all[400].date
        let layout = WallLayout.build(all, scale: .months, width: 390, focus: target)
        let section = Timeline.section(containing: target, in: layout.sections, scale: .months)
        XCTAssertNotNil(layout.initialY)
        XCTAssertEqual(layout.initialY, section.flatMap { layout.sectionTop[$0.id] })
    }
}

final class CaptureReaderTests: XCTestCase {
    func testExifDateUsesTheOffset() {
        let date = CaptureReader.exifDate("2023:05:14 10:15:30", offset: "-06:00")
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2023-05-14T16:15:30Z"))
        XCTAssertNil(CaptureReader.exifDate("0000:00:00 00:00:00", offset: nil))
    }

    func testReadsJPEGMetadata() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30))
        let image = renderer.image { context in UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 30)) }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2021:03:09 18:20:11", kCGImagePropertyExifOffsetTimeOriginal: "+00:00"]
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let info = try XCTUnwrap(CaptureReader.image(data as Data))
        XCTAssertEqual(info.date, ISO8601DateFormatter().date(from: "2021-03-09T18:20:11Z"))
        XCTAssertEqual(info.aspect ?? 0, 40.0 / 30.0, accuracy: 0.01)
    }

    func testReadsMovieHeader() {
        func be(_ value: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8((value >> (8 * UInt64(count - 1 - $0))) & 0xFF) } }
        // 2023-05-14T16:15:30Z in seconds since 1904.
        let created: UInt64 = 1_684_080_930 + 2_082_844_800
        var mvhd: [UInt8] = Array("mvhd".utf8) + [0, 0, 0, 0] + be(created, 4) + be(created, 4) + be(600, 4) + be(600 * 42, 4)
        mvhd += [UInt8](repeating: 0, count: 80)
        var tkhd: [UInt8] = Array("tkhd".utf8) + [0, 0, 0, 0] + [UInt8](repeating: 0, count: 36)
        // A portrait iPhone video: a 90° matrix (a = 0) on a 1920 × 1080 track.
        tkhd += be(0, 4) + be(0x10000, 4) + [UInt8](repeating: 0, count: 28)
        tkhd += be(1920 << 16, 4) + be(1080 << 16, 4)
        let info = CaptureReader.movie(Data([0, 0, 0, 0, 0x6D, 0x6F, 0x6F, 0x76] + mvhd + tkhd))
        XCTAssertEqual(info?.date, ISO8601DateFormatter().date(from: "2023-05-14T16:15:30Z"))
        XCTAssertEqual(info?.duration ?? 0, 42, accuracy: 0.001)
        XCTAssertEqual(info?.aspect ?? 0, 1080.0 / 1920.0, accuracy: 0.001)
    }
}

final class DuplicateTests: XCTestCase {
    private func item(_ id: String, _ seconds: Double, kind: MediaKind = .photo, aspect: Double = 0.75, nas: Bool) -> GalleryItem {
        GalleryItem(id: id, source: nas ? .nas(URL(string: "https://nas.example.com/photo/\(id)")!) : .phone(id),
                    date: Date(timeIntervalSince1970: seconds), kind: kind, aspect: aspect, duration: nil, name: id, bytes: nil, folder: "")
    }

    func testHidesNASCopiesOfIPhonePhotos() {
        let phone = [item("p1", 1_700_000_000.42, nas: false), item("p2", 1_700_000_500, kind: .video, aspect: 0.5625, nas: false)]
        let nas = [
            item("copy", 1_700_000_000, nas: true),                                // same second and shape
            item("video", 1_700_000_501, kind: .video, aspect: 0.5625, nas: true), // a second apart
            item("other", 1_700_000_000, aspect: 1.5, nas: true),                  // another camera, same second
            item("unread", 1_700_000_000, nas: true)                               // date not read from the file
        ]
        let kept = GalleryStore.removingDuplicates(nas, of: phone, checked: ["copy", "video", "other"])
        XCTAssertEqual(kept.map(\.id), ["other", "unread"])
    }
}

final class BarDirectionTests: XCTestCase {
    func testScrollDirectionPicksTheBar() {
        let direction = BarDirection()
        XCTAssertEqual(direction.update(0), false)
        var result: Bool?
        for y in stride(from: CGFloat(10), through: 600, by: 10) { if let value = direction.update(y) { result = value } }
        XCTAssertEqual(result, true, "scrolling down shows Días · Meses · Años")
        result = nil
        for y in stride(from: CGFloat(590), through: 500, by: -10) { if let value = direction.update(y) { result = value } }
        XCTAssertEqual(result, false, "scrolling up brings back the main bar")
        XCTAssertNil(direction.update(4_000), "a jump is not a gesture")
    }
}

final class SpaceTests: XCTestCase {
    func testParsesQuotaFromWebDAV() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:"><D:response><D:href>/home/Photos/</D:href>
        <D:propstat><D:prop><D:quota-available-bytes>1319413953331</D:quota-available-bytes><D:quota-used-bytes>2680586046669</D:quota-used-bytes></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>
        """
        let space = NASTransport.parseSpace(xml)
        XCTAssertEqual(space?.available, 1_319_413_953_331)
        XCTAssertEqual(space?.used, 2_680_586_046_669)
        XCTAssertEqual(space?.total, 4_000_000_000_000)
        XCTAssertNil(NASTransport.parseSpace("<D:multistatus xmlns:D=\"DAV:\"></D:multistatus>"))
    }

    func testScreenshotsAreRecognizedByName() {
        func item(_ name: String) -> GalleryItem {
            GalleryItem(id: name, source: .nas(URL(string: "https://nas.example.com/p/x.png")!), date: Date(), kind: .photo,
                        aspect: 1, duration: nil, name: name, bytes: nil, folder: nil)
        }
        XCTAssertTrue(item("Screenshot_2021-03-09-18-20-11.png").isScreenshot)
        XCTAssertTrue(item("Captura de pantalla 2024-01-02.png").isScreenshot)
        XCTAssertFalse(item("IMG_1234.HEIC").isScreenshot)
    }
}

final class DSMTests: XCTestCase {
    private let account = NASAccount(root: URL(string: "https://lfaz.example.me:5006/home/Photos/")!, username: "u", password: "p",
                                     routeIP: "", tailscaleHost: nil, connectionMode: nil, displayName: nil)

    func testOnlyTheDSMEntryPointOfTheSameNASIsAllowed() {
        XCTAssertTrue(URLPolicy.allowedDSM(URL(string: "https://lfaz.example.me:5001/webapi/entry.cgi?api=SYNO.API.Auth")!, account: account))
        XCTAssertFalse(URLPolicy.allowedDSM(URL(string: "https://lfaz.example.me:5006/webapi/entry.cgi")!, account: account))
        XCTAssertFalse(URLPolicy.allowedDSM(URL(string: "https://other.example.me:5001/webapi/entry.cgi")!, account: account))
        XCTAssertFalse(URLPolicy.allowedDSM(URL(string: "https://lfaz.example.me:5001/webapi/other.cgi")!, account: account))
        XCTAssertFalse(URLPolicy.allowed(URL(string: "https://lfaz.example.me:5001/webapi/entry.cgi")!, root: account.root))
    }

    func testPicksTheShareOfTheFolder() throws {
        let json = """
        {"success":true,"data":{"shares":[
          {"name":"music","path":"/music","additional":{"volume_status":{"freespace":100,"totalspace":1000}}},
          {"name":"home","path":"/home","additional":{"volume_status":{"freespace":1319413953331,"totalspace":4000000000000}}}]}}
        """
        struct Wrapper: Decodable { let data: Inner; struct Inner: Decodable { let shares: [DSMSpace.Share] } }
        let shares = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8)).data.shares
        let space = DSMSpace.space(for: account.root, in: shares)
        XCTAssertEqual(space?.available, 1_319_413_953_331)
        XCTAssertEqual(space?.total, 4_000_000_000_000)
    }
}
