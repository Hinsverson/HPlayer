//
//  HPSource.swift
//  HPlayer
//
//  Created by hinson on 2020/10/7.
//  Copyright © 2020 tommy. All rights reserved.
//

import Foundation
import AVFoundation

/// 播放器加载状态
public struct LoadingState {
    public let loadedTime: TimeInterval
    public let progress: TimeInterval
    public let packetCount: Int
    public let frameCount: Int
    public let isEndOfFile: Bool
    public let isPlayable: Bool
    public let isFirst: Bool
    public let isSeek: Bool
}
/// Item给到播放器的事件回调
protocol HPPlayerDelegate: AnyObject {
    func sourceDidOpened()
    func sourceDidChange(loadingState: LoadingState)
    func sourceDidFailed(error: NSError?)
    func sourceDidFinished(type: AVFoundation.AVMediaType, allSatisfy: Bool)
    func sourceDidChange(oldBitRate: Int64, newBitrate: Int64)
}

///视频自适应处理器
public struct VideoAdaptationState {
    public struct BitRateState {
        let bitRate: Int64
        let time: TimeInterval
    }

    ///提供选择的比特流
    public let bitRates: [Int64]
    public let duration: TimeInterval
    ///当前流的fps
    public internal(set) var fps: Int
    ///当前选择过的比特流信息和选择时间点
    public internal(set) var bitRateStates: [BitRateState]
    ///当前播放时间点
    public internal(set) var currentPlaybackTime: TimeInterval = 0
    ///能不能播放，实际取决于缓冲播放函数
    public internal(set) var isPlayable: Bool = false
    ///已经缓冲（read出来+解码出来）的frame数量
    public internal(set) var loadedCount: Int = 0
}

class HPSource {
    
    private let url: URL
    private let options: HPConfig
    
    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "HPlayer_FFAVParse"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()
    private var openOperation: BlockOperation?
    private var readOperation: BlockOperation?
    private var closeOperation: BlockOperation?
    
    private(set) var assetTracks = [HPMediaTrack]() //所有最上层记录信息的抽象Tarck
    private var allTracks = [HPSourceTrack]() //所有子track
    private var videoAudioTracks = [HPSourceTrack]()
    private(set) var subtitleTracks = [HPSourceTrack]()
    private var videoTrack: HPSourceTrack?
    private var audioTrack: HPSourceTrack?
    
    private var error: NSError? {
        didSet {
            if error != nil {
                state = .failed
                HPLog(error as! CustomStringConvertible)
            }
        }
    }
    private var state = HPSourceState.idle {
        didSet {
            switch state {
            case .opened:
                delegate?.sourceDidOpened()
            case .failed:
                delegate?.sourceDidFailed(error: error)
            default:
                break
            }
        }
    }
    private var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    
    ///*播放和同步相关
    ///音视频同步时，当前处理帧的时间
    private var positionTime = TimeInterval(0)
    ///打来流时，获取到的第一帧位置时间
    private var startTime = TimeInterval(0)
    ///没有音频，只渲染视频时，每次渲染动作的时间间隔记录
    private var videoMediaTime = CACurrentMediaTime()
    //没有音频数据可以渲染（同时也控制了同步的时候以音频还是视频为参考，true的逻辑相当于做无声视频的正常同步，false的逻辑相当于视频追音频的同步）
    private var isAudioStalled = true
    ///是否进行了首帧的预览渲染
    ///private var hasFrameToRender = false
    
    //*/
    
    //seek相关
    private var seekingCompletionHandler: ((Bool) -> Void)?
    
    ///控制Mepg资源访问状态的条件锁
    private let condition = NSCondition()
    ///用在对Track内Codec事件竞争处理
    private let semaphore = DispatchSemaphore(value: 1)
    
    
    ///记录是否是第一次处理loadState
    private var isFirst = true
    ///记录是否seek过
    private var isSeek = false
    
