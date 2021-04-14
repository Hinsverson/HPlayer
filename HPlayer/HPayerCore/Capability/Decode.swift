//
//  HPSoftwareDecode.swift
//  HPlayer
//
//  Created by hinson on 2020/12/7.
//  Copyright © 2020 tommy. All rights reserved.
//

import AVFoundation
import Foundation
import VideoToolbox

///加码环节的抽象描述
protocol HPDecode {
    init(assetTrack: HPMediaTrack, options: HPConfig)
    ///解码器开始解码前的准备动作
    func decode()
    func doDecode(packet: UnsafeMutablePointer<AVPacket>) throws -> [HPFrameBase]
    func seek(time: TimeInterval)
    func doFlushCodec()
    func shutdown()
}

///FFMpeg音频和视频软解封装类
class HPSoftwareDecode: HPDecode {
    private let mediaType: AVFoundation.AVMediaType
    private let timebase: HPTimebase
    private let options: HPConfig
    
    // 第一次seek不要调用avcodec_flush_buffers。否则seek完之后可能会因为不是关键帧而导致蓝屏
    private var firstSeek = true
    private var coreFrame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    ///标记当前解码到的针的时间戳
    private var bestEffortTimestamp = Int64(0)
    ///重采样器
    private let swresample: HPSwresample
    required init(assetTrack: HPMediaTrack, options: HPConfig) {
        timebase = assetTrack.timebase
        mediaType = assetTrack.mediaType
        self.options = options
        do {
            //创建编码器上下文
            codecContext = try assetTrack.stream.pointee.codecpar.ceateContext(options: options)
        } catch {
            HPLog(error as CustomStringConvertible)
        }
        //设置codecContext上下文的timebase为Track上的timebase
        codecContext?.pointee.time_base = timebase.rational //自定义的TimeBase转化为FF中的类型
        
        ///*重新采样编码（容错处理）
        if mediaType == .video {
            //根据 指定的视频颜色编码格式 进行重采样
            swresample = HPVideoSwresample(dstFormat: options.bufferPixelFormatType.format)
        } else {
            swresample = HPAudioSwresample()
        }
        //*/
    }

    func doDecode(packet: UnsafeMutablePointer<AVPacket>) throws -> [HPFrameBase] {
        guard let codecContext = codecContext else {
            return []
        }
        let result = avcodec_send_packet(codecContext, packet)
        guard result == 0 else {
            return []
        }
        var array = [HPFrameBase]()
        //一个packet可能包含多个针
        while true {
            do {
                let result = avcodec_receive_frame(codecContext, coreFrame)
                if result == 0, let avframe = coreFrame {
                    //⚠️这里原来的处理里用了dts再取最大，所以最后的timestamp会不准，出现首帧预览时，时间对比不通过的问题，按照FFmpeg的文档直接用best_effort_timestamp就好。
                    //best_effort_timestamp：用多种方式估算出的帧的时间戳，以stream中的time base为单位
                    let timestamp = max(avframe.pointee.best_effort_timestamp, avframe.pointee.pts/*, avframe.pointee.pkt_dts*/)
                    if timestamp >= bestEffortTimestamp {
                        bestEffortTimestamp = timestamp //校准到解码出来的该桢的开始
                    }
                    
                    let frame = swresample.transfer(avframe: avframe, timebase: timebase)
                    frame.position = bestEffortTimestamp
                    bestEffortTimestamp += frame.duration //更新bestEffortTimestamp
                    array.append(frame)
                    //let frame = HPVideoFrameVTB()
                    //array.append(frame)
                    //收到一桢后继续 while，直到桢解码完成
                    ///HPLog("AVFrame Info -\(self.mediaType.rawValue): pts(\(avframe.pointee.pts)) data\(avframe.pointee.data) isKeyFrame(\(avframe.pointee.key_frame)")
                } else {
                    throw result
                }
            } catch let code as Int32 {
                
                if IS_AVERROR_EAGAIN(code) {
                    break
                } else if IS_AVERROR_EOF(code) {
                    avcodec_flush_buffers(codecContext)
                    break //桢解码完成 跳出
                } else {
                    let error = NSError(errorCode: mediaType == .audio ? .codecAudioReceiveFrame : .codecVideoReceiveFrame, ffmpegErrnum: code)
                    HPLog(error)
                    throw error
                }
                /*
                if code == 0 || AVFILTER_EOF(code) {
                    if IS_AVERROR_EOF(code) {
                        avcodec_flush_buffers(codecContext)
                    }
                    break //桢解码完成 跳出
                } else {
                    let error = NSError(errorCode: mediaType == .audio ? .codecAudioReceiveFrame : .codecVideoReceiveFrame, ffmpegErrnum: code)
                    HPLog(error)
                    throw error
                }*/
            } catch {}
        }
        return array
    }

