//
//  OnboardingVideo.swift
//  OnboardingKit (from Onit's VideoPlayerView + OnboardingQuickEditIntro demo video)
//

import AVKit
import SwiftUI

/// Looping, control-less video, as in Onit's onboarding. Takes a file URL (SwiftPM apps don't
/// have asset catalogs, so videos ship in the bundle's Resources instead of as NSDataAssets).
public struct OnboardingVideoPlayer: NSViewRepresentable {
    private let url: URL
    private let videoGravity: AVLayerVideoGravity

    public init(url: URL, videoGravity: AVLayerVideoGravity = .resizeAspect) {
        self.url = url
        self.videoGravity = videoGravity
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = videoGravity
        view.player = context.coordinator.player(for: url)
        return view
    }

    public func updateNSView(_ view: AVPlayerView, context: Context) {
        let player = context.coordinator.player(for: url)
        if view.player !== player { view.player = player }
    }

    public final class Coordinator {
        private var player: AVPlayer?
        private var url: URL?
        private var observer: NSObjectProtocol?

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func player(for url: URL) -> AVPlayer {
            if let player, self.url == url { return player }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .none
            player.isMuted = true
            observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                player.seek(to: .zero)
                player.play()
            }
            player.play()
            self.player = player
            self.url = url
            return player
        }
    }
}

/// The QuickEdit-intro demo video block: 434pt wide, 18pt corners, faint S0 outline.
/// Shows a placeholder card when there's no video yet.
public struct OnboardingDemoVideo: View {
    private let url: URL?
    private let width: CGFloat
    private let aspectRatio: CGFloat

    public init(url: URL?, width: CGFloat = 434, aspectRatio: CGFloat = 16 / 10) {
        self.url = url
        self.width = width
        self.aspectRatio = aspectRatio
    }

    public var body: some View {
        Group {
            if let url {
                OnboardingVideoPlayer(url: url)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 34, weight: .light))
                    Text("Demo video coming soon")
                        .font(.system(size: 13))
                }
                .foregroundColor(Color(NSColor.secondaryLabelColor))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.onboardingFillQuiet)
            }
        }
        .frame(width: width, height: width / aspectRatio)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.onboardingS0.opacity(0.24), lineWidth: 1))
    }
}