    ///视频自适应处理器
    private var videoAdaptation: VideoAdaptationState?
    
    
    private(set) var rotation = 0.0
    //MediaPlayback协议
    private(set) var naturalSize = CGSize.zero
    private(set) var duration: TimeInterval = 0
    var currentPlaybackTime: TimeInterval { max(positionTime - startTime, 0) }
    
    var isBackground = false
    var seekable: Bool {
        guard let formatCtx = formatCtx else {
            return false
        }
        var seekable = true
        if let ioContext = formatCtx.pointee.pb {
            seekable = ioContext.pointee.seekable > 0
        }
        return seekable && duration > 0
    }
    ///给播放器处理事件的的代理
    weak var delegate: HPPlayerDelegate?
    
    init(url: URL, options: HPConfig) {
        self.url = url
        self.options = options //配置參數信息
        avformat_network_init() //老版本时才需要调用
        //设置日志回调
        av_log_set_callback { _, level, format, args in
            guard let format = format, level <= HPManager.logLevel.rawValue else {
                return
            }
            var log = String(cString: format)
            //let arguments: CVaListPointer? = args
            if let arguments = args { log = NSString(format: log, arguments: arguments) as String }
            HPLog(log)
        }
    }
    
    ///给Player提供选择Track的入口
    func select(track: PlayerTrack) {
        if let track = track as? HPMediaTrack {
            assetTracks.filter { $0.mediaType == track.mediaType }.forEach { $0.stream.pointee.discard = AVDISCARD_ALL }
            track.stream.pointee.discard = AVDISCARD_DEFAULT
            if track.mediaType == .video || track.mediaType == .audio {
                seek(time: currentPlaybackTime, completion: nil)
            }
        }
    }
    
    deinit {
        if !operationQueue.operations.isEmpty {
            //shutdown()
            operationQueue.waitUntilAllOperationsAreFinished()
        }
    }
    
    private func openThread() {
        ///options.starTime = CACurrentMediaTime()
        avformat_close_input(&self.formatCtx) //先关闭
        formatCtx = avformat_alloc_context()
        guard let formatCtx = formatCtx else { error = NSError(errorCode: .formatCreate) ; return }
        //设置打断回调
        var interruptCB = AVIOInterruptCB()
        interruptCB.opaque = Unmanaged.passUnretained(self).toOpaque()
        interruptCB.callback = { ctx -> Int32 in
            guard let ctx = ctx else {
                return 0
            }
            //⚠️：不能直接return 1，会报avformat can’t open input错误，应该根据parse状态来控制是否打断。
            //return 1
            // Todo: 告诉FFmpeg是否需要打断状态
            let formatContext = Unmanaged<HPSource>.fromOpaque(ctx).takeUnretainedValue()
            switch formatContext.state {
            case .finished, .closed, .failed:
                return 1
            default:
                return 0
            }
        }
        formatCtx.pointee.interrupt_callback = interruptCB

        var avOptions = options.formatContextOptions.avOptions
        let urlString: String
        if url.isFileURL {
            urlString = url.path
        } else {
            ///* Todo：网络播放处理，https不会走FFmpeg的缓存，http会走
            if url.absoluteString.hasPrefix("https") || !options.cache { //ffmpeg only cache http
                urlString = url.absoluteString
            } else {
                //urlString = "async:cache:" + url.absoluteString //使用FFmpeg缓存
                urlString = url.absoluteString
            }
            //*/
            //urlString = ""
        }

        //打开并初始化formateContext
        //fmt: 如果非空表示强制指定一个输入流的格式, 设置为空会自动选择.
        var result = avformat_open_input(&self.formatCtx, urlString, nil, nil)
        //var result = avformat_open_input(&self.formatCtx, urlString, nil, &avOptions)
        av_dict_free(&avOptions) //注意释放，这里实际没有用到
        //Swift不能识别C的宏，所以这里写死，参考：[FFMPEG错误速查。_志的csdn博客-CSDN博客](https://blog.csdn.net/a360940265a/article/details/86155481)
        if IS_AVERROR_EOF(result) { //end of file
            state = .finished
            return
        }
        //打开失败处理
        guard result == 0 else {
            error = .init(errorCode: .formatOpenInput, ffmpegErrnum: result)
            avformat_close_input(&self.formatCtx)
            return
        }
        
        ///options.openTime = CACurrentMediaTime()
        
        //读取媒体文件的数据包以获取流信息
        result = avformat_find_stream_info(formatCtx, nil)
        guard result == 0 else {
            error = .init(errorCode: .formatFindStreamInfo, ffmpegErrnum: result)
            avformat_close_input(&self.formatCtx)
            return
        }
        
        ///options.findTime = CACurrentMediaTime() //记录find时间点
        ///options.formatName = String(cString: formatCtx.pointee.iformat.pointee.name) //记录打开的Mpeg名字
    
        //记录打开的Mpeg总时长
        duration = TimeInterval(max(formatCtx.pointee.duration, 0) / Int64(AV_TIME_BASE))
        
        createCodec(formatCtx: formatCtx)
        if videoTrack == nil, audioTrack == nil {
            state = .failed
        } else {
            state = .opened
            state = .reading
            read()
        }
    }
    
