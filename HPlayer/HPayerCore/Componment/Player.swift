//
//  Player.swift
//  HPlayer
//
//  Created by hinson on 2020/12/21.
//  Copyright © 2020 tommy. All rights reserved.
//

import AVFoundation
//import CoreMedia
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

//MARK: - Player Define

///Player的抽象描述
public protocol MediaPlayback: AnyObject {
    var duration: TimeInterval { get }
    var naturalSize: CGSize { get }
    var currentPlaybackTime: TimeInterval { get }
    func prepareToPlay()
    func shutdown()
    func seek(time: TimeInterval, completion handler: ((Bool) -> Void)?)
}
///Player的抽象描述
public protocol MediaPlayerProtocol: MediaPlayback {
    var delegate: MediaPlayerDelegate? { get set }
    var view: UIView { get }
    var nominalFrameRate: Float { get }
    var playableTime: TimeInterval { get }
    var isPreparedToPlay: Bool { get }
    var playbackState: MediaPlaybackState { get }
    var loadState: MediaLoadState { get }
    var isPlaying: Bool { get }
    var isMuted: Bool { get set }
    var allowsExternalPlayback: Bool { get set }
    var usesExternalPlaybackWhileExternalScreenIsActive: Bool { get set }
    var isExternalPlaybackActive: Bool { get }
    var playbackRate: Float { get set }
    var playbackVolume: Float { get set }
    var contentMode: UIViewContentMode { get set }
    
