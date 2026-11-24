import XCTest
@testable import LFAZGaleria

final class StreamingTests: XCTestCase {
    func testByteRanges() {
        XCTAssertEqual(ByteRange.parse(nil, total: 1000), ByteRange(start: 0, end: 999))
        XCTAssertEqual(ByteRange.parse("bytes=0-1", total: 1000), ByteRange(start: 0, end: 1))
        XCTAssertEqual(ByteRange.parse("bytes=500-", total: 1000), ByteRange(start: 500, end: 999))
        XCTAssertEqual(ByteRange.parse("bytes=900-5000", total: 1000), ByteRange(start: 900, end: 999))
        XCTAssertEqual(ByteRange.parse("bytes=-100", total: 1000), ByteRange(start: 900, end: 999))
        XCTAssertEqual(ByteRange.parse("bytes=0-9, 20-29", total: 1000)?.count, 10)
        XCTAssertNil(ByteRange.parse("bytes=1000-", total: 1000))
        XCTAssertNil(ByteRange.parse("bytes=50-10", total: 1000))
        XCTAssertNil(ByteRange.parse("bytes=0-", total: 0))
    }

    func testMimeTypes() {
        XCTAssertEqual(MediaType.mime("MKV"), "video/x-matroska")
        XCTAssertEqual(MediaType.mime("mov"), "video/quicktime")
        XCTAssertEqual(MediaType.mime("xyz"), "application/octet-stream")
    }
}
