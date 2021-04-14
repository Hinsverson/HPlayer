//
//  Resample.swift
//  HPlayer
//
//  Created by hinson on 2020/12/13.
//  Copyright © 2020 tommy. All rights reserved.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import VideoToolbox
//#if canImport(UIKit)
import UIKit
//#else
//import AppKit
//#endif

protocol HPSwresample {
    func transfer(avframe: UnsafeMutablePointer<AVFrame>, timebase: HPTimebase) -> HPFrameBase
    func shutdown()
}

class HPVideoSwresample: HPSwresample {
    ///目标像素格式（FFMpeg格式类型）
    private let dstFormat: AVPixelFormat
    ///FFMpeg重采样器
    private var imgConvertCtx: OpaquePointer?
    ///源像素格式（FFMpeg格式类型）
    private var format: AVPixelFormat = AV_PIX_FMT_NONE
    
    ///scr高
    private var height: Int32 = 0
    ///scr宽
    private var width: Int32 = 0
    private var forceTransfer: Bool
    
    ///装重采样后数据的HPFrameBase
    var dstFrame: UnsafeMutablePointer<AVFrame>?
    
    init(dstFormat: AVPixelFormat, forceTransfer: Bool = false) {
        self.dstFormat = dstFormat
        self.forceTransfer = forceTransfer
    }

    private func setup(frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        setup(format: frame.pointee.format, width: frame.pointee.width, height: frame.pointee.height)
    }

    func setup(format: Int32, width: Int32, height: Int32) -> Bool {
        //如果格式、宽高相同，说明不需要重新配置，直接用就好
        if self.format.rawValue == format, self.width == width, self.height == height {
            return true
        }
        //清理
        shutdown()
        self.format = AVPixelFormat(rawValue: format)
        self.height = height
        self.width = width
        
        //如果没有指定需要强转，并且是HPixelBuffer本来支持的格式（Metal支持的能直接解析的像素格式）
        //意味着后续可以直接通过AVFrame构造出可被渲染的像素针，而不需要额外重新采样。
        if !forceTransfer, HPixelBuffer.isSupported(format: self.format) {
            return true
        }
        
        //初始化重采样
        imgConvertCtx = sws_getCachedContext(imgConvertCtx, width, height, self.format, width, height, dstFormat, SWS_BICUBIC, nil, nil, nil)
        guard imgConvertCtx != nil else {
            return false
        }
        
        //申请一个输出frame，并初始化
        dstFrame = av_frame_alloc()
        guard let dstFrame = dstFrame else {
            sws_freeContext(imgConvertCtx)
            imgConvertCtx = nil
            return false
        }
        dstFrame.pointee.width = width
        dstFrame.pointee.height = height
        dstFrame.pointee.format = dstFormat.rawValue
        av_image_alloc(&dstFrame.pointee.data.0, &dstFrame.pointee.linesize.0, width, height, AVPixelFormat(rawValue: dstFrame.pointee.format), 64)//填充初始化信息
        return true
    }

    func transfer(avframe: UnsafeMutablePointer<AVFrame>, timebase: HPTimebase) -> HPFrameBase {
        let frame = HPVideoFrameVTB()
        frame.timebase = timebase
        //如果来自VT硬解，则直接取数据强转为
        if avframe.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            // swiftlint:disable force_cast
            frame.corePixelBuffer = avframe.pointee.data.3 as! CVPixelBuffer
            // swiftlint:enable force_cast
        } else {
            //如果重采样配置成功，并且重采样成功
            if setup(frame: avframe), let dstFrame = dstFrame, swsConvert(data: Array(tuple: avframe.pointee.data), linesize: Array(tuple: avframe.pointee.linesize)) {
                //用重采样后的frame填充原来的frame，只修改像素格式 和 数据信息，其他不变
                avframe.pointee.format = dstFrame.pointee.format
                avframe.pointee.data = dstFrame.pointee.data
                avframe.pointee.linesize = dstFrame.pointee.linesize
            }
            //不需要重新采样或者是采样已经完成，像素格式符合要求，则把桢（HPFrameBase）转换为HPixelBuffer描述，方便渲染处理
            frame.corePixelBuffer = HPixelBuffer(frame: avframe)
        }
        frame.duration = avframe.pointee.pkt_duration //桢时长
        frame.size = Int64(avframe.pointee.pkt_size) //桢大小
        