    func doFlushCodec() {
        if firstSeek {
            firstSeek = false
        } else {
            if codecContext != nil {
                avcodec_flush_buffers(codecContext)
            }
        }
    }

    func shutdown() {
        av_frame_free(&coreFrame)
        avcodec_free_context(&codecContext)
    }

    func seek(time _: TimeInterval) {
        bestEffortTimestamp = Int64(0)
    }

    func decode() {
        bestEffortTimestamp = Int64(0)
        if codecContext != nil {
            //每次重新解码时都需要调用
            avcodec_flush_buffers(codecContext) // Should be called e.g. when seeking or when switching to a different stream.
        }
    }

    deinit {
        ///swresample.shutdown()
    }
}

///TV硬解
class HPHardwareDecode: HPDecode {
    private var session: DecodeSession?
    private let codecpar: AVCodecParameters
    private let timebase: HPTimebase
    private let options: HPConfig
    private var startTime = Int64(0)
    private var lastPosition = Int64(0)
    required init(assetTrack: HPMediaTrack, options: HPConfig) {
        timebase = assetTrack.timebase
        codecpar = assetTrack.stream.pointee.codecpar.pointee
        self.options = options
        session = DecodeSession(codecpar: codecpar, options: options)
    }

    init(assetTrack: HPMediaTrack, options: HPConfig, session: DecodeSession) {
        timebase = assetTrack.timebase
        codecpar = assetTrack.stream.pointee.codecpar.pointee
        self.options = options
        self.session = session
    }

    func doDecode(packet: UnsafeMutablePointer<AVPacket>) throws -> [HPFrameBase] {
        guard let data = packet.pointee.data, let session = session else {
            return []
        }
        
        /*调试
        let bety1 = data.advanced(by: 0).pointee
        let bety2 = data.advanced(by: 1).pointee
        let bety3 = data.advanced(by: 2).pointee
        let bety4 = data.advanced(by: 3).pointee
        let bety5 = data.advanced(by: 4).pointee
         */
        
        let sampleBuffer = try session.formatDescription.getSampleBuffer(isConvertNALSize: session.isConvertNALSize, data: data, size: Int(packet.pointee.size))
        var result = [HPVideoFrameVTB]()
        let flags = options.asynchronousDecompression ? VTDecodeFrameFlags._EnableAsynchronousDecompression : VTDecodeFrameFlags(rawValue: 0)
        var vtStatus = noErr
        //送入VT解码
        let status = VTDecompressionSessionDecodeFrame(session.decompressionSession, sampleBuffer: sampleBuffer, flags: flags, infoFlagsOut: nil) { [weak self] status, _, imageBuffer, _, _ in
            vtStatus = status
            guard let self = self, status == noErr, let imageBuffer = imageBuffer else {
                return
            }
            let frame = HPVideoFrameVTB()
            frame.corePixelBuffer = imageBuffer
            frame.timebase = self.timebase
            let timestamp = packet.pointee.pts
            if packet.pointee.flags & AV_PKT_FLAG_KEY == 1, packet.pointee.flags & AV_PKT_FLAG_DISCARD != 0, self.lastPosition > 0 {
                self.startTime = self.lastPosition - timestamp
            }
            self.lastPosition = max(self.lastPosition, timestamp)
            frame.position = self.startTime + timestamp
            frame.duration = packet.pointee.duration
            frame.size = Int64(packet.pointee.size)
            self.lastPosition += frame.duration
            result.append(frame)
        }
        if vtStatus != noErr {
//            status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr || status == kVTVideoDecoderBadDataErr
            if packet.pointee.flags & AV_PKT_FLAG_KEY == 1 { //有视频关键帧
                throw NSError(errorCode: .codecVideoReceiveFrame, ffmpegErrnum: vtStatus)
            } else {
                // 解决从后台切换到前台，解码失败的问题
                doFlushCodec()
            }
        }
        return result
    }

