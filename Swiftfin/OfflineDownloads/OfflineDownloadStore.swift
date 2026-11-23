//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Combine
import FactoryKit
import Foundation
import JellyfinAPI

@MainActor
final class OfflineDownloadStore: NSObject, ObservableObject {

    static let shared = OfflineDownloadStore()
    static let sessionIdentifier = (Bundle.main.bundleIdentifier ?? "Swiftfin") + ".offline-downloads"

    @Published
    private var records: [OfflineDownload] = []

    private let directory = URL.applicationSupportDirectory.appending(path: "OfflineDownloads", directoryHint: .isDirectory)
    private var manifestURL: URL {
        directory.appending(path: "downloads.json")
    }

    private var isLoaded = false
    private var backgroundCompletion: (() -> Void)?

    private lazy var transfers: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    override private init() {
        super.init()
        try? load()
    }

    func entries(for session: UserSession) -> [OfflineDownload] {
        records.filter { $0.serverID == session.server.id && $0.userID == session.user.id }
    }

    func fileURL(for entry: OfflineDownload) -> URL {
        directory.appending(path: entry.id.uuidString).appendingPathExtension(entry.fileExtension)
    }

    func start(_ item: BaseItemDto, session: UserSession) throws {
        try load()
        guard let id = item.id?.nilIfBlank else { throw DownloadError.unavailable }

        if entries(for: session).contains(where: { $0.itemID == id }) {
            return
        }

        let title = item.type == .episode
            ? [item.seriesName, item.seasonEpisodeLabel ?? item.episodeLocator, item.displayTitle]
            .compactMap(\.self)
            .joined(separator: " · ")
            : item.displayTitle
        let container = (item.mediaSources?.first?.container ?? item.container ?? "")
            .components(separatedBy: ",")[0].lowercased()
        let entry = OfflineDownload(
            id: UUID(),
            serverID: session.server.id,
            userID: session.user.id,
            itemID: id,
            title: title,
            fileExtension: container.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) != nil ? container : "media"
        )
        try enqueue(entry, item: item, session: session)
    }

    func retry(_ entry: OfflineDownload, session: UserSession) async throws {
        guard entry.serverID == session.server.id,
              entry.userID == session.user.id,
              case .failed = entry.state else { throw DownloadError.unavailable }

        let item = try await session.send(Paths.getItem(itemID: entry.itemID, userID: session.user.id)).value
        guard records.contains(where: { $0.id == entry.id && $0.transferID == entry.transferID && $0.state == entry.state }),
              item.id == entry.itemID else { throw DownloadError.unavailable }

        var retry = entry
        retry.transferID = UUID()
        retry.state = .downloading
        retry.progress = nil
        try enqueue(retry, item: item, session: session)
    }

    private func enqueue(_ entry: OfflineDownload, item: BaseItemDto, session: UserSession) throws {
        guard Container.shared.currentUserSession() === session,
              item.type == .movie || item.type == .episode,
              item.canBeDownloaded,
              let token = session.client.accessToken?.nilIfBlank,
              let url = session.client.url(with: Paths.getDownload(itemID: entry.itemID)) else { throw DownloadError.unavailable }

        var request = URLRequest(url: url)
        request.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        let task = transfers.downloadTask(with: request)
        task.taskDescription = entry.transferID.uuidString
        do {
            try persist(records.filter { $0.id != entry.id } + [entry])
            task.resume()
        } catch {
            task.cancel()
            throw error
        }
    }

    func remove(_ entry: OfflineDownload) throws {
        try load()
        let pending = pendingRemovalURL(for: entry.id)
        let files = FileManager.default
        guard let current = records.first(where: { $0.id == entry.id }) else {
            if files.fileExists(atPath: pending.path) {
                try files.removeItem(at: pending)
            }
            return
        }

        let media = fileURL(for: current)
        let hasMedia = files.fileExists(atPath: media.path)
        if hasMedia {
            try files.moveItem(at: media, to: pending)
        }
        do {
            try persist(records.filter { $0.id != entry.id })
        } catch {
            if hasMedia {
                try files.moveItem(at: pending, to: media)
            }
            throw error
        }
        let transferID = current.transferID.uuidString
        transfers.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == transferID }.forEach { $0.cancel() }
        }
        if files.fileExists(atPath: pending.path) {
            try files.removeItem(at: pending)
        }
    }

    func removeDownloads(serverID: String, userID: String? = nil) throws {
        try load()
        try recoverPendingRemovals()
        for entry in records where entry.serverID == serverID && (userID == nil || entry.userID == userID) {
            try remove(entry)
        }
    }

    func savePosition(_ seconds: Double, for entry: OfflineDownload) {
        guard seconds.isFinite,
              let index = records.firstIndex(where: { $0.id == entry.id && $0.state == .ready }) else { return }

        let seconds = max(0, seconds.rounded(.down))
        guard seconds != records[index].resumeSeconds else { return }

        var updated = records
        updated[index].resumeSeconds = seconds
        try? persist(updated)
    }

    private func persist(_ updated: [OfflineDownload]) throws {
        try JSONEncoder().encode(updated).write(to: manifestURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        records = updated
    }

    func load() throws {
        guard !isLoaded else { return }

        var directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
        ])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        do {
            records = try JSONDecoder().decode([OfflineDownload].self, from: Data(contentsOf: manifestURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            records = []
        }
        try recoverPendingRemovals()
        isLoaded = true

        // Only reconcile attempts present at launch. A new task may start while iOS enumerates transfers.
        let restored = Set(records.map(\.transferID))
        transfers.getAllTasks { tasks in
            Task { @MainActor in
                self.reconcile(restored, tasks: tasks)
            }
        }
    }

    private func pendingRemovalURL(for id: UUID) -> URL {
        directory.appending(path: "remove-" + id.uuidString)
    }

    /// The atomic manifest selects the outcome if termination interrupts a file deletion.
    private func recoverPendingRemovals() throws {
        let files = FileManager.default
        for pending in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = pending.lastPathComponent
            guard name.hasPrefix("remove-"), let id = UUID(uuidString: String(name.dropFirst(7))) else { continue }

            if let entry = records.first(where: { $0.id == id }), !files.fileExists(atPath: fileURL(for: entry).path) {
                try files.moveItem(at: pending, to: fileURL(for: entry))
            } else {
                try files.removeItem(at: pending)
            }
        }
    }

    private func reconcile(_ restored: Set<UUID>, tasks: [URLSessionTask]) {
        let active = Set(tasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) })
        for task in tasks {
            if !records.contains(where: { $0.transferID.uuidString == task.taskDescription && $0.state == .downloading }) {
                task.cancel()
            } else if task.state == .suspended {
                // The app may have exited after recording the attempt and before resuming its task.
                task.resume()
            }
        }
        for entry in records where restored.contains(entry.transferID) {
            let exists = FileManager.default.fileExists(atPath: fileURL(for: entry).path)
            switch entry.state {
            case .downloading where exists:
                finish(entry, state: .ready)
            case .downloading where !active.contains(entry.transferID), .ready where !exists:
                finish(entry, state: .failed(DownloadError.interrupted.localizedDescription))
            default:
                break
            }
        }
    }

    private func finish(_ entry: OfflineDownload, state: OfflineDownload.State) {
        guard let index = records.firstIndex(where: { $0.transferID == entry.transferID }) else { return }

        var updated = records
        updated[index].state = state
        updated[index].progress = nil
        do {
            try persist(updated)
        } catch {
            // The final file is also a durable completion marker if writing the manifest runs out of space.
            records = updated
        }
    }

    func handleBackgroundEvents(completion: @escaping () -> Void) {
        backgroundCompletion = completion
        try? load()
        _ = transfers
    }

    private func entry(for task: URLSessionTask) -> OfflineDownload? {
        records.first { $0.transferID.uuidString == task.taskDescription && $0.state == .downloading }
    }
}

