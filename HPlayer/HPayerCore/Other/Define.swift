//
//  Define.swift
//  HPlayer
//
//  Created by hinson on 2020/10/7.
//  Copyright © 2020 tommy. All rights reserved.
//

import Foundation
import AVFoundation
import Metal

public class HPConfig {
    
    public var videoDisable = false
    public var audioDisable = false
    public var subtitleDisable = false
    
    public static let audioFrameMaxCount = 16
    public static let videoFrameMaxCount = 8
    
    public var bufferPixelFormatType = HPConfig.bufferPixelFormatType
    
    /// 视频像素格式
    /// kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange，nv12，y和uv分别存储，u在前
    /// kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    /// kCVPixelFormatType_32BGRA
    ///
    public static var bufferPixelFormatType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    public var hardwareDecodeH264 = HPConfig.hardwareDecodeH264
    public var hardwareDecodeH265 = HPConfig.hardwareDecodeH265
    
    public static var hardwareDecodeH264 = false //默认为true，选用硬解（⚠️构造AVCodecContext时会有区别，构造的AVCodecContext一定要和外部使用的软硬解码模块对应，否则会有问题）
    public static var hardwareDecodeH265 = true
    ///异步
    public var asynchronousDecompression = false
    
    
    public var lowres = UInt8(0)
    public var decoderOptions = [String: Any]()
    
    
    ///public var display = HPDisplayEnum.plane
    
    /// Applies to short videos only
    public var isLoopPlay = HPConfig.isLoopPlay
    /// Applies to short videos only
    public static var isLoopPlay = false
    
    
    /// 是否自动播放，默认false
    public var isAutoPlay = HPConfig.isAutoPlay
    /// 是否自动播放，默认false
    public static var isAutoPlay = false
    
    
    /// 开启精确seek
    public var isAccurateSeek = HPConfig.isAccurateSeek
    /// 开启精确seek
    public static var isAccurateSeek = true
    
    /// 最大缓存视频时间
    public var maxBufferDuration = HPConfig.maxBufferDuration
    /// 最大缓存视频时间
    public static var maxBufferDuration = 30.0
    
    
    ///是否开启自适应
    public var videoAdaptable = true
    
    
    /// 最低缓存视频时间
    @HPObservable
    public var preferredForwardBufferDuration = HPConfig.preferredForwardBufferDuration
    /// 最低缓存视频时间
    public static var preferredForwardBufferDuration = 3.0
    
    /// 是否开启秒开
    public var isSecondOpen = HPConfig.isSecondOpen
    /// 是否开启秒开
    public static var isSecondOpen = false
    
    /// seek完是否自动播放
    public var isSeekedAutoPlay = HPConfig.isSeekedAutoPlay
    /// seek完是否自动播放
    public static var isSeekedAutoPlay = true
    
    
    ///ffmpeg only cache http
    public var cache = true
    
    ///节流器，防止频繁的更新加载状态
    private var throttle = mach_absolute_time()
    private let throttleDiff: UInt64
    public var formatContextOptions = [String: Any]()
    public init() {
        ///一些配置
        formatContextOptions["auto_convert"] = 0
        formatContextOptions["fps_probe_size"] = 3
        formatContextOptions["reconnect"] = 1
        // There is total different meaning for 'timeout' option in rtmp
        // remove 'timeout' option for rtmp、rtsp
        formatContextOptions["timeout"] = 30_000_000
        formatContextOptions["rw_timeout"] = 30_000_000
        formatContextOptions["user_agent"] = "hpplayer"
        decoderOptions["threads"] = "auto"
        decoderOptions["refcounted_frames"] = "1"
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        //间隔0.1s
        throttleDiff = UInt64(100_000_000 * timebaseInfo.denom / timebaseInfo.numer)
    }
    