    init(url: URL, options: HPConfig)
    func replace(url: URL, options: HPConfig)
    func play()
    func pause()
    func enterBackground()
    func enterForeground()
    func thumbnailImageAtCurrentTime(handler: @escaping (UIImage?) -> Void)
    func tracks(mediaType: AVFoundation.AVMediaType) -> [PlayerTrack]
    func select(track: PlayerTrack)
}
extension MediaPlayerProtocol {
    func setAudioSession() {
        let category = AVAudioSession.sharedInstance().category
        if category == .playback || category == .playAndRecord {
            return
        }
        if #available(iOS 11.0, tvOS 11.0, *) {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        } else {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        }
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

///Player的事件代理回调
public protocol MediaPlayerDelegate: AnyObject {
    func preparedToPlay(player: MediaPlayerProtocol)
    func changeLoadState(player: MediaPlayerProtocol)
    // 缓冲加载进度，0-100
    func changeBuffering(player: MediaPlayerProtocol, progress: Int)
    func playBack(player: MediaPlayerProtocol, loopCount: Int)
    func finish(player: MediaPlayerProtocol, error: Error?)
}

///Media播放状态描述
public enum MediaPlaybackState: Int {
    case idle
    case playing
    case paused
    case seeking
    case finished
    case stopped
}
///Media的加载状态描述
public enum MediaLoadState: Int {
    case idle
    case loading
    case playable
}

///FFMpeg播放器
public class HPlayer: MediaPlayerProtocol {
    
    //MARK: 私有
    private var playerItem: HPSource
    private let audioOutput = HPAudioOutput()
    private let videoOutput = HPMetalView()
    
    private var loopCount = 1
    private var options: HPConfig
    
    ///播放代理
    public weak var delegate: MediaPlayerDelegate?
    ///可进行播放的结尾时间点（缓冲进度的末尾时间点）
    public private(set) var playableTime = TimeInterval(0)
    ///是否已经准备好了播放
    public private(set) var isPreparedToPlay = false
    ///播放状态，每次改变时会进行playOrPause()，会进行audioOutput循环的开关和通知上层。
    public private(set) var playbackState = MediaPlaybackState.idle {
        didSet {
            if playbackState != oldValue {
                videoOutput.isPaused = playbackState != .playing
                playOrPause()
                if playbackState == .finished {
                    delegate?.finish(player: self, error: nil)
                }
            }
        }
    }
    ///加载状态，每次改变时会进行playOrPause()，会进行audioOutput循环的开关和通知上层。
    public private(set) var loadState = MediaLoadState.idle {
        didSet {
            if loadState != oldValue {
                playOrPause()
            }
        }
    }
    ///播放速度
    public var playbackRate: Float = 1 {
        didSet {
            audioOutput.audioPlayer.playbackRate = playbackRate
        }
    }
    public var allowsExternalPlayback: Bool = false
    public var usesExternalPlaybackWhileExternalScreenIsActive: Bool = false
    
    ///播放器播放点到向后缓冲的这一段时间刻度
    public private(set) var bufferingProgress = 0 {
        didSet {
            delegate?.changeBuffering(player: self, progress: bufferingProgress)
        }
    }
    
    ///播放声音
    public var playbackVolume: Float {
        get {
            audioOutput.audioPlayer.volume
        }
        set {
            audioOutput.audioPlayer.volume = newValue
        }
    }
    
    ///原始资源size
    public var naturalSize: CGSize {
        playerItem.rotation == 90 || playerItem.rotation == 270 ? playerItem.naturalSize.reverse : playerItem.naturalSize
    }
    public var duration: TimeInterval { playerItem.duration }
    public var currentPlaybackTime: TimeInterval {
        get { playerItem.currentPlaybackTime }
        set { /*seek(time: newValue)*/ }
    }
    
    public var isPlaying: Bool { playbackState == .playing }
    public var nominalFrameRate: Float {
        Float(playerItem.assetTracks.first { $0.mediaType == .video && $0.isEnabled }?.fps ?? 0)
    }
    public var isExternalPlaybackActive: Bool { false }
    
    public var view: UIView { videoOutput }
    
    public var contentMode: UIViewContentMode {
        set { view.contentMode = newValue }
        get { view.contentMode }
    }
    
    public var isMuted: Bool {
        set { audioOutput.audioPlayer.isMuted = newValue }
        get { audioOutput.audioPlayer.isMuted }
    }
    
    public var seekable: Bool { playerItem.seekable }
    
    public required init(url: URL, options: HPConfig) {
        playerItem = HPSource(url: url, options: options)
        self.options = options
        playerItem.delegate = self
        audioOutput.renderSource = playerItem
        videoOutput.renderSource = playerItem
        //videoOutput.display = options.display
        self.setAudioSession()
    }
    deinit {
        shutdown()
    }
    
    public func replace(url: URL, options: HPConfig) {
        HPLog("replaceUrl \(self)")
        shutdown()
        audioOutput.clear()
        videoOutput.clear()
        playerItem.delegate = nil
        playerItem = HPSource(url: url, options: options)
        self.options = options
        playerItem.delegate = self
        audioOutput.renderSource = playerItem
        videoOutput.renderSource = playerItem
        //videoOutput.display = options.display
    }

    public func seek(time: TimeInterval, completion handler: ((Bool) -> Void)? = nil) {
        guard time >= 0 else {
            return
        }
        let oldPlaybackState = playbackState
        playbackState = .seeking
        runInMainqueue { [weak self] in
            self?.bufferingProgress = 0
        }
        audioOutput.clear()
        let seekTime: TimeInterval
        if time >= duration, options.isLoopPlay {
            seekTime = 0
        } else {
            seekTime = time
        }
        playerItem.seek(time: seekTime) { [weak self] result in
            guard let self = self else { return }
            self.audioOutput.clear()
            runInMainqueue { [weak self] in
                guard let self = self else { return }
                self.playbackState = oldPlaybackState
                handler?(result)
            }
        }
    }

    ///播放准备工作
    public func prepareToPlay() {
        HPLog("prepareToPlay \(self)")
        playerItem.prepareToPlay()
        bufferingProgress = 0
    }

    public func play() {
        HPLog("play \(self)")
        playbackState = .playing
    }

    public func pause() {
        HPLog("pause \(self)")
        playbackState = .paused
    }

    public func shutdown() {
        HPLog("shutdown \(self)")
        playbackState = .stopped
        loadState = .idle
        isPreparedToPlay = false
        loopCount = 0
        playerItem.shutdown()
        
        ///options.starTime = 0
        ///options.openTime = 0
        ///options.findTime = 0
        ///options.readAudioTime = 0
        ///options.readVideoTime = 0
        ///options.decodeAudioTime = 0
        ///options.decodeVideoTime = 0
    }

    public func thumbnailImageAtCurrentTime(handler: @escaping (UIImage?) -> Void) {
        let image = videoOutput.toImage()
        handler(image)
    }

    public func enterBackground() {
        playerItem.isBackground = true
    }

    public func enterForeground() {
        playerItem.isBackground = false
    }

    public func tracks(mediaType: AVFoundation.AVMediaType) -> [PlayerTrack] {
        playerItem.assetTracks.filter { $0.mediaType == mediaType }
    }

    public func select(track: PlayerTrack) {
        playerItem.select(track: track)
    }
}

// MARK: - private functions
extension HPlayer {
    private func playOrPause() {
        runInMainqueue { [weak self] in
            guard let self = self else { return }
            self.audioOutput.isPaused = !(self.playbackState == .playing && self.loadState == .playable)
            self.delegate?.changeLoadState(player: self)
        }
    }
}

// MARK: - Player作为代理处理Item的事件回调
extension HPlayer: HPPlayerDelegate {
    func sourceDidOpened() {
        isPreparedToPlay = true
        runInMainqueue { [weak self] in
            guard let self = self else { return }
            self.videoOutput.drawableSize = self.naturalSize
            self.view.centerRotate(byDegrees: self.playerItem.rotation)
            self.videoOutput.isPaused = false //触发渲染，这里打开就去取，取不到不渲染，也就是没有首桢？
            if self.options.isAutoPlay { //如果自动播放
                self.play()
            }
            self.delegate?.preparedToPlay(player: self)
        }
    }

    func sourceDidFailed(error: NSError?) {
        runInMainqueue { [weak self] in
            guard let self = self else { return }
            self.delegate?.finish(player: self, error: error)
        }
    }

    func sourceDidFinished(type: AVFoundation.AVMediaType, allSatisfy: Bool) {
        runInMainqueue { [weak self] in
            guard let self = self else { return }
            if type == .audio {
                self.audioOutput.isPaused = true
            } else if type == .video {
                self.videoOutput.isPaused = true
            }
            if allSatisfy { //都结束
                if self.options.isLoopPlay {
                    self.loopCount += 1
                    self.delegate?.playBack(player: self, loopCount: self.loopCount)
                    self.audioOutput.isPaused = false
                    self.videoOutput.isPaused = false
                } else {
                    self.playbackState = .finished
                }
            }
        }
    }
    
    func sourceDidChange(loadingState: LoadingState) {
        //向后统计可播放时间点
        if loadingState.isEndOfFile {
            playableTime = duration
        } else {
            playableTime = currentPlaybackTime + loadingState.loadedTime
        }
        
        if loadState == .playable {
            if !loadingState.isEndOfFile, loadingState.packetCount == 0, loadingState.frameCount == 0 {
                loadState = .loading
                if playbackState == .playing {
                    runInMainqueue { [weak self] in
                        // 在主线程更新进度
                        self?.bufferingProgress = 0
                    }
                }
            }
        } else { //一开始loadState为idle
            
            /*Player处理source的loadingState变化
             player的loadState不是playable时（刚开始player的loadState为idle）
             接着source层告知player的loadingState.isPlayable为false时，会先记录loadingState.progress
                如果playbackState为playing，表示正在播放，这个时候拿出progress更新为播放器的缓冲进度bufferingProgress
             然后当source层告知player的loadingState.isPlayable为true时，表示可播放了，修改player的loadState为playable
             
             然后在player内部loadState为playable时
             如果loadingState不是EndOfFile，内部packetCount和frameCount都为0，说明已经缓冲的部分都播完了。
                所以切换player内部loadState为loading。
                如果playbackState为playing，表示正在播放，那么更新播放器的缓冲进度bufferingProgress为0
             */
            var progress = 100
            if loadingState.isPlayable {
                loadState = .playable
            } else {
                progress = min(100, Int(loadingState.progress))
            }
            if playbackState == .playing {
                runInMainqueue { [weak self] in
                    // 在主线程更新进度
                    self?.bufferingProgress = progress
                }
            }
        }
    }

    func sourceDidChange(oldBitRate: Int64, newBitrate: Int64) {
        HPLog("ADAPTION DEBUG ｜ oldBitRate \(oldBitRate) change to newBitrate \(newBitrate)")
    }
}

