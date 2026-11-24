# Sync offline watch progress on iOS

An iPhone or iPad that plays a downloaded episode should update the same Jellyfin account’s Continue Watching and watched status when the server becomes reachable. The user selected syncing the latest state per item. Replaying a log of viewing sessions would count rewatches and add duplicate-report handling beyond the requested scope.

## Recording playback

Keep one durable pending update per server, user and item. Record a position in Jellyfin ticks and the time of the viewing activity. Use the offline player’s existing periodic checkpoints, successful seeks, pauses and dismissal. A natural end explicitly records completion and clears resume progress. A seek to the beginning records position zero. Retain an unsent completion if the user starts the item again and subsequently has a new partial position.

Store pending updates independently of downloaded media so deleting a video or restarting the app preserves the pending history. Purge it on account or server removal. Existing downloads participate on their next playback. Their historical timestamps and completions cannot be reconstructed from the old resume value.

## Sending and resolving updates

Send updates only with an active session for the matching account and server. Attempt sync after playback, on session activation, and on foreground or connectivity recovery. Coalesce frequent checkpoints and retry transient failures with backoff while active. Support completing a retry on a subsequent launch. Use authenticated Jellyfin item user-data requests and verify the server’s handling of omitted fields for the supported version. Preserve favorites, ratings and play count. A partial view preserves an existing watched flag. Completion sets it.

Read current server progress before sending. If the server reports more recent viewing activity, retain the server state. For equal dates with conflicting progress, prefer the server. If a server date is unavailable, retain its watched flag and use the newly recorded local position. Once the server already reflects an update or confirms its write, acknowledge only the pending revision that was sent. A newer local checkpoint survives an in-flight request. Server read and write are separate operations, so the timestamp comparison provides best-effort protection against simultaneous playback from another device.

## Verification

Exercise partial viewing, explicit completion, rewinding to zero, and a partial rewatch following unsent completion. Reconnect after deleting the file and after restarting the app. Check account isolation, duplicate retries after a lost response, newer progress on another device, and a new checkpoint arriving during sync. Build the iOS target and verify the existing streaming and tvOS playback paths remain independent. Check the resulting Continue Watching and watched state against a Jellyfin server where available.