        ///HPLog("HPVideoFrameVTB Des: position(\(frame.position)) duration(\(frame.duration)) size(\(frame.size)) timebase(\(frame.timebase))")
        ///HPLog("HPVideoFrameVTB HPixelBuffer: \(frame.corePixelBuffer)")
        return frame
    }

    func transfer(format: AVPixelFormat, width: Int32, height: Int32, data: [UnsafeMutablePointer<UInt8>?], linesize: [Int32]) -> UIImage? {
        if setup(format: format.rawValue, width: width, height: height), swsConvert(data: data, linesize: linesize), let frame = dstFrame?.pointee {
            return UIImage(rgbData: frame.data.0!, linesize: Int(frame.linesize.0), width: Int(width), height: Int(height), isAlpha: dstFormat == AV_PIX_FMT_RGBA)
        }
        return nil
    }

    private func swsConvert(data: [UnsafeMutablePointer<UInt8>?], linesize: [Int32]) -> Bool {
        guard let dstFrame = dstFrame else {
            return false
        }
        let result = sws_scale(imgConvertCtx, data.map { UnsafePointer($0) }, linesize, 0, height, &dstFrame.pointee.data.0, &dstFrame.pointee.linesize.0)
        return result > 0
    }

    func shutdown() {
        av_frame_free(&dstFrame)
        sws_freeContext(imgConvertCtx)
        imgConvertCtx = nil
    }

    static func == (lhs: HPVideoSwresample, rhs: AVFrame) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.format.rawValue == rhs.format
    }
}

///渲染的像素桢描述
class HPixelBuffer: HPBuffer {
    let format: OSType
    let width: Int
    let height: Int
    let planeCount: Int
    let isFullRangeVideo: Bool
    let colorAttachments: NSString
    let drawableSize: CGSize
    
    ///每个通道对应的渲染格式
    private let formats: [MTLPixelFormat]
    ///每个通道对应的width
    private let widths: [Int]
    ///每个通道对应的height
    private let heights: [Int]
    ///像素数据
    private let dataWrap: HPFrameDataWrap
    ///数据行宽
    private let bytesPerRow: [Int32]
    