    func doFlushCodec() {
        session = DecodeSession(codecpar: codecpar, options: options)
    }

    func shutdown() {
        session = nil
    }

    func seek(time _: TimeInterval) {
        lastPosition = 0
        startTime = 0
    }

    func decode() {
        lastPosition = 0
        startTime = 0
    }
}

class DecodeSession {
    fileprivate let isConvertNALSize: Bool
    fileprivate let formatDescription: CMFormatDescription
    fileprivate let decompressionSession: VTDecompressionSession

    init?(codecpar: AVCodecParameters, options: HPConfig) {
        let formats = [AV_PIX_FMT_YUV420P, AV_PIX_FMT_YUV420P9BE, AV_PIX_FMT_YUV420P9LE,
                       AV_PIX_FMT_YUV420P10BE, AV_PIX_FMT_YUV420P10LE, AV_PIX_FMT_YUV420P12BE, AV_PIX_FMT_YUV420P12LE,
                       AV_PIX_FMT_YUV420P14BE, AV_PIX_FMT_YUV420P14LE, AV_PIX_FMT_YUV420P16BE, AV_PIX_FMT_YUV420P16LE]
        //fps和pps信息改变后需要重新创建解码器才能正确解码
        guard options.canHardwareDecode(codecpar: codecpar), formats.contains(AVPixelFormat(codecpar.format)), let extradata = codecpar.extradata else {
            return nil
        }
        let extradataSize = codecpar.extradata_size
        guard extradataSize >= 7, extradata[0] == 1 else {
            return nil
        }

        if extradata[4] == 0xFE {
            extradata[4] = 0xFF
            isConvertNALSize = true //进行3字节到4字节的size转换
        } else {
            isConvertNALSize = false
        }
        
        //1.配置视频解码参数信息
        let dic: NSMutableDictionary = [
            kCVImageBufferChromaLocationBottomFieldKey: "left",
            kCVImageBufferChromaLocationTopFieldKey: "left",
            kCMFormatDescriptionExtension_FullRangeVideo: options.bufferPixelFormatType != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, //NV12
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [
                codecpar.codec_id.rawValue == AV_CODEC_ID_HEVC.rawValue ? "hvcC" : "avcC": NSData(bytes: extradata, length: Int(extradataSize)),
            ],
        ]
        //如果设置了采集时的宽高比
        if let aspectRatio = codecpar.aspectRatio {
            dic[kCVImageBufferPixelAspectRatioKey] = aspectRatio
        }
        if codecpar.color_space == AVCOL_SPC_BT709 {
            dic[kCMFormatDescriptionExtension_YCbCrMatrix] = kCMFormatDescriptionColorPrimaries_ITU_R_709_2//设置颜色转化矩阵
        }
        // codecpar.pointee.color_range == AVCOL_RANGE_JPEG kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let type = codecpar.codec_id.rawValue == AV_CODEC_ID_HEVC.rawValue ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
       
        //2.创建CMFormatDescription(这里是直接根据Type创建，也可以根据sps和pps信息创建)
        // swiftlint:disable line_length
        var description: CMFormatDescription?
        var status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: type, width: codecpar.width, height: codecpar.height, extensions: dic, formatDescriptionOut: &description)
        // swiftlint:enable line_length
        guard status == noErr, let formatDescription = description else {
            return nil
        }
        self.formatDescription = formatDescription
        
