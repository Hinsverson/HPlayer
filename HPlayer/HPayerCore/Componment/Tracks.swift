//
//  Tracks.swift
//  HPlayer
//
//  Created by hinson on 2020/12/3.
//  Copyright © 2020 tommy. All rights reserved.
//

import UIKit
import AVFoundation

/////Track类型
//public enum MediaPlayerTrackType: String {
//    case video
//    case audio
//    case subtitle
//}

///Track的基本抽象描述
public protocol PlayerTrack {
    var name: String { get }
    var language: String? { get }
    var mediaType: AVFoundation.AVMediaType { get }
    var fps: Int { get }
    var rotation: Double { get }
    var bitRate: Int64 { get }
    var naturalSize: CGSize { get }
    var isEnabled: Bool { get }
}
///FFMpeg Track的基本抽象描述
protocol HPMediaTrack: PlayerTrack, CustomStringConvertible {
    var stream: UnsafeMutablePointer<AVStream> { get }
    var timebase: HPTimebase { get }
}
extension HPMediaTrack {
    var description: String { name }
    var isEnabled: Bool {
        get { stream.pointee.discard == AVDISCARD_DEFAULT }
        set { stream.pointee.discard = newValue ? AVDISCARD_DEFAULT : AVDISCARD_ALL }
    }
}
extension HPMediaTrack {
    var streamIndex: Int32 { stream.pointee.index }
}

extension HPMediaTrack {
    ///便捷的创建解码器
    func makeDecode(options: HPConfig) -> HPDecode {
        autoreleasepool {
            if let session = DecodeSession(codecpar: stream.pointee.codecpar.pointee, options: options) {
                return HPHardwareDecode(assetTrack: self, options: options, session: session)
            } else {
                return HPSoftwareDecode(assetTrack: self, options: options)
            }
        }
    }
}

func == (lhs: HPMediaTrack, rhs: HPMediaTrack) -> Bool {
    lhs.streamIndex == rhs.streamIndex
}

///FFMpeg Track的基本包装类，主要用途是方便地map存储一些信息
struct HPAssetTrack: HPMediaTrack {
    let name: String
    let language: String?
    let stream: UnsafeMutablePointer<AVStream>
    let mediaType: AVFoundation.AVMediaType
    let timebase: HPTimebase
    let fps: Int
    let bitRate: Int64
    let rotation: Double
    let naturalSize: CGSize
    init?(stream: UnsafeMutablePointer<AVStream>) {
        self.stream = stream
        if let bitrateEntry = av_dict_get(stream.pointee.metadata, "variant_bitrate", nil, 0) ?? av_dict_get(stream.pointee.metadata, "BPS", nil, 0),
            let bitRate = Int64(String(cString: bitrateEntry.pointee.value)) {
            self.bitRate = bitRate
        } else {
            bitRate = stream.pointee.codecpar.pointee.bit_rate
        }
        if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
            mediaType = .audio
        } else if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO {
            mediaType = .video
        } else if stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE {
            mediaType = .subtitle
        } else {
            return nil
        }
        var timebase = HPTimebase(stream.pointee.time_base)
        if timebase.num <= 0 || timebase.den <= 0 {
            timebase = HPTimebase(num: 1, den: mediaType == .audio ? HPManager.audioPlayerSampleRate : 25000)
        }
        self.timebase = timebase
        rotation = stream.rotation
        naturalSize = CGSize(width: Int(stream.pointee.codecpar.pointee.width), height: Int(stream.pointee.codecpar.pointee.height))
        let frameRate = av_guess_frame_rate(nil, stream, nil)
        if stream.pointee.duration > 0, stream.pointee.nb_frames > 0, stream.pointee.nb_frames != stream.pointee.duration {
            fps = Int(stream.pointee.nb_frames * Int64(timebase.den) / (stream.pointee.duration * Int64(timebase.num))) //1s有多少桢，duration时间戳*timebase时间基（num/dem）得到实际的时刻值。
        } else if frameRate.den > 0, frameRate.num > 0 {
            fps = Int(frameRate.num / frameRate.den)
        } else {
            fps = mediaType == .audio ? 44 : 24
        }
        if let entry = av_dict_get(stream.pointee.metadata, "language", nil, 0), let title = entry.pointee.value {
            language = NSLocalizedString(String(cString: title), comment: "")
        } else {
            language = nil
        }
        if let entry = av_dict_get(stream.pointee.metadata, "title", nil, 0), let title = entry.pointee.value {
            name = String(cString: title)
        } else {
            if let language = language {
                name = language
            } else {
                name = mediaType == .subtitle ? NSLocalizedString("built-in subtitles", comment: "") : mediaType.rawValue
            }
        }
    }
}

