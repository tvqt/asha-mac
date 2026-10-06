// KnownAids.swift — remembers which macOS device ID is the left/right aid.
//
// Why this exists: our Oticon aids' adverts don't say which side they are.
// And once an aid is paired with the Mac, it stops advertising any service at
// all, only its name. So after we've connected to an aid once and read its
// ReadOnlyProperties, we save "this device ID is the RIGHT aid" in a small
// JSON file. Next time we can connect straight to it, no scan needed.
//
// About the IDs: macOS hides real Bluetooth addresses from apps and gives each
// device a UUID instead. For a PAIRED device it stays the same between runs.
// Unpaired aids change address now and then, for privacy, so their ID changes.
//
// File location: ~/.config/asha-mac/known-aids.json

import Foundation

struct KnownAid: Codable {   // Codable = can be converted to/from JSON automatically
    var id: String           // macOS's device UUID, as text
    var side: String         // "left" or "right"
    var hiSyncId: String     // hex; both aids of one pair share it
    var name: String
    var updated: String      // when we last saw it, ISO 8601 text
}

enum KnownAids {
    static let fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/asha-mac/known-aids.json")

    /// Load the list. A missing or unreadable file just means "no known aids".
    static func load() -> [KnownAid] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([KnownAid].self, from: data) else { return [] }
        return list
    }

    /// The known aid for a side, if any.
    static func find(side: Side) -> KnownAid? {
        load().first { $0.side == side.rawValue }
    }

    /// The side we've recorded for a device ID, if any.
    static func side(of id: UUID) -> Side? {
        load().first { $0.id == id.uuidString }.flatMap { Side(rawValue: $0.side) }
    }

    /// Add or update an entry. Called after a successful ReadOnlyProperties read.
    /// Only one aid per side is kept: a new right aid replaces the old one.
    static func record(id: UUID, props: AshaProperties, name: String) {
        var list = load().filter { $0.id != id.uuidString && $0.side != props.side.rawValue }
        list.append(KnownAid(id: id.uuidString, side: props.side.rawValue,
                             hiSyncId: hex(props.hiSyncId), name: name,
                             updated: ISO8601DateFormatter().string(from: Date())))
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]   // human-readable file
            try enc.encode(list).write(to: fileURL)
            log("Remembered: device \(id.uuidString.prefix(8))… is the \(props.side.rawValue.uppercased()) aid (\(fileURL.path))")
        } catch {
            log("Warning: couldn't save \(fileURL.path): \(error.localizedDescription)")
        }
    }
}
