//
//  PlayerLayer.swift
//  HPlayer
//
//  Created by hinson on 2020/12/22.
//  Copyright © 2020 tommy. All rights reserved.
//

import AVFoundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
/**
 Player status emun
 - notSetURL:
 - readyToPlay:    player ready to play
 - buffering:      player buffering
 - bufferFinished: buffer finished
 - playedToTheEnd: played to the End
 - error:          error with playing
 */
public enum HPPlayerState: CustomStringConvertible {
    case notSetURL //初始后的默认状态
    case readyToPlay //已通过url完成player的初始化，并且player准备好后的状态
    case buffering //player loadState还没到playable前，表示正在缓冲
    case bufferFinished //player loadState == playable 表示缓冲完成
    case paused
    case playedToTheEnd
    case error
    public var description: String {
        switch self {
        case .notSetURL:
            return "notSetURL"
        case .readyToPlay:
            return "readyToPlay"
        case .buffering:
            return "buffering"
        case .bufferFinished:
            return "bufferFinished"
        case .paused:
            return "paused"
        case .playedToTheEnd:
            return "playedToTheEnd"
        case .error:
            return "error"
        }
    }

    public var isPlaying: Bool { self == .buffering || self == .bufferFinished }
}

public protocol HPPlayerLayerDelegate: AnyObject {
    func player(layer: HPPlayerLayer, state: HPPlayerState)
    func player(layer: HPPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval)
    func player(layer: HPPlayerLayer, finish error: Error?)
    ///readyToPlay后缓冲的情况
    func player(layer: HPPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval)
}

open class HPPlayerLayer: UIView {
    ///缓冲进度
    @HPObservable
    public var bufferingProgress: Int = 0 //可在变量名称上添加下划线来访问包装器类型：_bufferingProgress
    ///循环播放次数
    @HPObservable
    public var loopCount: Int = 0
    private var options: HPConfig?
    ///进行缓冲的次数
    private var bufferedCount = 0
    private var shouldSeekTo: TimeInterval = 0
    private var startTime: TimeInterval = 0
    private var url: URL?
    public var isWirelessRouteActive = false
    public weak var delegate: HPPlayerLayerDelegate?
    private lazy var timer: Timer = {
        Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(playerTimerAction), userInfo: nil, repeats: true)
    }()

    ///设置或者切换player时会进行重新的布局处理：以HPPlayerLayer的bounds布局，并且content=scaleAspectFit
    public var player: MediaPlayerProtocol? {
        didSet {
            oldValue?.view.removeFromSuperview()
            if let player = player {
                HPLog("player is \(player)")
                player.delegate = self
                player.contentMode = .scaleAspectFit //填充模式
                if let oldValue = oldValue {
                    player.playbackRate = oldValue.playbackRate
                    player.playbackVolume = oldValue.playbackVolume
                }
                addSubview(player.view)
                player.view.frame = bounds
                prepareToPlay()
            }
        }
    }

    /// 播发器的几种状态
    public private(set) var state = HPPlayerState.notSetURL {
        didSet {
            if state != oldValue {
                HPLog("playerStateDidChange - \(state)")
                delegate?.player(layer: self, state: state)
            }
        }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        registerRemoteControllEvent()
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(self, selector: #selector(enterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(enterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        #endif
    }

    public required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        unregisterRemoteControllEvent()
        resetPlayer()
    }

    ///初始化内核的Player
    public func set(url: URL, options: HPConfig) {
        self.url = url
        self.options = options
        
        //确定set时应该使用的播放器类型：现在只支持HPlayer
        let firstPlayerType: MediaPlayerProtocol.Type = HPlayer.self
        
        //如果当前播放器类型和应该使用的一致，则继续用当前播放器
        if let player = player, type(of: player) == firstPlayerType {
            player.replace(url: url, options: options)
            prepareToPlay()
        } else {
            player = firstPlayerType.init(url: url, options: options)
        }
        
    }

    ///开始播放前需要先set
    open func play() {
        UIApplication.shared.isIdleTimerDisabled = true
        options?.isAutoPlay = true
        if let player = player {
            if player.isPreparedToPlay {
                player.play()
                timer.fireDate = Date.distantPast //通过设置为过去的最长时间（NSDate表示的时间只能在distantPast和distantFuture之间）开始fire动作
            } else {
                if state == .error {
                    player.prepareToPlay() //player未准备好，报错时，重新准备试一下？
                }
            }
            state = player.loadState == .playable ? .bufferFinished : .buffering
        } else {
            state = .buffering
        }
    }

    ///暂停
    open func pause() {
        if #available(OSX 10.12.2, *) {
            if let player = player {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                    MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentPlaybackTime,
                    MPMediaItemPropertyPlaybackDuration: player.duration,
                ]
            }
        }
        options?.isAutoPlay = false
        player?.pause()
        timer.fireDate = Date.distantFuture
        state = .paused
        UIApplication.shared.isIdleTimerDisabled = false
    }

    ///重置播放器状态
    open func resetPlayer() {
        HPLog("resetPlayer")
        timer.invalidate()
        state = .notSetURL
        bufferedCount = 0
        shouldSeekTo = 0
        player?.playbackRate = 1
        player?.playbackVolume = 1
        UIApplication.shared.isIdleTimerDisabled = false
    }

    ///seek
    open func seek(time: TimeInterval, autoPlay: Bool, completion handler: ((Bool) -> Void)? = nil) {
        if time.isInfinite || time.isNaN { return }
        if autoPlay { state = .buffering }
        
        if let player = player, player.isPreparedToPlay {
            player.seek(time: time) { [weak self] finished in
                guard let self = self else { return }
                if finished, autoPlay { self.play() }
                handler?(finished)
            }
        } else {
            options?.isAutoPlay = autoPlay
            shouldSeekTo = time
        }
    }
    
    override open func layoutSubviews() {
        super.layoutSubviews()
        player?.view.frame = bounds
    }
}