    ///缓冲算法函数（⚠️）
    open func playable(capacitys: [PlayerTrackCapacity], isFirst: Bool, isSeek: Bool) -> LoadingState? {
        /*关于mach_absolute_time，参考：https://blog.csdn.net/auspark/article/details/104460953
         简单讲就是系统启动后CPU的运转计数，在锁屏时会停止，重启后会重新更新
         */
        //0.1s时间间隔、第一次、seek过后做一次LoadingState的更新
        guard isFirst || isSeek || mach_absolute_time() - throttle > throttleDiff else {
            return nil
        }
        let packetCount = capacitys.map { $0.packetCount }.min() ?? 0 //音视频track中，最小packetCount数
        let frameCount = capacitys.map { $0.frameCount }.min() ?? 0 //音视频track中，最小frameCount数
        let isEndOfFile = capacitys.allSatisfy { $0.isEndOfFile } //音视频track中，都为EndOfFile才是EndOfFile
        //fps: 解析流时track记录得到的流中每秒有多少桢（frame）
        //loadedTime =（待解码桢数量+已经解码还没渲染的针数量）* 每针占多少秒（fps的倒数）
        //loadedTime在播放过程中是动态变化的
        let loadedTime = capacitys.map { TimeInterval($0.packetCount + $0.frameCount) / TimeInterval($0.fps) }.min() ?? 0 //取所有track中最小的
        HPLog("⏰loadedTime：\(loadedTime)")
        let progress = loadedTime * 100.0 / preferredForwardBufferDuration //暂时没用
        
        //isPlayable状态的计算处理（⚠️）
        let isPlayable = capacitys.allSatisfy { capacity in //所有为true才为true
            //刚进入，或者seek发生(相当于重新处理)
            if isFirst || isSeek {
                //track内outputQueue中待渲染的帧数 > 最大存储容量/2
                if capacity.frameCount >= capacity.frameMaxCount >> 1 {
                    //让音频能更快的打开播放
                    if capacity.mediaType == .audio || isSecondOpen {
                        if isFirst {
                            return true
                        } else if isSeek, capacity.packetCount >= capacity.fps { //seek后queue中又存到的packet数大于fps，说明超过了1秒，此时开启
                            return true
                        }
                    }
                } else {
                    return capacity.isEndOfFile && capacity.packetCount == 0 //已经最后的场景，也要考虑
                }
            }
            //正常情况，已经最后的场景，也要考虑
            if capacity.isEndOfFile {
                return true
            }
            //超过最低缓存时长就认为能播，capacity.packetCount + capacity.frameCount == capacity.fps 说明load到的数据至少能播1s
            return capacity.packetCount + capacity.frameCount >= capacity.fps * Int(preferredForwardBufferDuration)
        }
        throttle = mach_absolute_time() //更新节流时间点，用于下一次的参考起点
        return LoadingState(loadedTime: loadedTime, progress: progress, packetCount: packetCount,
                            frameCount: frameCount, isEndOfFile: isEndOfFile, isPlayable: isPlayable,
                            isFirst: isFirst, isSeek: isSeek)
    }
    ///播放过程中，根据编解码能力，进行bit流的上升和下降选择算法
    open func adaptable(state: VideoAdaptationState) -> (Int64, Int64)? {
        //last上一次（第一次为打开时）选择的那条视频流的bitRate信息和当时那个时间点
        //适配必须要求，当前准备切换的时间点-上次切换的那个时间点 = 经过的时间长度 > 最长缓冲时长的一半
        guard let last = state.bitRateStates.last, CACurrentMediaTime() - last.time > maxBufferDuration / 2, let index = state.bitRates.firstIndex(of: last.bitRate) else {
            return nil
        }
        //
        let isUp = state.loadedCount > (state.fps * Int(maxBufferDuration)) / 2
        if isUp != state.isPlayable { //过滤音频情况，isUp不一定就和isPlayable相同，isUp的计算只是isPlayable计算中的一种情况
            return nil
        }
        //应该往上升高，就尝试升高
        if isUp {
            if index < state.bitRates.endIndex - 1 {
                return (last.bitRate, state.bitRates[index + 1])
            }
        //应该往下降低，就尝试降低
        } else {
            if index > state.bitRates.startIndex {
                return (last.bitRate, state.bitRates[index - 1])
            }
        }
        return nil
    }
    
    ///  wanted video stream index, or nil for automatic selection
    /// - Parameter : video bitRate
    /// - Returns: The index of the bitRates
    open func wantedVideo(bitRates _: [Int64]) -> Int? {
        nil
    }

    /// wanted audio stream index, or nil for automatic selection
    /// - Parameter :  audio bitRate and language
    /// - Returns: The index of the infos
    open func wantedAudio(infos _: [(bitRate: Int64, language: String?)]) -> Int? {
        nil
    }
    
}