///缓冲情况
public protocol PlayerTrackCapacity {
    var fps: Int { get }
    ///缓冲到的已read出来的packet
    var packetCount: Int { get }
    ///缓冲到已经解码的帧
    var frameCount: Int { get }
    var frameMaxCount: Int { get }
    var isEndOfFile: Bool { get }
    var mediaType: AVFoundation.AVMediaType { get }
}

///播放器 Track的基本抽象描述
protocol HPSourceTrack: PlayerTrackCapacity, AnyObject {
    init(assetTrack: HPMediaTrack, options: HPConfig)
    
    ///source通过它，告诉track，是否需要支持循环播放的解码处理（实际时机就是source内read循环已经经读取packet到了资源尾部）
    var isLoopModel: Bool { get set }
    var isEndOfFile: Bool { get set }
    var delegate: HPCodecCapacityDelegate? { get set }
    /// 解码动作的入口
    func decode()
    func seek(time: TimeInterval)
    func putPacket(packet: HPPacket)
    /// 对外渲染取数据的入口
    func getOutputRender(where predicate: ((HPFrame) -> Bool)?) -> HPFrame?
    /// 结束处理
    func shutdown()
}

protocol HPCodecCapacityDelegate: AnyObject {
    func codecDidChangeCapacity(track: HPSourceTrack)
    func codecDidFinished(track: HPSourceTrack)
}

///FFMpeg Track的基类（抽象，用于子类继承）
class HPSourceTrackBase<HPFrameBase: HPFrame>: HPSourceTrack, CustomStringConvertible {
    var isLoopModel = false
    var isEndOfFile: Bool = false
    weak var delegate: HPCodecCapacityDelegate?
    
    var packetCount: Int { 0 }
    var frameCount: Int { outputRenderQueue.count }
    let frameMaxCount: Int
    let description: String
    fileprivate var state = HPCodecState.idle
    let fps: Int
    let options: HPConfig
    let mediaType: AVFoundation.AVMediaType
    let outputRenderQueue: HPCircularQueue<HPFrameBase>

    required init(assetTrack: HPMediaTrack, options: HPConfig) {
        //从assetTrack拿必要的信息
        mediaType = assetTrack.mediaType
        description = mediaType.rawValue
        fps = assetTrack.fps
        self.options = options
        
        //创建环形渲染队列
        //默认缓存队列大小跟帧率挂钩,经测试除以4，最优
        if mediaType == .audio {
            outputRenderQueue = HPCircularQueue(initialCapacity: HPConfig.audioFrameMaxCount, expanding: false)
        } else if mediaType == .video {
            outputRenderQueue = HPCircularQueue(initialCapacity: HPConfig.videoFrameMaxCount, sorted: true, expanding: false)
        } else {
            outputRenderQueue = HPCircularQueue()
        }
        frameMaxCount = outputRenderQueue.maxCount //这里的最大取环形队列的最大数，outputRenderQueue创建时根据options内的videoFrameMaxCount会进行容错处理，实际数量必须是大于videoFrameMaxCount且小于2的次幂数。
    }

    func decode() {
        isEndOfFile = false
        state = .decoding
    }

    func seek(time _: TimeInterval) {
        isEndOfFile = false
        state = .flush
        outputRenderQueue.flush()
    }

    func putPacket(packet _: HPPacket) {
        fatalError("Abstract method")
    }
    