// MARK: - private functions

extension HPPlayerLayer {
    ///每当切换播放器，或者切换播放资源时应该手动调用依次，做一些准备
    private func prepareToPlay() {
        startTime = CACurrentMediaTime()
        bufferedCount = 0
        player?.prepareToPlay()
        if options?.isAutoPlay ?? false {
            state = .buffering
        } else {
            state = .notSetURL
        }
    }

    @objc private func playerTimerAction() {
        guard let player = player, player.isPreparedToPlay else { return }
        delegate?.player(layer: self, currentTime: player.currentPlaybackTime, totalTime: player.duration)
        if player.playbackState == .playing, player.loadState == .playable, state == .buffering {
            // 一个兜底保护，正常不能走到这里
            state = .bufferFinished
        }
    }

    private func registerRemoteControllEvent() {
        if #available(OSX 10.12.2, *) {
            MPRemoteCommandCenter.shared().playCommand.addTarget(self, action: #selector(remoteCommandAction(event:)))
            MPRemoteCommandCenter.shared().pauseCommand.addTarget(self, action: #selector(remoteCommandAction(event:)))
            MPRemoteCommandCenter.shared().togglePlayPauseCommand.addTarget(self, action: #selector(remoteCommandAction(event:)))
            MPRemoteCommandCenter.shared().seekForwardCommand.addTarget(self, action: #selector(remoteCommandAction(event:)))
            MPRemoteCommandCenter.shared().seekBackwardCommand.addTarget(self, action: #selector(remoteCommandAction(event:)))
            MPRemoteCommandCenter.shared().changePlaybackRateCommand.addTarget(self, action: #selector(remoteCommandAction(event:)))
            MPRemoteCommandCenter.shared().changePlaybackPositionCommand.addTarget(self, action: #selector(remoteCommandAction(event:)))
        }
    }

    private func unregisterRemoteControllEvent() {
        if #available(OSX 10.12.2, *) {
            MPRemoteCommandCenter.shared().playCommand.removeTarget(self)
            MPRemoteCommandCenter.shared().pauseCommand.removeTarget(self)
            MPRemoteCommandCenter.shared().togglePlayPauseCommand.removeTarget(self)
            MPRemoteCommandCenter.shared().seekForwardCommand.removeTarget(self)
            MPRemoteCommandCenter.shared().seekBackwardCommand.removeTarget(self)
            MPRemoteCommandCenter.shared().changePlaybackRateCommand.removeTarget(self)
            MPRemoteCommandCenter.shared().changePlaybackPositionCommand.removeTarget(self)
        }
    }

    @available(OSX 10.12.2, *)
    @objc private func remoteCommandAction(event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let player = player else {
            return .noSuchContent
        }
        if event.command == MPRemoteCommandCenter.shared().playCommand {
            play()
        } else if event.command == MPRemoteCommandCenter.shared().pauseCommand {
            pause()
        } else if event.command == MPRemoteCommandCenter.shared().togglePlayPauseCommand {
            if state.isPlaying {
                pause()
            } else {
                play()
            }
        } else if event.command == MPRemoteCommandCenter.shared().seekForwardCommand {
            seek(time: player.currentPlaybackTime + player.duration * 0.01, autoPlay: options?.isSeekedAutoPlay ?? false)
        } else if event.command == MPRemoteCommandCenter.shared().seekBackwardCommand {
            seek(time: player.currentPlaybackTime - player.duration * 0.01, autoPlay: options?.isSeekedAutoPlay ?? false)
        } else if let event = event as? MPChangePlaybackPositionCommandEvent {
            seek(time: event.positionTime, autoPlay: options?.isSeekedAutoPlay ?? false)
        } else if let event = event as? MPChangePlaybackRateCommandEvent {
            player.playbackRate = event.playbackRate
        }
        return .success
    }

    @objc private func enterBackground() {
        guard let player = player, state.isPlaying, !player.isExternalPlaybackActive else {
            return
        }

        if HPManager.canBackgroundPlay {
            player.enterBackground()
            return
        }
        pause()
    }

    @objc private func enterForeground() {
        if HPManager.canBackgroundPlay {
            player?.enterForeground()
        }
    }
}

// MARK: - MediaPlayerDelegate
extension HPPlayerLayer: MediaPlayerDelegate {
    public func preparedToPlay(player: MediaPlayerProtocol) {
        //Mac上更新播放中心信息
        if #available(OSX 10.12.2, *) {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyPlaybackDuration: player.duration,
            ]
        }
        
        state = .readyToPlay
        
        //如果需要自动播放
        if options?.isAutoPlay ?? false {
            if shouldSeekTo > 0 { //shouldSeekTo的时间大于0，说明需要seek（主要是网络播放的场景，外部seek时plyer还没准备好）
                seek(time: shouldSeekTo, autoPlay: true) { [weak self] _ in
                    guard let self = self else { return }
                    self.shouldSeekTo = 0
                }
            } else { //正常播放
                play()
            }
        }
    }

    public func changeLoadState(player: MediaPlayerProtocol) {
        guard player.playbackState != .seeking else { return } //过滤seek
        //统计每次缓冲loading的时长，每一个缓冲从loading变为playable时，走这里
        if player.loadState == .playable, startTime > 0 { //每次player可以playable时，并且startTime有效
            
            let diff = CACurrentMediaTime() - startTime //计算从上次刚开始loading，到下次playable间的耗时
            
            delegate?.player(layer: self, bufferedCount: bufferedCount, consumeTime: diff)
            if bufferedCount == 0 { //刚进来或者resetPlayer后，bufferedCount才为0，进行初始加载进度的详细影响信息打印
                /*加载进度的详细影响信息打印
                var dic = ["firstTime": diff]
                if let options = options {
                    dic["prepareTime"] = options.starTime - startTime
                    dic["openTime"] = options.openTime - options.starTime
                    dic["findTime"] = options.findTime - options.starTime
                    dic["readVideoTime"] = options.readVideoTime - options.starTime
                    dic["readAudioTime"] = options.readAudioTime - options.starTime
                    dic["decodeVideoTime"] = options.decodeVideoTime - options.starTime
                    dic["decodeAudioTime"] = options.decodeAudioTime - options.starTime
                }
                HPLog(dic)
                 */
            }
            bufferedCount += 1
            startTime = 0 //重置为0，所以之后这段playable时间内不会触发上面的if逻辑，只有等到后面，播放过程中，持续加载时loadState再次变为不可播放的loading时，会重新更新起点时间，然后不为0，接着触发上面的if逻辑。
        }
        
        
        guard state.isPlaying else { return } //播放状态下处理，一进来加载时不处理
        if player.loadState == .playable { //开始可播放
            state = .bufferFinished //缓冲完成
        } else { //开始loading
            if state == .bufferFinished {
                startTime = CACurrentMediaTime() //重新开始耗时计算
            }
            state = .buffering //开始缓冲
        }
    }

    public func changeBuffering(player _: MediaPlayerProtocol, progress: Int) {
        bufferingProgress = progress
    }

    public func playBack(player _: MediaPlayerProtocol, loopCount: Int) {
        self.loopCount = loopCount
    }

    public func finish(player: MediaPlayerProtocol, error: Error?) {
        if let error = error {
            state = .error
            HPLog(error as CustomStringConvertible)
        } else {
            let duration = player.duration
            delegate?.player(layer: self, currentTime: duration, totalTime: duration)
            state = .playedToTheEnd
        }
        timer.fireDate = Date.distantFuture
        bufferedCount = 1
        delegate?.player(layer: self, finish: error)
    }
}

