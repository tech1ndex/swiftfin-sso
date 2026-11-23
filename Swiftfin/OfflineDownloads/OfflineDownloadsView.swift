//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import FactoryKit
import JellyfinAPI
import SwiftUI

struct OfflineDownloadButton: View {

    @Injected(\.currentUserSession)
    private var session
    @EnvironmentObject
    private var tabs: TabCoordinator
    @ObservedObject
    private var store = OfflineDownloadStore.shared
    @ObservedObject
    var provider: ItemContentGroupProvider

    static func isAvailable(for item: BaseItemDto) -> Bool {
        (item.type == .movie || item.type == .episode) && item.canBeDownloaded
    }

    @ContentBuilder
    var body: some View {
        if let session, Self.isAvailable(for: provider.item) {
            if store.entries(for: session).contains(where: { $0.itemID == provider.item.id }) {
                Button {
                    tabs.selectedTabID = "downloads"
                } label: {
                    Label(L10n.downloads, systemImage: "arrow.down.circle")
                }
            } else {
                Button {
                    do {
                        try store.start(provider.item, session: session)
                    } catch {
                        provider.actionError = error
                    }
                } label: {
                    Label(L10n.download, systemImage: "arrow.down.circle")
                }
            }
        }
    }
}

struct OfflineDownloadsView: View {

    @Injected(\.currentUserSession)
    private var session
    @Injected(\.mediaPlayerManager)
    private var mediaPlayerManager
    @ObservedObject
    private var store = OfflineDownloadStore.shared
    @State
    private var playing: OfflineDownload?
    @State
    private var error: Error?

    @ContentBuilder
    var body: some View {
        let entries = session.map(store.entries(for:)) ?? []
        Group {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label(L10n.downloads, systemImage: "arrow.down.circle")
                } description: {
                    Text(L10n.downloadEmptyDescription)
                }
            } else {
                List(entries) { entry in
                    row(for: entry)
                        .swipeActions {
                            Button(role: .destructive) {
                                remove(entry)
                            } label: {
                                Label(L10n.delete, systemImage: "trash")
                            }
                        }
                }
            }
        }
        .navigationTitle(L10n.downloads)
        .onAppear {
            do { try store.load() } catch { self.error = error }
        }
        .fullScreenCover(item: $playing) { entry in
            OfflineVideoPlayer(url: store.fileURL(for: entry), title: entry.title, startSeconds: entry.resumeSeconds) {
                store.savePosition($0, for: entry)
            }
        }
        .errorMessage($error)
    }

    @ContentBuilder
    private func row(for entry: OfflineDownload) -> some View {
        switch entry.state {
        case .ready:
            Button {
                mediaPlayerManager.stop()
                playing = entry
            } label: {
                Label(entry.title, systemImage: "play.circle")
            }
            .contextMenu {
                Button(role: .destructive) {
                    remove(entry)
                } label: {
                    Label(L10n.delete, systemImage: "trash")
                }
            }

        case .downloading:
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.title)
                ProgressView(value: entry.progress)
                Button(L10n.cancel) { remove(entry) }
                    .buttonStyle(.borderless)
            }

        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.title)
                Text(message).font(.footnote).foregroundStyle(.secondary)
                Button(L10n.retry) {
                    guard let session else { return }

                    Task {
                        do { try await store.retry(entry, session: session) } catch { self.error = error }
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func remove(_ entry: OfflineDownload) {
        do { try store.remove(entry) } catch { self.error = error }
    }
}
