import XCTest
@testable import LFAZGaleria

final class DateGuessTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Mexico_City")!
        return calendar
    }
    private let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026

    private func parts(_ date: Date?) -> [Int]? {
        guard let date else { return nil }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [c.year!, c.month!, c.day!, c.hour!, c.minute!]
    }

    private func guess(_ name: String, _ folders: [String] = []) -> [Int]? {
        parts(DateGuess.date(fileName: name, folders: folders, calendar: calendar, now: now))
    }

    func testCameraNames() {
        XCTAssertEqual(guess("IMG_20230514_101530.jpg"), [2023, 5, 14, 10, 15])
        XCTAssertEqual(guess("PXL_20240102_224511123.jpg"), [2024, 1, 2, 22, 45])
        XCTAssertEqual(guess("20190730_081200.heic"), [2019, 7, 30, 8, 12])
        XCTAssertEqual(guess("IMG-20230514-WA0001.jpg"), [2023, 5, 14, 12, 0])
    }

    func testWrittenDates() {
        XCTAssertEqual(guess("WhatsApp Image 2023-05-14 at 10.15.30.jpeg"), [2023, 5, 14, 10, 15])
        XCTAssertEqual(guess("2022-12-31 23.59.01.png"), [2022, 12, 31, 23, 59])
        XCTAssertEqual(guess("Screenshot_2021-03-09-18-20-11.png"), [2021, 3, 9, 18, 20])
    }

    func testRejectsImpossibleDates() {
        XCTAssertNil(guess("IMG_20230231_101530.jpg"))
        XCTAssertNil(guess("IMG_1234.jpg"))
        XCTAssertNil(guess("DSC_2019.jpg"))
        XCTAssertNil(guess("1690000000123.jpg"))
        XCTAssertNil(guess("IMG_20300101.jpg"))
    }

    func testFolders() {
        XCTAssertEqual(guess("IMG_1234.jpg", ["Fotos", "2023", "05 Mayo"]), [2023, 5, 1, 12, 0])
        XCTAssertEqual(guess("IMG_1234.jpg", ["2021 Mayo"]), [2021, 5, 1, 12, 0])
        XCTAssertEqual(guess("IMG_1234.jpg", ["2020-08 Playa"]), [2020, 8, 1, 12, 0])
        XCTAssertEqual(guess("IMG_1234.jpg", ["2018", "Vacaciones"]), [2018, 1, 1, 12, 0])
        XCTAssertNil(guess("IMG_1234.jpg", ["Vacaciones"]))
    }

    func testNameWinsOverFolder() {
        XCTAssertEqual(guess("IMG_20230514_101530.jpg", ["2010"]), [2023, 5, 14, 10, 15])
    }

    func testNASDateWhenFolderAgrees() {
        let taken = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 18, minute: 23))!
        // Synology backup: «MobileBackup/iPhone/2026/11» with the moment it was taken.
        let backup = DateGuess.resolve(fileName: "IMG_9845.JPG", folders: ["MobileBackup", "iPhone", "2026", "11"], modified: taken, calendar: calendar, now: now)
        XCTAssertEqual(parts(backup.date), [2026, 11, 22, 18, 23]); XCTAssertTrue(backup.exact)
        // Copied years later: the folder says the month, the NAS date is the copy.
        let copied = DateGuess.resolve(fileName: "IMG_1.JPG", folders: ["2019", "05"], modified: taken, calendar: calendar, now: now)
        XCTAssertEqual(parts(copied.date), [2019, 5, 1, 12, 0]); XCTAssertFalse(copied.exact)
        // A year folder accepts any month of that year.
        XCTAssertTrue(DateGuess.resolve(fileName: "IMG_2.JPG", folders: ["2026"], modified: taken, calendar: calendar, now: now).exact)
        // No folder hint: the NAS date, not marked exact.
        let plain = DateGuess.resolve(fileName: "IMG_3.JPG", folders: ["Varios"], modified: taken, calendar: calendar, now: now)
        XCTAssertEqual(parts(plain.date), [2026, 11, 22, 18, 23]); XCTAssertFalse(plain.exact)
    }
}