    init(frame: UnsafeMutablePointer<AVFrame>) {
        //FFMpeg的像素格式类型描述转化为MTLPixelFormat（Metal中的像素格式类型）
        format = AVPixelFormat(rawValue: frame.pointee.format).format
        
        // MARK: ❓特殊格式AVCOL_SPC_BT709 需要特殊处理
        if frame.pointee.colorspace == AVCOL_SPC_BT709 {
            colorAttachments = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        } else {
            //        else if frame.colorspace == AVCOL_SPC_SMPTE170M || frame.colorspace == AVCOL_SPC_BT470BG {
            colorAttachments = kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
        }
        width = Int(frame.pointee.width)
        height = Int(frame.pointee.height)
        isFullRangeVideo = format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        bytesPerRow = Array(tuple: frame.pointee.linesize)
        
        //https://blog.csdn.net/qq_23282479/article/details/105692470
        //DAR,Display_aspect_ratio,是指定该视频播放的时候，看到的视频比例。
        //SAR,Sample Aspect Ratio,是指采集这个视频的比例，也就是存储像素点的比例。
        let vertical = Int(frame.pointee.sample_aspect_ratio.den)//样例视频：1
        let horizontal = Int(frame.pointee.sample_aspect_ratio.num)//样例视频：0
        //大于0才有意义，宽高不等则以宽为标准，重新计算高
        if vertical > 0, horizontal > 0, vertical != horizontal {
            //MARK: ❓这里的计算是不是理解反了？
            drawableSize = CGSize(width: width, height: height * vertical / horizontal)
        } else {
            drawableSize = CGSize(width: width, height: height) //样例视频：(840.0, 360.0)
        }
        //根据不同的像素存储格式，初始化相关描述信息
        switch format {
        case kCVPixelFormatType_420YpCbCr8Planar: //样例视频：走这里
            planeCount = 3 //颜色通道数
            formats = [.r8Unorm, .r8Unorm, .r8Unorm] //各个颜色通道的渲染格式
            widths = [width, width / 2, width / 2] //各个颜色通道的width
            heights = [height, height / 2, height / 2] //各个颜色通道的height
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            planeCount = 2
            formats = [.r8Unorm, .rg8Unorm]
            widths = [width, width / 2]
            heights = [height, height / 2]
        default:
            planeCount = 1
            formats = [.bgra8Unorm]
            widths = [width]
            heights = [height]
        }
        
        dataWrap = HPObjectCachePool.share.object(class: HPFrameDataWrap.self, key: "VideoData") { HPFrameDataWrap() }
        let bytes = Array(tuple: frame.pointee.data)
        //填充HPFrameDataWrap的size描述和data数据
        //bytesPerRow来自于frame.pointee.linesize，这个linesize有8个成员，当kCVPixelFormatType_420YpCbCr8Planar类型，通道个数为3时只有前3个有效
        /*样例视频：
         bytesPerRow
         8 elements
           - 0 : 848
           - 1 : 424
           - 2 : 424
           - 3 : 0
           - 4 : 0
           - 5 : 0
           - 6 : 0
           - 7 : 0
         */
        //每个通道大小 = 每个通道每一行的字节数*每个通道对应的height，总大小=所有通道大小和
        dataWrap.size = (0 ..< planeCount).map { Int(bytesPerRow[$0]) * heights[$0] }
        (0 ..< planeCount).forEach { i in //把每个通道存储的数据，拷贝出来放入dataWrap.data[i]进行存储
            dataWrap.data[i]?.assign(from: bytes[i]!, count: dataWrap.size[i]) //拷贝替换
        }
    }

    deinit {
        HPObjectCachePool.share.comeback(item: dataWrap, key: "VideoData")
    }

    func widthOfPlane(at planeIndex: Int) -> Int {
        widths[planeIndex]
    }

    func heightOfPlane(at planeIndex: Int) -> Int {
        heights[planeIndex]
    }

    ///Apple环境下支持的像素显示格式
    public static func isSupported(format: AVPixelFormat) -> Bool {
        [AV_PIX_FMT_NV12, AV_PIX_FMT_YUV420P, AV_PIX_FMT_BGRA].contains(format)
    }

    func image() -> UIImage? {
        var image: UIImage?
        if format.format == AV_PIX_FMT_RGB24 {
            image = UIImage(rgbData: dataWrap.data[0]!, linesize: Int(bytesPerRow[0]), width: width, height: height)
        }
        let scale = HPVideoSwresample(dstFormat: AV_PIX_FMT_RGB24, forceTransfer: true)
        image = scale.transfer(format: format.format, width: Int32(width), height: Int32(height), data: dataWrap.data, linesize: bytesPerRow)
        scale.shutdown()
        return image
    }
    func textures(frome cache: HPMetalTextureCache) -> [MTLTexture] {
        cache.textures(formats: formats, widths: widths, heights: heights, bytes: dataWrap.data, bytesPerRows: bytesPerRow)
    }
}

extension AVCodecParameters {
    //https://blog.csdn.net/qq_23282479/article/details/105692470
    //DAR,Display_aspect_ratio,是指定该视频播放的时候，看到的视频比例。
    //SAR,Sample Aspect Ratio,是指采集这个视频的比例，也就是存储像素点的比例。
    var aspectRatio: NSDictionary? {
        let den = sample_aspect_ratio.den //分母：高
        let num = sample_aspect_ratio.num //分子：宽
        if den > 0, num > 0, den != num {
            return [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: num,
                    kCVImageBufferPixelAspectRatioVerticalSpacingKey: den] as NSDictionary
        } else {
            return nil
        }
    }
}