enum HPSourceState {
    case idle
    case opening 
    case opened
    case reading
    case seeking
    case paused
    case finished
    case closed
    case failed
}

public enum HPLogLevel: Int32 {
    case panic = 0
    case fatal = 8
    case error = 16
    case warning = 24
    case info = 32
    case verbose = 40
    case debug = 48
    case trace = 56
}

///编解码状态描述
enum HPCodecState {
    case idle
    case decoding
    case flush
    case closed
    case failed
    case finished
}

///音视频中
struct HPTimebase {
    static let defaultValue = HPTimebase(num: 1, den: 1)
    public let num: Int32 //分子
    public let den: Int32 //分母
    
    //num/den 表示一桢是多少秒的刻度
    //该针时间点s/（num/den）得到这是第几桢
    //第timestamp针 *（num/den）得到该针的时间点s
    //时间秒->第几戳
    func getPosition(from seconds: Double) -> Int64 { Int64(seconds * Double(den) / Double(num)) }
    //第几戳->CMTime(高精度的时间表示方法)https://www.jianshu.com/p/d6f9d7e493b6
    func cmtime(for timestamp: Int64) -> CMTime { CMTime(value: timestamp * Int64(num), timescale: den) }
}
extension HPTimebase {
    public var rational: AVRational { AVRational(num: num, den: den) }
    init(_ rational: AVRational) {
        num = rational.num
        den = rational.den
    }
}

final class HPPacket: HPQueueItem {
    final class AVPacketWrap {
        fileprivate var corePacket = av_packet_alloc() //ref: +1
        deinit {
            av_packet_free(&corePacket) //跟随Wrap的生命周期释放
        }
    }

    public var duration: Int64 = 0
    public var size: Int64 = 0
    public var position: Int64 = 0
    var assetTrack: HPMediaTrack! //反向记录的Track信息
    var corePacket: UnsafeMutablePointer<AVPacket> { packetWrap.corePacket! }
    private let packetWrap = HPObjectCachePool.share.object(class: AVPacketWrap.self, key: "AVPacketWrap") { AVPacketWrap() }
    //填充packet的信息
    func fill() {
        position = corePacket.pointee.pts == Int64.min ? corePacket.pointee.dts : corePacket.pointee.pts
        duration = corePacket.pointee.duration
        size = Int64(corePacket.pointee.size)
    }

    deinit {
        av_packet_unref(corePacket) //ref: -1
        HPObjectCachePool.share.comeback(item: packetWrap, key: "AVPacketWrap") //MARK: ❓
    }
}

// MARK: Protocol
public protocol HPQueueItem {
    var duration: Int64 { get }
    var size: Int64 { get }
    ///帧的时间戳位置
    var position: Int64 { get }
}
/// 抽象桢描述
protocol HPFrame: HPQueueItem {
    var timebase: HPTimebase { get set }
}
extension HPFrame {
    ///秒单位描述
    public var seconds: TimeInterval { cmtime.seconds }
    ///时间戳单位描述
    public var cmtime: CMTime { timebase.cmtime(for: position) }
}
///桢基类
class HPFrameBase: HPFrame {
    public var timebase = HPTimebase.defaultValue
    public var duration: Int64 = 0
    public var size: Int64 = 0
    public var position: Int64 = 0
}

///TV桢
final class HPVideoFrameVTB: HPFrameBase {
    public var corePixelBuffer: HPBuffer?
}


import UIKit
public protocol HPBuffer: AnyObject {
    ///用于渲染显示时的分辨率大小
    var drawableSize: CGSize { get }
    ///像素格式
    var format: OSType { get }
    ///颜色通道数
    var planeCount: Int { get }
    ///像素宽高
    var width: Int { get }
    var height: Int { get }
    var isFullRangeVideo: Bool { get }
    var colorAttachments: NSString { get }
    func widthOfPlane(at planeIndex: Int) -> Int
    func heightOfPlane(at planeIndex: Int) -> Int
    func textures(frome cache: HPMetalTextureCache) -> [MTLTexture]
    func image() -> UIImage?
}

extension CVPixelBuffer: HPBuffer {
    public var width: Int { CVPixelBufferGetWidth(self) }

