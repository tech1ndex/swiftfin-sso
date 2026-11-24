//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import JellyfinAPI
import Network

@MainActor
final class OfflineWatchSync {

    static let shared = OfflineWatchSync()
    private weak var session: UserSession?
    private var task: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var generation = UUID()

    func start(_ session: UserSession) {
        stop()
        self.session = session
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }

            Task { @MainActor in self?.wake() }
        }
        monitor.start(queue: DispatchQueue(label: "Swiftfin.OfflineWatchSync"))
        schedule()
    }

    func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        monitor?.cancel()
        monitor = nil
        session = nil
    }

    func wake() {
        guard task == nil else { return }

        schedule()
    }

    func schedule() {
        guard task == nil, let session else { return }

        let generation = generation
        task = Task { [weak self, weak session] in
            var delay = 2
            while let self, let session, !Task.isCancelled, self.generation == generation {
                do {
                    try await Task.sleep(for: .seconds(delay))
                    let updates = try OfflineWatchQueue.shared.entries(serverID: session.server.id, userID: session.user.id)
                    if updates.isEmpty {
                        break
                    }
                    var failed = false
                    for update in updates {
                        do {
                            try Task.checkCancellation()
                            let client = session.client
                            let remote = try await client.send(Paths.getItemUserData(itemID: update.itemID, userID: update.userID)).value
                            try Task.checkCancellation()
                            guard self.generation == generation else { return }

                            let current = try OfflineWatchQueue.shared.entries(serverID: update.serverID, userID: update.userID)
                            guard current.contains(where: { $0.revision == update.revision }) else { continue }

                            if remote.lastPlayedDate
                                .map({
                                    ($0.timeIntervalSince1970 * 1000).rounded() >= (update.recordedAt.timeIntervalSince1970 * 1000)
                                        .rounded() }) !=
                                true {
                                let body = UpdateUserItemDataDto(
                                    isPlayed: update.completed ? true : nil,
                                    lastPlayedDate: update.recordedAt,
                                    playbackPositionTicks: update.positionTicks
                                )
                                _ = try await client.send(Paths.updateItemUserData(itemID: update.itemID, userID: update.userID, body))
                            }
                            try Task.checkCancellation()
                            guard self.generation == generation else { return }

                            try OfflineWatchQueue.shared.acknowledge(update)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            failed = true
                        }
                    }
                    delay = failed ? min(delay * 2, 60) : 2
                } catch is CancellationError {
                    break
                } catch {
                    delay = min(delay * 2, 60)
                }
            }
            guard let self, self.generation == generation else { return }

            self.task = nil
        }
    }
}
