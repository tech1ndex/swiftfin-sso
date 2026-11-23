//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

struct OfflineDownload: Codable, Hashable, Identifiable {

    enum State: Codable, Hashable {

        case downloading
        case ready
        case failed(String)
    }

    let id: UUID
    let serverID: String
    let userID: String
    let itemID: String
    let title: String
    let fileExtension: String

    // Each attempt has its own identity so a late callback after cancellation or retry is harmless.
    var transferID = UUID()
    var state: State = .downloading
    var progress: Double?
    var resumeSeconds: Double = 0
}