    public var height: Int { CVPixelBufferGetHeight(self) }

    public var size: CGSize { CGSize(width: width, height: height) }

    public var isPlanar: Bool { CVPixelBufferIsPlanar(self) }

    public var planeCount: Int { isPlanar ? CVPixelBufferGetPlaneCount(self) : 1 }

    public var format: OSType { CVPixelBufferGetPixelFormatType(self) }

    public var drawableSize: CGSize {
        // Check if the pixel buffer exists
        if let ratio = CVBufferGetAttachment(self, kCVImageBufferPixelAspectRatioKey, nil)?.takeUnretainedValue() as? NSDictionary,
            let horizontal = (ratio[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? NSNumber)?.intValue,
            let vertical = (ratio[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? NSNumber)?.intValue,
            horizontal > 0, vertical > 0, horizontal != vertical
        {
            return CGSize(width: width, height: height * vertical / horizontal)
        } else {
            return size
        }
    }

    public var isFullRangeVideo: Bool {
        CVBufferGetAttachment(self, kCMFormatDescriptionExtension_FullRangeVideo, nil)?.takeUnretainedValue() as? Bool ?? true
    }

    public var colorAttachments: NSString {
        CVBufferGetAttachment(self, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue() as? NSString ?? kCVImageBufferYCbCrMatrix_ITU_R_709_2
    }

    public func widthOfPlane(at planeIndex: Int) -> Int {
        CVPixelBufferGetWidthOfPlane(self, planeIndex)
    }

    public func heightOfPlane(at planeIndex: Int) -> Int {
        CVPixelBufferGetHeightOfPlane(self, planeIndex)
    }

    func baseAddressOfPlane(at planeIndex: Int) -> UnsafeMutableRawPointer? {
        CVPixelBufferGetBaseAddressOfPlane(self, planeIndex)
    }
    
    public func image() -> UIImage? {
        let ciImage = CIImage(cvImageBuffer: self)
        let context = CIContext(options: nil)
        if let videoImage = context.createCGImage(ciImage, from: CGRect(origin: .zero, size: size)) {
            return UIImage(cgImage: videoImage)
        } else {
            return nil
        }
    }
    public func textures(frome cache: HPMetalTextureCache) -> [MTLTexture] {
        cache.texture(pixelBuffer: self) //把CVPixelBuffer通过HPMetalTextureCache转换为MTLTexture
    }
}


// MARK: Log
public struct HPManager {
    /// 日志输出方式
    public static var logFunctionPoint: (String) -> Void = {
        print($0)
    }
}
extension HPManager {
    /// 是否能后台播放视频
    public static var canBackgroundPlay = false
}


func HPLog(_ message: CustomStringConvertible, file: String = #file, function: String = #function, line: Int = #line) {
    let fileName = (file as NSString).lastPathComponent
    HPManager.logFunctionPoint("HPlayer: \(fileName):\(line) \(function) | \(message)")
}

extension HPManager {
    /// 日志级别
    public static var logLevel = HPLogLevel.warning
    public static var stackSize = 32768
    public static var audioPlayerMaximumFramesPerSlice = AVAudioFrameCount(4096)
    public static var preferredFramesPerSecond = 60

    public static var audioPlayerSampleRate = Int32(AVAudioSession.sharedInstance().sampleRate)
    public static var audioPlayerMaximumChannels = AVAudioChannelCount(AVAudioSession.sharedInstance().outputNumberOfChannels)

    static func outputFormat() -> AudioStreamBasicDescription {
        var audioStreamBasicDescription = AudioStreamBasicDescription()
        let floatByteSize = UInt32(MemoryLayout<Float>.size)
        audioStreamBasicDescription.mBitsPerChannel = 8 * floatByteSize
        audioStreamBasicDescription.mBytesPerFrame = floatByteSize
        audioStreamBasicDescription.mChannelsPerFrame = audioPlayerMaximumChannels
        audioStreamBasicDescription.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved
        audioStreamBasicDescription.mFormatID = kAudioFormatLinearPCM
        audioStreamBasicDescription.mFramesPerPacket = 1
        audioStreamBasicDescription.mBytesPerPacket = audioStreamBasicDescription.mFramesPerPacket * audioStreamBasicDescription.mBytesPerFrame
        audioStreamBasicDescription.mSampleRate = Float64(audioPlayerSampleRate)
        return audioStreamBasicDescription
    }

    static let audioDefaultFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(audioPlayerSampleRate), channels: audioPlayerMaximumChannels, interleaved: false)!
}

//MARK: - Error
public let HPErrorDomain = "HPErrorDomain"

public enum HPErrorCode: Int {
    case unknown
    case formatCreate
    case formatOpenInput
    case formatFindStreamInfo
    case readFrame
    case codecContextCreate
    case codecContextSetParam
    case codecContextFindDecoder
    case codesContextOpen
    case codecVideoSendPacket
    case codecAudioSendPacket
    case codecVideoReceiveFrame
    case codecAudioReceiveFrame
    case auidoSwrInit
    case codecSubtitleSendPacket
    case videoTracksUnplayable
    case subtitleUnEncoding
    case subtitleUnParse
    case subtitleFormatUnSupport
}

extension HPErrorCode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .formatCreate:
            return "avformat_alloc_context return nil"
        case .formatOpenInput:
            return "avformat can't open input"
        case .formatFindStreamInfo:
            return "avformat_find_stream_info return nil"
        case .codecContextCreate:
            return "avcodec_alloc_context3 return nil"
        case .codecContextSetParam:
            return "avcodec can't set parameters to context"
        case .codesContextOpen:
            return "codesContext can't Open"
        case .codecVideoReceiveFrame:
            return "avcodec can't receive video frame"
        case .codecAudioReceiveFrame:
            return "avcodec can't receive audio frame"
        case .videoTracksUnplayable:
            return "VideoTracks are not even playable."
        case .codecSubtitleSendPacket:
            return "avcodec can't decode subtitle"
        case .subtitleUnEncoding:
            return "Subtitle encoding format is not supported."
        case .subtitleUnParse:
            return "Subtitle parsing error"
        case .subtitleFormatUnSupport:
            return "Current subtitle format is not supported"
        default:
            return "unknown"
        }
    }
}