extension AVPixelFormat {
    var format: OSType {
        switch self {
        case AV_PIX_FMT_MONOBLACK: return kCVPixelFormatType_1Monochrome
        case AV_PIX_FMT_RGB555BE: return kCVPixelFormatType_16BE555
        case AV_PIX_FMT_RGB555LE: return kCVPixelFormatType_16LE555
        case AV_PIX_FMT_RGB565BE: return kCVPixelFormatType_16BE565
        case AV_PIX_FMT_RGB565LE: return kCVPixelFormatType_16LE565
        case AV_PIX_FMT_RGB24: return kCVPixelFormatType_24RGB
        case AV_PIX_FMT_BGR24: return kCVPixelFormatType_24BGR
        case AV_PIX_FMT_0RGB: return kCVPixelFormatType_32ARGB
        case AV_PIX_FMT_BGR0: return kCVPixelFormatType_32BGRA
        case AV_PIX_FMT_0BGR: return kCVPixelFormatType_32ABGR
        case AV_PIX_FMT_RGB0: return kCVPixelFormatType_32RGBA
        case AV_PIX_FMT_BGRA: return kCVPixelFormatType_32BGRA
        case AV_PIX_FMT_BGR48BE: return kCVPixelFormatType_48RGB
        case AV_PIX_FMT_UYVY422: return kCVPixelFormatType_422YpCbCr8
        case AV_PIX_FMT_YUVA444P: return kCVPixelFormatType_4444YpCbCrA8R
        case AV_PIX_FMT_YUVA444P16LE: return kCVPixelFormatType_4444AYpCbCr16
        case AV_PIX_FMT_YUV444P: return kCVPixelFormatType_444YpCbCr8
        //        case AV_PIX_FMT_YUV422P16: return kCVPixelFormatType_422YpCbCr16
        //        case AV_PIX_FMT_YUV422P10: return kCVPixelFormatType_422YpCbCr10
        //        case AV_PIX_FMT_YUV444P10: return kCVPixelFormatType_444YpCbCr10
        case AV_PIX_FMT_YUV420P: return kCVPixelFormatType_420YpCbCr8Planar
        case AV_PIX_FMT_YUV420P10LE: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case AV_PIX_FMT_NV12: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case AV_PIX_FMT_YUYV422: return kCVPixelFormatType_422YpCbCr8_yuvs
        case AV_PIX_FMT_GRAY8: return kCVPixelFormatType_OneComponent8
        default:
            return 0
        }
    }
}

extension OSType {
    var format: AVPixelFormat {
        switch self {
        case kCVPixelFormatType_32ARGB: return AV_PIX_FMT_ARGB
        case kCVPixelFormatType_32BGRA: return AV_PIX_FMT_BGRA
        case kCVPixelFormatType_24RGB: return AV_PIX_FMT_RGB24
        case kCVPixelFormatType_16BE555: return AV_PIX_FMT_RGB555BE
        case kCVPixelFormatType_16BE565: return AV_PIX_FMT_RGB565BE
        case kCVPixelFormatType_16LE555: return AV_PIX_FMT_RGB555LE
        case kCVPixelFormatType_16LE565: return AV_PIX_FMT_RGB565LE
        case kCVPixelFormatType_422YpCbCr8: return AV_PIX_FMT_UYVY422
        case kCVPixelFormatType_422YpCbCr8_yuvs: return AV_PIX_FMT_YUYV422
        case kCVPixelFormatType_444YpCbCr8: return AV_PIX_FMT_YUV444P
        case kCVPixelFormatType_4444YpCbCrA8: return AV_PIX_FMT_YUV444P16LE
        case kCVPixelFormatType_422YpCbCr16: return AV_PIX_FMT_YUV422P16LE
        case kCVPixelFormatType_422YpCbCr10: return AV_PIX_FMT_YUV422P10LE
        case kCVPixelFormatType_444YpCbCr10: return AV_PIX_FMT_YUV444P10LE
        case kCVPixelFormatType_420YpCbCr8Planar: return AV_PIX_FMT_YUV420P
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return AV_PIX_FMT_NV12
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return AV_PIX_FMT_NV12
        case kCVPixelFormatType_422YpCbCr8_yuvs: return AV_PIX_FMT_YUYV422
        default:
            return AV_PIX_FMT_NONE
        }
    }
}