    private func createCodec(formatCtx: UnsafeMutablePointer<AVFormatContext>) {
        allTracks.removeAll()
        assetTracks.removeAll()
        videoAdaptation = nil
        videoTrack = nil
        audioTrack = nil
       
        ///*记录开始时间
        if formatCtx.pointee.start_time != Int64.min {
            startTime = TimeInterval(formatCtx.pointee.start_time / Int64(AV_TIME_BASE))
        }
        //*/
        assetTracks = (0 ..< Int(formatCtx.pointee.nb_streams)).compactMap { i in
            if let coreStream = formatCtx.pointee.streams[i] {
                coreStream.pointee.discard = AVDISCARD_ALL //设置为全忽略，后面维护开启
                return HPAssetTrack(stream: coreStream)
            } else {
                return nil
            }
        }
        var videoIndex: Int32 = -1
        if !options.videoDisable {
            let videos = assetTracks.filter { $0.mediaType == .video }
            ///* 这里的处理是通过bitRates来选择一条特定的流
            let bitRates = videos.map { $0.bitRate }
            let wantedStreamNb: Int32
            if videos.count > 0, let index = options.wantedVideo(bitRates: bitRates) {
                wantedStreamNb = videos[index].streamIndex
            } else {
                wantedStreamNb = -1
            }
            //*/
            //通过videoIndex去匹配抽象track
            videoIndex = av_find_best_stream(formatCtx, AVMEDIA_TYPE_VIDEO, wantedStreamNb, -1, nil, 0)
            if let first = videos.first(where: { $0.streamIndex == videoIndex }) {
                first.stream.pointee.discard = AVDISCARD_DEFAULT //和后面判断流是否enable有关，设置为AVDISCARD_DEFAULT，即enable=true，demuxed时不忽略
                
                //记录视频旋转角度，原size
                rotation = first.rotation
                naturalSize = first.naturalSize
                
                let track = HPSourceTrackAsync(assetTrack: first, options: options)
                videoAudioTracks.append(track)
                track.delegate = self //Track内codec事件处理代理
                videoTrack = track
                
                positionTime = first.timebase.cmtime(for: first.stream.pointee.start_time).seconds //自己新加的视频首帧时间，用于首帧预览时的对比，format中取的start_time是所有音视频、字幕的中首帧的最小时间，不能用那个。
                
                HPLog("ADAPTION DEBUG ｜ Video Track Count：\(videos.count)")
                HPLog("ADAPTION DEBUG ｜ First selected bitRate：\(first.bitRate)")
                
                ///*如果视频流大于1个时的自适应处理
                if videos.count > 1, options.videoAdaptable {
                    //打开时选择的那条流bitRate信息
                    let bitRateState = VideoAdaptationState.BitRateState(bitRate: first.bitRate, time: CACurrentMediaTime())
                    videoAdaptation = VideoAdaptationState(bitRates: bitRates.sorted(by: <), duration: duration, fps: first.fps, bitRateStates: [bitRateState])
                }
                //*/
            }
        }
        if !options.audioDisable {
            let audios = assetTracks.filter { $0.mediaType == .audio }
            ///* 这里的处理是通过bitRates来选择一条特定的流
            let wantedStreamNb: Int32
            if audios.count > 0, let index = options.wantedAudio(infos: audios.map { ($0.bitRate, $0.language) }) {
                wantedStreamNb = audios[index].streamIndex
            } else {
                wantedStreamNb = -1
            }
            //*/
            let audioIndex = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, wantedStreamNb, videoIndex, nil, 0)
            if let first = audios.first(where: { $0.streamIndex == audioIndex }) {
                first.stream.pointee.discard = AVDISCARD_DEFAULT
                let track = HPSourceTrackAsync(assetTrack: first, options: options)
                track.delegate = self
                videoAudioTracks.append(track)
                audioTrack = track
                
                //这里拿到了音频流，说明该Mpeg内有音频内容，设置为false，表示后续按照视频追音频的方式做同步。
                isAudioStalled = false
                
                HPLog("ADAPTION DEBUG ｜ Audio Track Count：\(audios.count)")
                HPLog("ADAPTION DEBUG ｜ First selected bitRate：\(first.bitRate)")
            }
        }
        if !options.subtitleDisable {
            /*
            subtitleTracks = assetTracks.filter { $0.mediaType == .subtitle }.map {
                $0.stream.pointee.discard = AVDISCARD_DEFAULT
                //return SubtitlePlayerItemTrack(assetTrack: $0, options: options)
                return SubtitlePlayerItemTrack(assetTrack: $0, options: options)
            }
            allTracks.append(contentsOf: subtitleTracks)
            */
        }
        allTracks.append(contentsOf: videoAudioTracks)
    }
    
    private func read() {
        HPLog("Read HPPacket Cycle - Start")
        readOperation = BlockOperation { [weak self] in
            guard let self = self else { return }
            Thread.current.name = (self.operationQueue.name ?? "") + "_read"
            Thread.current.stackSize = HPManager.stackSize
            self.readThread()
        }
        readOperation?.queuePriority = .veryHigh
        readOperation?.qualityOfService = .userInteractive
        if let openOperation = openOperation {
            readOperation?.addDependency(openOperation)
        }
        if let readOperation = readOperation {
            operationQueue.addOperation(readOperation)
        }
    }
    private func readThread() {
        //先异步 开始解码的动作 等待后续parse再putPacket数据
        allTracks.forEach { $0.decode() }
        //死循环parse读取直到状态改变：进行了一些pause、seek处理
        while [HPSourceState.paused, .seeking, .reading].contains(state) {
            if state == .paused { condition.wait() } //暂停状态下停止read线程往下走
            if state == .seeking {
                let timeStamp = Int64(positionTime * TimeInterval(AV_TIME_BASE))
                // can not seek to key frame
//                let result = avformat_seek_file(formatCtx, -1, timeStamp - 2, timeStamp, timeStamp + 2, AVSEEK_FLAG_BACKWARD)
                let result = av_seek_frame(formatCtx, -1, timeStamp, AVSEEK_FLAG_BACKWARD)//没有i桢的话向前seek
                if state == .closed {
                    break
                }
                allTracks.forEach { $0.seek(time: positionTime) }
                isSeek = true
                seekingCompletionHandler?(result >= 0)
                seekingCompletionHandler = nil
                state = .reading
            } else if state == .reading {
                autoreleasepool {
                    reading()
                }
            }
        }
        HPLog("Read HPPacket Cycle - Finish")
    }
    
    private func reading() {
        let packet = HPPacket()
        let readResult = av_read_frame(formatCtx, packet.corePacket) //
        if state == .closed { return }
        if readResult == 0 {
            if packet.corePacket.pointee.size <= 0 { return }
            packet.fill()
            let first = assetTracks.first { $0.stream.pointee.index == packet.corePacket.pointee.stream_index }
            if let first = first, first.isEnabled { //enable和stream的discard级别有关
                packet.assetTrack = first //在packet上记录反向的track信息，packet解码时会可能有用
                if first.mediaType == .video {
                    ///if options.readVideoTime == 0 { options.readVideoTime = CACurrentMediaTime() }
                    videoTrack?.putPacket(packet: packet)
                    ///print("读取出video HPPacket: \(packet.corePacket.pointee.dts)")
                } else if first.mediaType == .audio {
                    ///if options.readAudioTime == 0 { options.readAudioTime = CACurrentMediaTime() }
                    audioTrack?.putPacket(packet: packet)
                    ///print("读取出audio HPPacket: \(packet.corePacket.pointee.dts)")
                } else {
                    ///subtitleTracks.first { $0.assetTrack == first }?.putPacket(packet: packet)
                    ///print("读取出subtitle HPPacket: \(packet.corePacket.pointee.dts)")
                }
            }
            
        } else {
            //EFO错误比较特殊
            if IS_AVERROR_EOF(readResult) || avio_feof(formatCtx?.pointee.pb) != 0 {
                ///* 如果运行循环播放的话要继续seek播放，否则state标记为播放完成
                if options.isLoopPlay, allTracks.allSatisfy({ !$0.isLoopModel }) {
                    allTracks.forEach { $0.isLoopModel = true }
                    _ = av_seek_frame(formatCtx, -1, 0, AVSEEK_FLAG_BACKWARD)
                } else {
                    allTracks.forEach { $0.isEndOfFile = true }
                    state = .finished
                }
                //*/
                state = .finished
            } else {
                error = .init(errorCode: .readFrame, ffmpegErrnum: readResult)
                HPLog("Read Error")
            }
        }
    }
    
    private func pause() {
        if state == .reading {
            state = .paused
        }
    }

    private func resume() {
        if state == .paused {
            state = .reading
            condition.signal()
        }
    }
    ///视频流大于1个时的自适应切换处理。
    private func adaptable(track: HPSourceTrack, loadingState: LoadingState) {
        //切换的前提是视频流，并且还没有read到尾部
        guard var videoAdaptation = videoAdaptation, track.mediaType == .video, !loadingState.isEndOfFile else {
            return
        }
        //提取一些必要判断信息
        videoAdaptation.loadedCount = track.packetCount + track.frameCount
        videoAdaptation.currentPlaybackTime = currentPlaybackTime
        videoAdaptation.isPlayable = loadingState.isPlayable
        //切换成功
        guard let (oldBitRate, newBitrate) = options.adaptable(state: videoAdaptation) else {
            return
        }
        //忽略旧的视频流
        assetTracks.first { $0.mediaType == .video && $0.bitRate == oldBitRate }?.stream.pointee.discard = AVDISCARD_ALL
        if let newAssetTrack = assetTracks.first(where: { $0.mediaType == .video && $0.bitRate == newBitrate }) {
            //开启新的视频流
            newAssetTrack.stream.pointee.discard = AVDISCARD_DEFAULT
            /* 切换视频流后，对于音频流的选择处理
             基本思路：通过av_find_best_stream传入原来音频的index和切换后的视频流index作为参考流去找音频流
             如果找出的音频流和原来的音频流index不同，说明有多个音频流且能找到和切换后视频流相关联的音频流，那么需要忽略旧的音频流，开启新的音频流。
             */
            if let first = assetTracks.first(where: { $0.mediaType == .audio && $0.isEnabled }) {
                let index = av_find_best_stream(formatCtx, AVMEDIA_TYPE_AUDIO, first.streamIndex, newAssetTrack.streamIndex, nil, 0)
                if index != first.streamIndex {
                    first.stream.pointee.discard = AVDISCARD_ALL
                    assetTracks.first { $0.mediaType == .audio && $0.streamIndex == index }?.stream.pointee.discard = AVDISCARD_DEFAULT
                }
            }
        }
        //添加一次选择点，下一次切换时会以最后一个选择点作为参考
        let bitRateState = VideoAdaptationState.BitRateState(bitRate: newBitrate, time: CACurrentMediaTime())
        self.videoAdaptation?.bitRateStates.append(bitRateState)
        delegate?.sourceDidChange(oldBitRate: oldBitRate, newBitrate: newBitrate) //流变化的通知
    }
}

