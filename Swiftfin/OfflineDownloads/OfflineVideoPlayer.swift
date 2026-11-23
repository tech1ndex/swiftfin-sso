//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFAudio
import MPVUI
import SwiftUI

struct OfflineVideoPlayer: View {

    @Environment(\.dismiss)
    private var dismiss
    @Environment(\.scenePhase)
    private var scenePhase
    @Environment(\.layoutDirection)
    private var layoutDirection

    let url: URL
    let title: String
    let startSeconds: Double
    let onPosition: (Double) -> Void

    @State
    private var player: MPVPlayer?
    @State
    private var showsControls = true
    @GestureState
    private var scrubPosition: Double?
    @State
    private var pendingPosition: Double?
    @State
    private var seekTask: Task<Void, Never>?
    @State
    private var seekError: Error?
    @State
    private var lastCheckpoint: Double?
    @State
    private var previousIdleTimerSetting = false

    @ContentBuilder
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                MPVVideoPlayer(player: player)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                Button {
                    showsControls.toggle()
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.playback)
                .accessibilityHint(L10n.playbackControlsAccessibilityHint)

                if showsControls {
                    VStack {
                        header
                        Spacer()
                        controls(for: player)
                    }
                }

                if player.state == .loading {
                    ProgressView()
                        .allowsHitTesting(false)
                }
            }

            if !url.isFileURL || player?.state.error != nil {
                VStack(spacing: 16) {
                    Text(L10n.unableToLoadThisItem)
                    Button(L10n.close) { dismiss() }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .preferredColorScheme(.dark)
        .errorMessage($seekError)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .supportedOrientations(.all)
        .onAppear {
            guard player == nil, url.isFileURL else { return }

            previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
            let player = MPVPlayer()
            self.player = player
            player.load(url, playAutomatically: true, startTime: .seconds(startSeconds.isFinite ? max(0, startSeconds) : 0))
        }
        .onChange(of: player?.position) { _, _ in
            guard let player,
                  player.isPlaybackReady,
                  abs(player.position.seconds - (lastCheckpoint ?? startSeconds)) >= 10
            else { return }

            checkpoint()
        }
        .onChange(of: player?.state) { _, state in
            guard let state else { return }

            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting || state == .playing
            if state == .ended {
                checkpoint()
                dismiss()
            } else if state == .paused {
                checkpoint()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                checkpoint()
                player?.pause()
            }
        }
        .onReceive(Notifications[.avAudioSessionInterruption].publisher.receive(on: DispatchQueue.main)) { interruption in
            if interruption.0 == .began {
                player?.pause()
            }
        }
        .onReceive(Notifications[.avAudioSessionRouteChange].publisher.receive(on: DispatchQueue.main)) { reason in
            if reason == .oldDeviceUnavailable {
                player?.pause()
            }
        }
        .onDisappear {
            guard let player else { return }

            seekTask?.cancel()
            checkpoint()
            player.stop()
            self.player = nil
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerSetting
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    @ContentBuilder
    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Label(L10n.close, systemImage: "chevron.down")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            Text(verbatim: title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal)
        .background(.black.opacity(0.72))
        .foregroundStyle(.white)
    }

    private func controls(for player: MPVPlayer) -> some View {
        let duration = player.duration.seconds
        let position = scrubPosition ?? pendingPosition ?? player.position.seconds

        return HStack {
            Button { player.togglePlayback() } label: {
                Label(player.isPaused ? L10n.play : L10n.pause, systemImage: player.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 44, height: 44)
            }

            VStack {
                seekBar(player, position: position, duration: duration)

                HStack {
                    Text(Duration.seconds(position), format: .time(pattern: .hourMinuteSecond))
                    Spacer()
                    Text(player.duration, format: .time(pattern: .hourMinuteSecond))
                }
                .font(.caption.monospacedDigit())
            }

            Menu {
                Picker(L10n.audio, selection: Binding(
                    get: { player.audioTracks.first(where: \.isSelected)?.id },
                    set: {
                        if let id = $0 {
                            player.selectTrack(id)
                        }
                    }
                )) {
                    trackOptions(player.audioTracks)
                }

                Picker(L10n.subtitles, selection: Binding(
                    get: { player.selectedSubtitle()?.id },
                    set: { player.selectSubtitle($0, for: .primary) }
                )) {
                    Text(L10n.off).tag(nil as MPVMediaTrackIdentifier?)
                    trackOptions(player.subtitleTracks)
                }
            } label: {
                Label(L10n.tracks, systemImage: "captions.bubble")
                    .frame(width: 44, height: 44)
            }
        }
        .labelStyle(.iconOnly)
        .padding()
        .tint(.white)
        .foregroundStyle(.white)
        .background(.black.opacity(0.72))
    }

    private func seekBar(_ player: MPVPlayer, position: Double, duration: Double) -> some View {
        let total = max(1, duration)
        return GeometryReader { geometry in
            let width = geometry.size.width
            ProgressView(value: min(max(0, position), total), total: total)
                .progressViewStyle(.linear)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($scrubPosition) { drag, preview, _ in
                            preview = targetSeconds(at: drag.location.x, width: width, duration: duration)
                        }
                        .onEnded { drag in
                            guard let target = targetSeconds(at: drag.location.x, width: width, duration: duration) else { return }

                            seek(player, to: target)
                        }
                )
        }
        .frame(height: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.seek)
        .accessibilityValue(Duration.seconds(position).formatted(.spokenRuntime))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: seek(player, to: min(duration, position + 10))
            case .decrement: seek(player, to: max(0, position - 10))
            @unknown default: break
            }
        }
        .disabled(!player.isSeekable || duration <= 0)
    }

    private func targetSeconds(at x: CGFloat, width: CGFloat, duration: Double) -> Double? {
        guard width > 0, duration > 0 else { return nil }

        let fraction = min(max(0, x / width), 1)
        return duration * (layoutDirection == .rightToLeft ? 1 - fraction : fraction)
    }

    private func seek(_ player: MPVPlayer, to seconds: Double) {
        seekTask?.cancel()
        pendingPosition = seconds
        seekTask = Task { @MainActor in
            do {
                let result = try await player.seekAndWait(to: .seconds(seconds))
                guard !Task.isCancelled else { return }

                lastCheckpoint = result.position.seconds
                onPosition(result.position.seconds)
            } catch {
                guard !Task.isCancelled else { return }

                seekError = error
            }
            pendingPosition = nil
            seekTask = nil
        }
    }

    @ContentBuilder
    private func trackOptions(_ tracks: [MPVMediaTrack]) -> some View {
        ForEach(tracks) { track in
            let language = track.language.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
            let name = track.title ?? language ?? track.codec ?? L10n.subtitleTrack
            Text(verbatim: "\(track.mpvID) · \(name)")
                .tag(Optional(track.id))
        }
    }

    private func checkpoint() {
        guard let player, player.isPlaybackReady || player.state == .ended else { return }

        let position = player.state == .ended ? 0 : player.position.seconds
        guard position >= 0, position.isFinite, position != lastCheckpoint else { return }

        lastCheckpoint = position
        onPosition(position)
    }
}