extension NSError {
    convenience init(errorCode: HPErrorCode, userInfo: [String: Any] = [:]) {
        var userInfo = userInfo
        userInfo[NSLocalizedDescriptionKey] = errorCode.description
        self.init(domain: HPErrorDomain, code: errorCode.rawValue, userInfo: userInfo)
    }
}

// MARK: Extension
extension Dictionary where Key == String {

    //这里的处理可能是av_dict_set_int的存储只支持Int64、Int、String？
    var avOptions: OpaquePointer? {
        var avOptions: OpaquePointer? //不透明box，使用avOptions后取消
        forEach { key, value in
            if let i = value as? Int64 {
                av_dict_set_int(&avOptions, key, i, 0)
            } else if let i = value as? Int {
                av_dict_set_int(&avOptions, key, Int64(i), 0)
            } else if let string = value as? String {
                av_dict_set(&avOptions, key, string, 0)
            }
        }
        return avOptions
    }
}

extension NSError {
    convenience init(errorCode: HPErrorCode, ffmpegErrnum: Int32) {
        var errorStringBuffer = [Int8](repeating: 0, count: 512)
        av_strerror(ffmpegErrnum, &errorStringBuffer, 512)
        let underlyingError = NSError(domain: "FFmpegDomain", code: Int(ffmpegErrnum), userInfo: [NSLocalizedDescriptionKey: String(cString: errorStringBuffer)])
        self.init(errorCode: errorCode, userInfo: [NSUnderlyingErrorKey: underlyingError])
    }
}

extension UnsafeMutablePointer where Pointee == AVStream {
    var rotation: Double {
        let displaymatrix = av_stream_get_side_data(self, AV_PKT_DATA_DISPLAYMATRIX, nil)
        let rotateTag = av_dict_get(pointee.metadata, "rotate", nil, 0)
        if let rotateTag = rotateTag, String(cString: rotateTag.pointee.value) == "0" {
            return 0.0
        } else if let displaymatrix = displaymatrix {
            let matrix = displaymatrix.withMemoryRebound(to: Int32.self, capacity: 1) { $0 }
            return -av_display_rotation_get(matrix)
        }
        return 0.0
    }
}

extension Int32: Error {}