//MARK: - Item对Track内Codec的事件处理
extension HPSource: HPCodecCapacityDelegate {
    ///track中queue的packet增减变化就会触发
    ///在reading线程put packet后、decode线程处理完一个packet增加了frame后、从outputQueue中取到一个frame用于送出去渲染之后，seek时、read读取到资源尾部后
    ///⚠️所以这里要考虑多线程问题
    func codecDidChangeCapacity(track: HPSourceTrack) {
        semaphore.wait()
        defer {
            semaphore.signal()
            if isBackground, let videoTrack = videoTrack, videoTrack.frameCount > videoTrack.frameMaxCount >> 1 {
                _ = getOutputRender(type: .video) //空渲染
            }
        }
        //取缓冲状态
        guard let loadingState = options.playable(capacitys: videoAudioTracks, isFirst: isFirst, isSeek: isSeek) else {
            return
        }
        
        delegate?.sourceDidChange(loadingState: loadingState)
        if loadingState.isPlayable {
            isFirst = false
            isSeek = false
            //向后load的节流处理：已load的时间大于最大则暂停read，小于最大的一半则又开启
            if loadingState.loadedTime > options.maxBufferDuration {
                adaptable(track: track, loadingState: loadingState) //缓冲已经足够，说明网络和解码情况良好，尝试去进行高比特流的切换
                pause()
            } else if loadingState.loadedTime < options.maxBufferDuration / 2 {
                resume()
            }
        } else {
            resume()
            adaptable(track: track, loadingState: loadingState) //缓冲不是很充分，说明网络和解码情况不好，尝试去进行低比特流的切换
        }
    }

