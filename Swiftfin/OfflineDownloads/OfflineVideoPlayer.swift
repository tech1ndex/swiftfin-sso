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
    let onPosition: (Double, Bool) -> Void

    @State
    private var player: MPVPlayer?
    @State
    private var showsControls = true
    @State
    private var showsTracks = false
    @State
    private var textSubtitles = TextSubtitlePresentation()
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
    private var reportedCompletion = false
    @State
    private var previousIdleTimerSetting = false

    @ContentBuilder
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                GeometryReader { viewport in
                    let dimensions = player.mediaInformation.presentationDimensions
                    MPVVideoPlayerView(
                        player: player,
                        textSubtitles: textSubtitles,
                        layout: .init(
                            videoSize: dimensions.map { CGSize(width: $0.width, height: $0.height) } ?? .zero,
                            viewportSize: viewport.size,
                            behavior: .fit
                        ),
                        isPictureInPictureActive: false
                    )
                }
                .ignoresSafeArea()

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
        .sheet(isPresented: $showsTracks) {
            if let player {
                OfflineTrackSelection(player: player) {
                    showsTracks = false
                    showsControls = false
                }
                .presentationDetents([.medium, .large])
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .supportedOrientations(.all)
        .onAppear {
            guard player == nil, url.isFileURL else { return }

            previousIdleTimerSetting = UIApplication.shared.isIdleTimerDisabled
            let player = MPVPlayer()
            self.player = player
            textSubtitles.start(player)
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
            textSubtitles.clear()
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
            Button {
                guard let scene = UIApplication.shared
                    .connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }) else { return }

                let orientations: UIInterfaceOrientationMask = scene.interfaceOrientation.isLandscape ? .portrait : .landscapeRight
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { error in
                    Task { @MainActor in seekError = error }
                }
            } label: {
                Label(L10n.rotate, systemImage: "rotate.right")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
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

            Button {
                showsTracks = true
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
                onPosition(result.position.seconds, false)
            } catch {
                guard !Task.isCancelled else { return }

                seekError = error
            }
            pendingPosition = nil
            seekTask = nil
        }
    }

    private func checkpoint() {
        guard let player, player.isPlaybackReady || player.state == .ended else { return }

        let position = player.state == .ended ? 0 : player.position.seconds
        guard position >= 0,
              position.isFinite,
              position != lastCheckpoint || (player.state == .ended && !reportedCompletion) else { return }

        reportedCompletion = player.state == .ended

        lastCheckpoint = position
        onPosition(position, player.state == .ended)
    }
}

private struct OfflineTrackSelection: View {

    let player: MPVPlayer
    let onSelect: () -> Void

    @ContentBuilder
    var body: some View {
        NavigationStack {
            List {
                Section(L10n.audio) {
                    ForEach(player.audioTracks) { track in
                        option(title: trackName(track), selected: track.isSelected) {
                            player.selectTrack(track.id)
                        }
                    }
                }

                Section {
                    let selected = player.selectedSubtitle()?.id
                    option(title: L10n.off, selected: selected == nil) {
                        player.selectSubtitle(nil)
                    }
                    ForEach(player.subtitleTracks) { track in
                        option(title: trackName(track), selected: selected == track.id) {
                            player.selectSubtitle(track.id)
                        }
                    }
                } header: {
                    Text(L10n.subtitles)
                } footer: {
                    Text(L10n.downloadSubtitleTracksDescription)
                }
            }
            .navigationTitle(L10n.tracks)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.done, action: onSelect)
                }
            }
        }
    }

    @ContentBuilder
    private func option(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            onSelect()
        } label: {
            HStack {
                Text(verbatim: title)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func trackName(_ track: MPVMediaTrack) -> String {
        let language = track.language?.nilIfBlank.map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
        let title = track.title?.nilIfBlank
        if let language, let title, language.localizedCaseInsensitiveCompare(title) != .orderedSame {
            return "\(language) · \(title)"
        }
        return language ?? title ?? "\(L10n.subtitleTrack) \(track.mpvID)"
    }
}
