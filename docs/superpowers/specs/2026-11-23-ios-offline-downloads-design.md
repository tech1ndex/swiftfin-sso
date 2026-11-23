# Offline video in Swiftfin for iOS

Save an original-quality movie or episode on iPhone or iPad, quit Swiftfin, reopen it in airplane mode, and watch it from Downloads. The user selected original-quality files for the first build. The iOS app owns the downloaded copy and uses the existing local account and playback protections.

## Approaches

Downloading the original preserves its container, quality and embedded tracks. This is the selected approach. Smaller, selectable encodes would need server conversion and additional handling for conversion failures. Exporting to Files would leave library management and offline resume to another player. The proposed Downloads experience keeps both inside Swiftfin.

## Download and storage

Offer Download on individual movie and episode detail screens when the existing account and item permission check passes. Download the default original media source for the item, including embedded audio and subtitles. Offer progress, cancel, retry on failure, and delete. External subtitle files, bulk season downloads, and alternate source selection are outside this first build.

Use authenticated requests and store durable, backup-excluded files in the app container. Scope transfers, media, metadata and resume positions to the Jellyfin server and user. Persist only what is needed to list and play the file, without token-bearing URLs. Keep incomplete files separate and mark an item playable only after a successful response and a complete move to local storage. Reconcile background transfers and local state on relaunch. Report interrupted transfers and insufficient disk space with a retry action. Removing an account also removes its downloads. Signing out hides them until that account is unlocked again.

## Offline navigation and playback

Expose Downloads from the iOS main navigation with locally stored titles and episode identifiers. A previously signed-in user can open Downloads on a cold launch while the server is unreachable. Honor sign-out-on-close and local authentication through Swiftfin’s existing account selection and unlock flow. Support local movie and episode playback using the existing playback engine that handles the file’s format. Loading the file, seeking, selecting embedded tracks, and saving the local resume position must work without server requests. Resume is local to the download for this version. Server watch-state reconciliation is a separate feature.

## Verification

Download a movie and an episode while signed in. Relaunch in airplane mode, find both in Downloads, play, seek, exit, resume and delete. Verify cancellation, an interrupted transfer and retry, account switching, and denial of downloads by the server. Check that supported embedded tracks work from a downloaded file. Build the iOS and tvOS targets and keep download controls and storage services specific to iOS. The builder may choose the persistence format, transfer integration and player wiring within these constraints.