extension CVPixelBufferPool {
    func getPixelBuffer(fromFrame frame: AVFrame) -> CVPixelBuffer? {
        var pbuf: CVPixelBuffer?
        let ret = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, self, &pbuf)
        //        let dic = [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        //                       kCVPixelBufferBytesPerRowAlignmentKey: frame.linesize.0] as NSDictionary
        //        let ret = CVPixelBufferCreate(kCFAllocatorDefault, Int(frame.width), Int(frame.height), AVPixelFormat(rawValue: frame.format).format, dic, &pbuf)
        if let pbuf = pbuf, ret == kCVReturnSuccess {
            CVPixelBufferLockBaseAddress(pbuf, CVPixelBufferLockFlags(rawValue: 0))
            let data = Array(tuple: frame.data)
            let linesize = Array(tuple: frame.linesize)
            let heights = [frame.height, frame.height / 2, frame.height / 2]
            for i in 0 ..< pbuf.planeCount {
                let perRow = Int(linesize[i])
                pbuf.baseAddressOfPlane(at: i)?.copyMemory(from: data[i]!, byteCount: Int(heights[i]) * perRow)
            }
            CVPixelBufferUnlockBaseAddress(pbuf, CVPixelBufferLockFlags(rawValue: 0))
        }
        return pbuf
    }
}

extension UIImage {
    convenience init?(rgbData: UnsafePointer<UInt8>, linesize: Int, width: Int, height: Int, isAlpha: Bool = false) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = isAlpha ? CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue) : []
        guard let data = CFDataCreate(kCFAllocatorDefault, rgbData, linesize * height),
            let provider = CGDataProvider(data: data),
            // swiftlint:disable line_length
            let imageRef = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: isAlpha ? 32 : 24, bytesPerRow: linesize, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            // swiftlint:enable line_length
            return nil
        }
        self.init(cgImage: imageRef)
    }
}

typealias SwrContext = OpaquePointer

class HPAudioSwresample: HPSwresample {
    private var swrContext: SwrContext?
    private var descriptor: AudioDescriptor?
    private func setup(frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        //已经配置好了的话，则不需要重新配置
        let newDescriptor = AudioDescriptor(frame: frame)
        if let descriptor = descriptor, descriptor == newDescriptor {
            return true
        }
        //从配置项拿出声道信息
        let outChannel = av_get_default_channel_layout(Int32(HPManager.audioPlayerMaximumChannels))
        //从HPFrameBase中拿入声道信息
        let inChannel = av_get_default_channel_layout(Int32(newDescriptor.inputNumberOfChannels))
        
        swrContext = swr_alloc_set_opts(nil, outChannel, AV_SAMPLE_FMT_FLTP, HPManager.audioPlayerSampleRate, inChannel, newDescriptor.inputFormat, newDescriptor.inputSampleRate, 0, nil)
        let result = swr_init(swrContext)
        if result < 0 {
            shutdown()
            return false
        } else {
            descriptor = newDescriptor //成功后保存des
            return true
        }
    }

    func transfer(avframe: UnsafeMutablePointer<AVFrame>, timebase: HPTimebase) -> HPFrameBase {
        _ = setup(frame: avframe)
        var numberOfSamples = avframe.pointee.nb_samples
        let nbSamples = swr_get_out_samples(swrContext, numberOfSamples)
        
        var frameBuffer = Array(tuple: avframe.pointee.data).map { UnsafePointer<UInt8>($0) }
        var bufferSize = Int32(0)
        _ = av_samples_get_buffer_size(&bufferSize, Int32(HPManager.audioPlayerMaximumChannels), nbSamples, AV_SAMPLE_FMT_FLTP, 1)
        
        //转换
        let frame = HPAudioFrame(bufferSize: bufferSize)
        numberOfSamples = swr_convert(swrContext, &frame.dataWrap.data, nbSamples, &frameBuffer, numberOfSamples)
        frame.timebase = timebase
        frame.numberOfSamples = Int(numberOfSamples)
        frame.duration = avframe.pointee.pkt_duration
        frame.size = Int64(avframe.pointee.pkt_size)
        if frame.duration == 0 {
            frame.duration = Int64(avframe.pointee.nb_samples) * Int64(frame.timebase.den) / (Int64(avframe.pointee.sample_rate) * Int64(frame.timebase.num))
        }
        
        ///HPLog("HPAudioFrame Des: position(\(frame.position)) duration(\(frame.duration)) size(\(frame.size)) timebase(\(frame.timebase))")
        
        return frame
    }

