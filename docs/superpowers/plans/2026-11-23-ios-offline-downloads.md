# iOS offline downloads implementation plan

Implement the [approved design](../specs/2026-11-23-ios-offline-downloads-design.md) with Foundation background transfers, the existing MPVUI dependency and the signed-in iOS navigation. Keep all new feature types under Swiftfin.

- [x] Build OfflineDownloadStore with a durable account-scoped catalog, validated original-file transfers, background task reconciliation, retry, progress, cancellation and deletion. Observe only one active OS task per entry. Remove a deleted account’s files.
- [x] Build OfflineVideoPlayer around MPVUI. Receive a local URL, title, start time and progress callback. Provide load, seek, embedded tracks, pause, completion and local resume.
- [x] Add Downloads to main navigation and an eligible movie or episode’s action menu. Wire per-account presentation, error reporting, retry and storage operations. Verify both Xcode schemes and exercise offline state transitions.