    func getOutputRender(where predicate: ((HPFrame) -> Bool)?) -> HPFrame? {
        outputRenderQueue.pop(where: predicate)
    }
    
    func shutdown() {
        if state == .idle {
            return
        }
        state = .closed
        outputRenderQueue.shutdown()
    }

    deinit {
        shutdown()
    }
}

final class HPSourceTrackAsync: HPSourceTrackBase<HPFrameBase> {
    private let operationQueue = OperationQueue()
    private var decoderMap = [Int32: HPDecode]()
    private var decodeOperation: BlockOperation!
    private var seekTime = 0.0
    //无缝播放使用的PacketQueue
    private var loopPacketQueue: HPCircularQueue<HPPacket>?
    private var packetQueue = HPCircularQueue<HPPacket>()
    
    //重写的属性
    override var packetCount: Int { packetQueue.count }

    ///⌛️：目前的理解是只有isLoopModel被该为true时，read线程没有停，这个packetQueue才有用。
    override var isLoopModel: Bool { //支持循环播放时，source线程在read到资源末尾时触发修改为true，此时一般播放渲染还没有到最后
        didSet {
            if isLoopModel { //创建新的loopPacketQueue用以暂存接下来source又从头read出来的packet
                loopPacketQueue = HPCircularQueue<HPPacket>()
                isEndOfFile = true
            } else { //然后上一次播放结束后，如果需要循环播放时，source内会在播放结束后修改为false，此时loopPacketQueue已经存了一些source从头read出来的packet，所以需要换loopPacketQueue给packetQueue，之后就又开始用packetQueue去接收从source中read过来的packet。
                if let loopPacketQueue = loopPacketQueue {
                    packetQueue.shutdown()
                    packetQueue = loopPacketQueue
                    self.loopPacketQueue = nil
                }
            }
        }
    }
    
    override var isEndOfFile: Bool {
        didSet {
            if isEndOfFile {
                //⚠️这里在rsource的read线程读取到资源末尾时不会触发，因为此时state并不是finish
                if state == .finished, frameCount == 0 {
                    delegate?.codecDidFinished(track: self)
                }
                delegate?.codecDidChangeCapacity(track: self)
            }
        }
    }

    required init(assetTrack: HPMediaTrack, options: HPConfig) {
        decoderMap[assetTrack.streamIndex] = assetTrack.makeDecode(options: options)
        super.init(assetTrack: assetTrack, options: options)
        operationQueue.name = "HPlayer_" + description
        operationQueue.maxConcurrentOperationCount = 1
        operationQueue.qualityOfService = .userInteractive
    }

    override func putPacket(packet: HPPacket) {
        if isLoopModel {
            loopPacketQueue?.push(packet)
        } else {
            packetQueue.push(packet)
        }
        delegate?.codecDidChangeCapacity(track: self)
    }

    // 解码入口：外部是先decode，再parsePacket
    override func decode() {
        HPLog("Decode HPPacket Cycle - Start")
        guard operationQueue.operationCount == 0 else { return }
        decodeOperation = BlockOperation { [weak self] in
            guard let self = self else { return }
            Thread.current.name = self.operationQueue.name
            Thread.current.stackSize = HPManager.stackSize
            self.decodeThread()
        }
        decodeOperation.queuePriority = .veryHigh
        decodeOperation.qualityOfService = .userInteractive
        operationQueue.addOperation(decodeOperation)
    }

    // 渲染入口：对外部提供渲染数据，解码后会把数据放在outputRenderQueue中
    override func getOutputRender(where predicate: ((HPFrame) -> Bool)?) -> HPFrame? {
        let outputFecthRender = outputRenderQueue.pop(where: predicate)
        if outputFecthRender == nil {
            //⚠️当outputRenderQueue中取不到frame送出取渲染，这里就是最终的播放结束状态，通过codecDidFinished通知给source处理。
            if state == .finished, frameCount == 0 {
                delegate?.codecDidFinished(track: self)
            }
        } else {
            delegate?.codecDidChangeCapacity(track: self) //回调出去做一些播放控制相关处理
        }
        return outputFecthRender
    }