    func codecDidFinished(track: HPSourceTrack) {
        if track.mediaType == .audio {
            isAudioStalled = true
        }
        let allSatisfy = videoAudioTracks.allSatisfy { $0.isEndOfFile && $0.frameCount == 0 && $0.packetCount == 0 }
        delegate?.sourceDidFinished(type: track.mediaType, allSatisfy: allSatisfy)
        if allSatisfy, options.isLoopPlay {
            isAudioStalled = audioTrack == nil
            audioTrack?.isLoopModel = false
            videoTrack?.isLoopModel = false
            if state == .finished {
                state = .reading
                read()
            }
        }
    }
}

extension HPSource: MediaPlayback {
    ///开始parse
    func prepareToPlay() {
        state = .opening
        openOperation = BlockOperation { [weak self] in
            guard let self = self else { return }
            Thread.current.name = (self.operationQueue.name ?? "") + "_open"
            Thread.current.stackSize = HPManager.stackSize
            self.openThread()
        }
        openOperation?.queuePriority = .veryHigh
        openOperation?.qualityOfService = .userInteractive
        if let op = openOperation { operationQueue.addOperation(op) }
    }
    func shutdown() {
        guard state != .closed else { return }
        
        state = .closed
        condition.signal() //
        
        // 故意循环引用。等结束了。才释放
        let closeOp = BlockOperation {
            Thread.current.name = (self.operationQueue.name ?? "") + "_close"
            self.allTracks.forEach { $0.shutdown() } //清理track内queue中的资源
            HPObjectCachePool.share.removeAll()
            HPLog("清空formatCtx")
            avformat_close_input(&self.formatCtx)
            self.duration = 0
            self.closeOperation = nil
            self.operationQueue.cancelAllOperations()
            HPObjectCachePool.share.removeAll()
        }
        closeOp.queuePriority = .veryHigh
        closeOp.qualityOfService = .userInteractive
        if let readOp = readOperation {
            readOp.cancel()
            closeOp.addDependency(readOp)
        } else if let openOp = openOperation {
            openOp.cancel()
            closeOp.addDependency(openOp)
        }
        operationQueue.addOperation(closeOp)
        closeOperation = closeOp
    }

