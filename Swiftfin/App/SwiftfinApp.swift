//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import SwiftUI
import UIKit

@main
struct SwiftfinApp: App {

    @UIApplicationDelegateAdaptor
    private var appDelegate: SwiftfinAppDelegate

    init() {
        Self.configure()

        UIScrollView.appearance().keyboardDismissMode = .onDrag

        // Sometimes the tab bar won't appear properly on push, always have material background.
        UITabBar.appearance().scrollEdgeAppearance = UITabBarAppearance(idiom: .unspecified)

        Task {
            await SwiftfinSpotlight.addSwiftfinToSpotlight()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class SwiftfinAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == OfflineDownloadStore.sessionIdentifier else {
            completionHandler()
            return
        }

        OfflineDownloadStore.shared.handleBackgroundEvents(completion: completionHandler)
    }

    func applicationProtectedDataDidBecomeAvailable(_ application: UIApplication) {
        try? OfflineDownloadStore.shared.load()
    }
}

extension UINavigationController {

    /// Remove back button text
    override open func viewWillLayoutSubviews() {
        navigationBar.topItem?.backButtonDisplayMode = .minimal
    }
}