/// All callbacks use OperationQueue.main. Move the temporary file before returning it to URLSession.
extension OfflineDownloadStore: @preconcurrency URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // iOS can deliver a completed download after omitting its task from the launch snapshot.
        guard let entry = records.first(where: { $0.transferID.uuidString == downloadTask.taskDescription && $0.state != .ready })
        else { return }

        do {
            guard let response = downloadTask.response as? HTTPURLResponse else { throw DownloadError.interrupted }
            guard response.statusCode == 200 else { throw DownloadError.http(response.statusCode) }

            let mime = response.mimeType ?? ""
            guard !mime.hasPrefix("text/"), !mime.contains("json"), !mime.contains("xml") else { throw DownloadError.invalidFile }

            let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0 else { throw DownloadError.invalidFile }

            if response.value(forHTTPHeaderField: "Content-Encoding") == nil,
               response.expectedContentLength >= 0,
               Int64(size) != response.expectedContentLength {
                throw DownloadError.interrupted
            }

            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: location.path
            )
            try FileManager.default.moveItem(at: location, to: fileURL(for: entry))
            finish(entry, state: .ready)
        } catch {
            finish(entry, state: .failed(DownloadError.message(for: error)))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0, let index = records.firstIndex(where: {
            $0.transferID.uuidString == downloadTask.taskDescription && $0.state == .downloading
        }) else { return }

        let fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        if records[index].progress.map({ abs($0 - fraction) >= 0.01 }) ?? true {
            records[index].progress = fraction
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = entry(for: task) else { return }

        finish(entry, state: .failed(DownloadError.message(for: error ?? DownloadError.interrupted)))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let completion = backgroundCompletion
        backgroundCompletion = nil
        completion?()
    }
}

private enum DownloadError: LocalizedError {

    case unavailable
    case interrupted
    case invalidFile
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: L10n.downloadUnavailable
        case .interrupted: L10n.downloadInterrupted
        case .invalidFile: L10n.downloadInvalidFile
        case let .http(code): L10n.downloadHTTPError(code)
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? DownloadError {
            return error.localizedDescription
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError ||
            nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) {
            return L10n.downloadInsufficientSpace
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            return message(for: underlying)
        }
        // Network errors can include the request URL. Store only the user-facing category.
        return interrupted.localizedDescription
    }
}