    func shutdown() {
        swr_free(&swrContext)
    }
}

final class HPAudioFrame: HPFrameBase {
    public var numberOfSamples = 0
    let dataWrap: HPFrameDataWrap
    public init(bufferSize: Int32) {
        dataWrap = HPObjectCachePool.share.object(class: HPFrameDataWrap.self, key: "AudioData") { HPFrameDataWrap() }
        if dataWrap.size[0] < bufferSize {
            dataWrap.size = Array(repeating: Int(bufferSize), count: Int(HPManager.audioPlayerMaximumChannels))
        }
    }
    deinit {
        HPObjectCachePool.share.comeback(item: dataWrap, key: "AudioData")
    }
}

///通过格式、声道数、采样率 来描述Audio
fileprivate class AudioDescriptor: Equatable {
    fileprivate let inputNumberOfChannels: AVAudioChannelCount
    fileprivate let inputSampleRate: Int32
    fileprivate let inputFormat: AVSampleFormat
    init(codecpar: UnsafeMutablePointer<AVCodecParameters>) {
        let channels = UInt32(codecpar.pointee.channels)
        inputNumberOfChannels = channels == 0 ? HPManager.audioPlayerMaximumChannels : channels
        let sampleRate = codecpar.pointee.sample_rate
        inputSampleRate = sampleRate == 0 ? HPManager.audioPlayerSampleRate : sampleRate
        inputFormat = AVSampleFormat(rawValue: codecpar.pointee.format)
    }

    init(frame: UnsafeMutablePointer<AVFrame>) {
        let channels = UInt32(frame.pointee.channels)
        inputNumberOfChannels = channels == 0 ? HPManager.audioPlayerMaximumChannels : channels
        let sampleRate = frame.pointee.sample_rate
        inputSampleRate = sampleRate == 0 ? HPManager.audioPlayerSampleRate : sampleRate
        inputFormat = AVSampleFormat(rawValue: frame.pointee.format)
    }

    static func == (lhs: AudioDescriptor, rhs: AudioDescriptor) -> Bool {
        lhs.inputFormat == rhs.inputFormat && lhs.inputSampleRate == rhs.inputSampleRate && lhs.inputNumberOfChannels == rhs.inputNumberOfChannels
    }

    static func == (lhs: AudioDescriptor, rhs: AVFrame) -> Bool {
        lhs.inputFormat.rawValue == rhs.format && lhs.inputSampleRate == rhs.sample_rate && lhs.inputNumberOfChannels == rhs.channels
    }
}

final class HPFrameDataWrap {
    var data: [UnsafeMutablePointer<UInt8>?]
    var size: [Int] = [0] {
        didSet {
            if size.description != oldValue.description {
                (0 ..< data.count).forEach { i in
                    if oldValue[i] > 0 {
                        data[i]?.deinitialize(count: oldValue[i])
                        data[i]?.deallocate()
                    }
                }
                data.removeAll()
                (0 ..< size.count).forEach { i in
                    data.append(UnsafeMutablePointer<UInt8>.allocate(capacity: Int(size[i])))
                }
            }
        }
    }

    public init() {
        data = Array(repeating: nil, count: 1)
    }

    deinit {
        (0 ..< data.count).forEach { i in
            data[i]?.deinitialize(count: size[i])
            data[i]?.deallocate()
        }
        data.removeAll()
    }
}