    func seek(time: TimeInterval, completion handler: ((Bool) -> Void)?) {
        if state == .reading || state == .paused {
            positionTime = time + startTime
            seekingCompletionHandler = handler
            state = .seeking
            condition.broadcast()
        } else if state == .finished {
            positionTime = time + startTime
            seekingCompletionHandler = handler
            state = .seeking
            read()
        }
        isAudioStalled = audioTrack == nil
    }
}

 /* 音视频同步处理
  整体采用音频的渲染播放时间线为标准，视频追音频的方式来做同步（成立的条件是音频的实际渲染频率高于原视频的桢率）。
  首先是视频渲染回调从getOutputRender拿第一桢视频数据渲染，此时desire=0，所以能取到第一个视频桢。
  其次是音频渲染回调从getOutputRender拿音频数据进行渲染，渲染播放完成后setAudio更新positionTime(秒)，表示音频播放到了多少秒（外部处理音频渲染时，一次渲染播放的周期内存在多次getOutputRender拿数据的情况，因为可能拿一次的数据不够完成一次audioPlayerDidRenderSample渲染播放，需要多次在audioPlayerShouldInputData填充数据去渲染）
  isAudioStalled在parse音频轨道时被设置为false，所以音频渲染后能更新positionTime。
  同时视频渲染回调（按照MTKView刷新频率）也会从getOutputRender拿视频数据，没拿到就不渲染，，只拿cmtime比desire小的frame
  如果isAudioStalled为true，表示没有音频数据时也需要渲染视频数据，需要通过videoMediaTime单独记录只渲染视频的时间长度，那么拿视频数据时要用 desire += max(CACurrentMediaTime() - self.videoMediaTime, 0)来做过滤取frame。
  实际情况是音频的一次有效渲染频率（setAudio）比视频渲染频率高（setVideo），所以音频数据一直在送出去渲染并更新positionTime，当视频渲染刷新回调过来时（比如每秒60次），发现如果队头中有数据且position比positionTime小就直接送出去渲染，如果队头视频桢position比positionTime大，那么取不到合适的就不渲染，直到音频渲染后更新positionTime，直到positionTime大于等于队头视频桢position，下一次视频渲染刷新回调过来时再取出去渲染。
  
  上面成立的条件是音频的实际渲染频率高于对应视频桢的切换频率（实际调试确实是这样）
  可以理解为非常多个音频渲染节点才会有一个对应的应该被渲染的视频桢节点（比如音频渲染节点有1，2，3，4，5，但是只有节点1和5才对应切换一个视频桢1和2）
  而视频渲染频率，比如60次1秒，只是影响取视频桢去渲染这个动作的频率，只要当视频渲染刷新频率（MTKView刷新频率）高于原本视频桢切换频率（原视频1s内有多少个视频桢节点）就可以保证每桢视频画面都能被取出去渲染。否则相当于在音频渲染到5节点，应该取视频桢2的时候，只取到了视频桢1（因为这里的设计队列内的视频桢只能一个一个出队），就会出现声音正常按1倍速度渲染播放，画面却一卡一卡的展示，音频比视频快的不同步（经过实际修改preferredFramesPerSecond测试验证正确）。
  一般不会考虑这种场景（视频渲染刷新频率（MTKView刷新频率）小于原本视频桢切换频率），因为这样的话相当于损失了视频的流畅度，这种场景只存在于视频原本的桢率非常高，还要在低刷新率设备上播放的场景，解决方法是直接出队丢弃并继续出队下一个桢，直到追上音频，当然这里没有做这种处理。
  
  尝试理解下面的过程
  音频渲染节点：1 2 3 4 5 6 7 8 9
  视频渲染节点：1       2       3
  屏幕刷新节点：1   2   3   4   5
  */