    override func seek(time: TimeInterval) {
        isEndOfFile = false
        seekTime = time
        packetQueue.flush() //清空read出来的packetQueue内的数据
        super.seek(time: time) //会清空decode出来的frame数据
        loopPacketQueue = nil //seek时如果有循环播放，并且read已经开始往loopPacketQueue中加packet了这种场景也要把loopPacketQueue中预先read出来这部分数据清空释放掉，因为只要是seek，必须从当前seek位置重新read再解码渲染处理。
        isLoopModel = false
        delegate?.codecDidChangeCapacity(track: self)
        decoderMap.values.forEach { $0.seek(time: time) }
    }

    override func shutdown() {
        if state == .idle {
            return
        }
        super.shutdown()
        packetQueue.shutdown()
        operationQueue.cancelAllOperations()
        if Thread.current.name != operationQueue.name {
            operationQueue.waitUntilAllOperationsAreFinished()
        }
        decoderMap.values.forEach { $0.shutdown() }
        decoderMap.removeAll()
    }
    
    private func decodeThread() {
        state = .decoding
        isEndOfFile = false //标记开始
        decoderMap.values.forEach { $0.decode() } //准备解码动作
        //死循环decode处理，直到decodeOperation canceled
        while !decodeOperation.isCancelled {
            if state == .flush { //擦除状态的处理
                decoderMap.values.forEach { $0.doFlushCodec() }
                state = .decoding
            } else if isEndOfFile && packetQueue.count == 0 { //⚠️这里是最终的解码结束状态，当source 线程read到资源末尾时如果在循环播放模式时会先去修改isEndOfFile==true，并且重新创建packetQueue，所以count计数为0，接着decode线程走到这里而decode结束。
                state = .finished
                break
            } else if state == .decoding {
                guard let packet = packetQueue.pop(wait: true), state != .flush, state != .closed else {
                    continue //没有取到就下一循环
                }
                autoreleasepool {
                    doDecode(packet: packet)
                }
            } else {
                break
            }
        }
        HPLog("DecodeOperation finish")
    }
    private func doDecode(packet: HPPacket) {
        let decoder = decoderMap.value(for: packet.assetTrack.streamIndex, default: packet.assetTrack.makeDecode(options: options))
        do {
            //视频硬解直接送到VT中，无需重采样
            //视频软件解，需要重采样
            //音频只有软解，需要重采样
            let array = try decoder.doDecode(packet: packet.corePacket)
            /*记录decode信息
            if options.decodeAudioTime == 0, mediaType == .audio {
                options.decodeAudioTime = CACurrentMediaTime()
            }
            if options.decodeVideoTime == 0, mediaType == .video {
                options.decodeVideoTime = CACurrentMediaTime()
            }*/
            array.forEach { frame in
                if state == .flush || state == .closed {
                    return
                }
                //拿到frame
                ///* seek处理
                if seekTime > 0, options.isAccurateSeek {
                    if frame.timebase.cmtime(for: frame.position + frame.duration).seconds < seekTime {
                        return
                    } else {
                        seekTime = 0.0
                    }
                }
                //*/
                //开始渲染
                outputRenderQueue.push(frame)
                //通知出去做一些播放控制相关的逻辑
                delegate?.codecDidChangeCapacity(track: self)
            }
        } catch {
            HPLog("Decoder did Failed : \(error)")
            ///*如果硬解失败，考虑软解
            if decoder is HPHardwareDecode {
                decoderMap[packet.assetTrack.streamIndex] = HPSoftwareDecode(assetTrack: packet.assetTrack, options: options)
                HPLog("VideoCodec switch to software decompression")
                doDecode(packet: packet)
            } else {
                state = .failed
            }
            //*/
        }
    }
}

extension Dictionary {
    public mutating func value(for key: Key, default defaultValue: @autoclosure () -> Value) -> Value {
        if let value = self[key] {
            return value
        } else {
            let value = defaultValue()
            self[key] = value
            return value
        }
    }
}