        //3.配置解码的图像参数
        let attributes: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: options.bufferPixelFormatType,
            kCVPixelBufferWidthKey: codecpar.width,
            kCVPixelBufferHeightKey: codecpar.height,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ]
        var session: VTDecompressionSession?
        // swiftlint:disable line_length
        status = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: formatDescription, decoderSpecification: nil, imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session)
        // swiftlint:enable line_length
        guard status == noErr, let decompressionSession = session else {
            return nil
        }
        //4.创建session
        self.decompressionSession = decompressionSession
    }

    deinit {
        VTDecompressionSessionWaitForAsynchronousFrames(decompressionSession)
        VTDecompressionSessionInvalidate(decompressionSession)
    }
}

extension CMFormatDescription {

    fileprivate func getSampleBuffer(isConvertNALSize: Bool, data: UnsafeMutablePointer<UInt8>, size: Int) throws -> CMSampleBuffer {
        
        if isConvertNALSize {
            var ioContext: UnsafeMutablePointer<AVIOContext>?
            let status = avio_open_dyn_buf(&ioContext)
            if status == 0 {
                var nalSize: UInt32 = 0
                let end = data + size //最后
                var nalStart = data //起点
                while nalStart < end {
                    /*
                     00000001 00000000 00000000
                     00000000
                     00000000
                     */
                    
                    nalSize = UInt32(UInt32(nalStart[0]) << 16 | UInt32(nalStart[1]) << 8 | UInt32(nalStart[2]))
                    avio_wb32(ioContext, nalSize)
                    nalStart += 3
                    avio_write(ioContext, nalStart, Int32(nalSize))
                    nalStart += Int(nalSize)
                }
                var demuxBuffer: UnsafeMutablePointer<UInt8>?
                let demuxSze = avio_close_dyn_buf(ioContext, &demuxBuffer)
                return try createSampleBuffer(data: demuxBuffer, size: Int(demuxSze))
            } else {
                throw NSError(errorCode: .codecVideoReceiveFrame, ffmpegErrnum: status)
            }
        } else {
            return try createSampleBuffer(data: data, size: size)
        }
    }

    //构造Block\SampleBuffer
    private func createSampleBuffer(data: UnsafeMutablePointer<UInt8>?, size: Int) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var sampleBuffer: CMSampleBuffer?
        // swiftlint:disable line_length
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: data, blockLength: size, blockAllocator: kCFAllocatorNull, customBlockSource: nil, offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &blockBuffer)
        if status == noErr {
            status = CMSampleBufferCreate(allocator: nil, dataBuffer: blockBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: self, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer)
            if let sampleBuffer = sampleBuffer {
                return sampleBuffer
            }
        }
        throw NSError(errorCode: .codecVideoReceiveFrame, ffmpegErrnum: status)
        // swiftlint:enable line_length
    }
}

extension HPConfig {
    ///只有视频流codec_id==AV_CODEC_ID_H264，才有VT硬解，音频始终用软解，或者CoreAudio的上层API
    func canHardwareDecode(codecpar: AVCodecParameters) -> Bool {
        if codecpar.codec_id == AV_CODEC_ID_H264, hardwareDecodeH264 {
            return true
        } else if codecpar.codec_id == AV_CODEC_ID_HEVC, #available(iOS 11.0, tvOS 11.0, OSX 10.13, *), VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), hardwareDecodeH265 {
            return true
        }
        return false
    }
}