///* 单视频渲染时间同步处理（按照标准速率播放）
/* 思路
 setVideo回调内更新positionTime（初始为0，用以记录即将被渲染的视频桢的pts）
 setVideo回调内同时更新渲染点的当前时间刻度（CACurrentMediaTime()）
 外部MTKView根据内部刷新频率通过getOutputRender方法从Track的桢队列里内取视频桢时，通过CACurrentMediaTime() - self.videoMediaTime计算得到渲染的间隔时间，取的时候只取pts比positionTime+渲染间隔时间小的桢送出去渲染
 
 ⚠️当然这里的逻辑成立的依据是MTKView刷新回调频率高于Track的桢队列里桢的生成频率（解码频率），队列内一有视频桢就被送出去渲染了，没有的话就不渲染。
 ⚠️如果设置的MTKView的刷新回调小于Track的桢队列里桢的生成频率（解码频率），相当于在渲染时Track的桢队列里的桢不断累积，而取的时候（出队）又总是一个一个从前往后出，所以视频播放画面就像调慢了倍速一样。
 ⚠️如果为了健壮性，MTKView的刷新回调小于Track的桢队列里桢的生成频率（解码频率）时也要保证画面按正常速度播放，那么需要在出队的时机filter合适的桢（最靠近pst的桢），方法是出队时循环处理，记录出队桢的pst，除了最靠近真实播放pst的那个桢，前面取出的桢都丢弃，最后送出最靠近真实播放pst的那个桢。
 */
