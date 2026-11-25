import Foundation

/// The rules of the iPhone backup that do not depend on PhotoKit or the network: where each
/// file goes and which name it gets, so nothing on the NAS is ever replaced.
enum BackupPlan {
    /// `Respaldo iPhone/2026/11`: the year and month the photo was taken.
    static func folders(for date: Date, calendar: Calendar = .current) -> [String] {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 1970, month = parts.month ?? 1
        return [URLPolicy.backupFolder, String(year), String(format: "%02d", month)]
    }

    /// A file name the NAS accepts: no folders, no control characters, not hidden.
    static func safeName(_ name: String, fallback: String) -> String {
        var clean = String(name.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(Character.init))
        for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] { clean = clean.replacingOccurrences(of: bad, with: "_") }
        clean = clean.trimmingCharacters(in: .whitespaces)
        while clean.hasPrefix(".") { clean.removeFirst() }
        if clean.isEmpty || clean == ".." { clean = fallback }
        return String(clean.prefix(200))
    }

    /// `IMG_1234.HEIC`, then `IMG_1234 (2).HEIC`, `IMG_1234 (3).HEIC`…
    static func suffixed(_ name: String, _ number: Int) -> String {
        guard number > 1 else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(base) (\(number))" : "\(base) (\(number)).\(ext)"
    }

    /// One name for all the files of a photo (a Live Photo keeps its photo and video
    /// together): the first numbering where every file is either missing on the NAS or
    /// already there with the same size (copied before). Returns the numbering and the
    /// files still to upload.
    static func choose(_ files: [(name: String, size: Int64)], existing: [String: Int64?]) -> (number: Int, upload: [Int]) {
        var number = 1
        while number < 10_000 {
            var upload: [Int] = []
            var fits = true
            for (index, file) in files.enumerated() {
                let key = suffixed(file.name, number).lowercased()
                if let found = existing[key] {
                    if found != file.size { fits = false; break }
                } else {
                    upload.append(index)
                }
            }
            if fits { return (number, upload) }
            number += 1
        }
        return (number, Array(files.indices))
    }

    /// Two files of one photo with the same name (rare) get the second one numbered.
    static func distinctNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.map { name in
            var candidate = name, number = 2
            while !seen.insert(candidate.lowercased()).inserted {
                candidate = suffixed(name, number); number += 1
            }
            return candidate
        }
    }

    /// The upload goes to a temporary name first and is renamed when complete, so an
    /// interrupted upload never leaves a broken photo with the real name.
    static func temporaryName(_ name: String) -> String { "lfaz-subiendo-" + name + ".parcial" }
}