extension UnsafeMutablePointer where Pointee == AVCodecParameters {
    //https://juejin.cn/post/6844903871463030792 对比理解
    //https://www.cnblogs.com/yongdaimi/p/9804699.html 简单理解
    func ceateContext(options: HPConfig) throws -> UnsafeMutablePointer<AVCodecContext> {
        //1.codecContext 内存分配
        var codecContextOption = avcodec_alloc_context3(nil)
        guard let codecContext = codecContextOption else {
            throw NSError(errorCode: .codecContextCreate)
        }
        //2.把AVStream流中的codecpar编解码参数信息填充到编解码器上下文中，AVStream.codecpar的类型为AVCodecParameters
        var result = avcodec_parameters_to_context(codecContext, self)
        guard result == 0 else {
            avcodec_free_context(&codecContextOption)
            throw NSError(errorCode: .codecContextSetParam, ffmpegErrnum: result)
        }
        //如果要硬解，需额外处理，设置编码格式，并设置AVCodecContext的硬件解码器上下文
        if options.canHardwareDecode(codecpar: pointee) {
            codecContext.pointee.opaque = Unmanaged.passUnretained(options).toOpaque()
            //协商像素格式，需要外部告诉FFMpeg
            codecContext.pointee.get_format = { ctx, fmt -> AVPixelFormat in
                guard let fmt = fmt, let ctx = ctx else {
                    return AV_PIX_FMT_NONE
                }
                let options = Unmanaged<HPConfig>.fromOpaque(ctx.pointee.opaque).takeUnretainedValue()
                var i = 0
                while fmt[i] != AV_PIX_FMT_NONE {
                    if fmt[i] == AV_PIX_FMT_VIDEOTOOLBOX {
                        //
                        var deviceCtx = av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_VIDEOTOOLBOX)
                        if deviceCtx == nil {
                            break
                        }
                        av_buffer_unref(&deviceCtx)
                        //⚠️奔溃过
                        //如果外部采用的是软解模块，而options.canHardwareDecode返回的是turn的话，这里会构造硬解AVCodecContext，所以当通过avcodec_send_packet时，会来到这个get_format回调里，但是由于外部采用的是软解，所以会出现坏内存访问的问题。
                        var framesCtx = av_hwframe_ctx_alloc(deviceCtx)
                        if let framesCtx = framesCtx {
                            let framesCtxData = UnsafeMutableRawPointer(framesCtx.pointee.data)
                                .bindMemory(to: AVHWFramesContext.self, capacity: 1)
                            framesCtxData.pointee.format = AV_PIX_FMT_VIDEOTOOLBOX
                            framesCtxData.pointee.sw_format = options.bufferPixelFormatType.format
                            framesCtxData.pointee.width = ctx.pointee.width
                            framesCtxData.pointee.height = ctx.pointee.height
                        }
                        if av_hwframe_ctx_init(framesCtx) != 0 {
                            av_buffer_unref(&framesCtx)
                            break
                        }
                        ctx.pointee.hw_frames_ctx = framesCtx //设置AVCodecContext的硬件解码器上下文
                        return fmt[i]
                    }
                    i += 1
                }
                return fmt[0]
            }
        }
        
        //3.根据解码器名找到codec（AVCodec当中存放的是解码器格式的配置信息）
        guard let codec = avcodec_find_decoder(codecContext.pointee.codec_id) else {
            avcodec_free_context(&codecContextOption)
            throw NSError(errorCode: .codecContextFindDecoder, ffmpegErrnum: result)
        }
        codecContext.pointee.codec_id = codec.pointee.id
        codecContext.pointee.flags |= AV_CODEC_FLAG2_FAST
        var lowres = options.lowres
        if lowres > codec.pointee.max_lowres {
            lowres = codec.pointee.max_lowres
        }
        codecContext.pointee.lowres = Int32(lowres)
        var avOptions = options.decoderOptions.avOptions
        if lowres > 0 {
            av_dict_set_int(&avOptions, "lowres", Int64(lowres), 0)
        }
        //4. codecContext打开编解码器
        result = avcodec_open2(codecContext, codec, &avOptions)
        guard result == 0 else {
            avcodec_free_context(&codecContextOption)
            throw NSError(errorCode: .codesContextOpen, ffmpegErrnum: result)
        }
        return codecContext
    }
}
