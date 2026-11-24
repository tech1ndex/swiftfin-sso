//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

struct OfflineWatchUpdate: Codable {

    let serverID: String
    let userID: String
    let itemID: String
    let positionTicks: Int
    let recordedAt: Date
    let completed: Bool
    let revision: UUID
}

@MainActor
final class OfflineWatchQueue {

    static let shared = OfflineWatchQueue(directory: URL.applicationSupportDirectory.appending(
        path: "OfflineWatchQueue",
        directoryHint: .isDirectory
    ))

    private let directory: URL
    private var fileURL: URL {
        directory.appending(path: "updates.json")
    }

    init(directory: URL) {
        self.directory = directory
    }

    func record(serverID: String, userID: String, itemID: String, seconds: Double, completed: Bool) throws {
        let ticks = completed ? 0 : max(0, seconds) * 10_000_000
        guard seconds.isFinite, let positionTicks = Int(exactly: ticks.rounded(.down)) else {
            throw CocoaError(.coderInvalidValue)
        }

        var updates = try read()
        let index = updates.firstIndex { $0.serverID == serverID && $0.userID == userID && $0.itemID == itemID }
        let update = OfflineWatchUpdate(
            serverID: serverID,
            userID: userID,
            itemID: itemID,
            positionTicks: positionTicks,
            recordedAt: Date(),
            completed: completed || index.map { updates[$0].completed } == true,
            revision: UUID()
        )
        if let index {
            updates[index] = update
        } else {
            updates.append(update)
        }
        try write(updates)
    }

    func entries(serverID: String, userID: String) throws -> [OfflineWatchUpdate] {
        try read().filter { $0.serverID == serverID && $0.userID == userID }
    }

    func acknowledge(_ update: OfflineWatchUpdate) throws {
        var updates = try read()
        guard let index = updates.firstIndex(where: { $0.revision == update.revision }) else { return }

        updates.remove(at: index)
        try write(updates)
    }

    func remove(serverID: String, userID: String? = nil) throws {
        let updates = try read()
        let retained = updates.filter { $0.serverID != serverID || (userID != nil && $0.userID != userID) }
        guard retained.count != updates.count else { return }

        try write(retained)
    }

    private func read() throws -> [OfflineWatchUpdate] {
        do {
            return try JSONDecoder().decode([OfflineWatchUpdate].self, from: Data(contentsOf: fileURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
    }

    private func write(_ updates: [OfflineWatchUpdate]) throws {
        var directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(updates).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