extension HPSource: HPOutputRenderDelegate {
    func setVideo(time: CMTime) {
        positionTime = time.seconds
        videoMediaTime = CACurrentMediaTime()
    }
    func setAudio(time: CMTime) {
        if !isAudioStalled {
            positionTime = time.seconds
        }
    }
    /// Item层作为代理提供给外部进行渲染的入口，item会去对应的Track的renderQueue中取数据
    func getOutputRender(type: AVFoundation.AVMediaType) -> HPFrame? {
        //这里是在做播放时的时间有效处理，保证拿出去渲染的HPFrameBase是时间上小于或者等于当前播放时间的
        var predicate: ((HPFrame) -> Bool)?
        ///* 原来的同步处理
        if type == .video {
            predicate = { [weak self] (frame) -> Bool in
                guard let self = self else { return true }
                var desire = self.positionTime //当前期望的，已渲染到的时间节点
                
                if self.isAudioStalled {
                    //无声视频同步时，需要加上渲染的间隔时间保证正常倍速切换视频桢
                    desire += max(CACurrentMediaTime() - self.videoMediaTime, 0)
                }
                
                /*⚠️问题已经找到，是因为解码的时候，对frame的position选取错误
                //let start = self.startTime
                let frameTime = frame.cmtime.seconds
                //let valid = frameTime < start
                //这里的处理是因为调试中发现，网络视频播放时，解码到的第一帧时间点小于打开流时从FFmpeg中记录的startTime（打开的同时会用startTime更新positionTime，原来没有这步处理，positionTime就是默认初始为0，所以第一次预览去取时desire为0，如果第一帧时间点不是0就会出现上面这种情况，预览不到画面）
                if frameTime <= desire || !self.hasFrameToRender {
                    self.hasFrameToRender = true
                    return true
                } else {
                    return false
                }
                */
                return frame.cmtime.seconds <= desire //队列里的frame时间要比当前需要被渲染的时间小（METView回调时间）
            }
        }
        //*/
        
        var frame: HPFrame? = nil
        if type == .video {
            frame = videoTrack?.getOutputRender(where: predicate)
        } else {
            frame = audioTrack?.getOutputRender(where: predicate)
        }
        
        if let frame = frame {
            return frame
        }
        return nil
        
        //return (type == .video ? videoTrack : audioTrack)?.getOutputRender(where: predicate)
    }
}
//*/
