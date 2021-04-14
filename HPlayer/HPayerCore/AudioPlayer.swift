//
//  HPAudioPlayer.swift
//  HPlayer
//
//  Created by hinson on 2020/12/21.
//  Copyright © 2020 tommy. All rights reserved.
//

import AudioToolbox
import CoreAudio

final class HPAudioGraphPlayer: HPAudioPlayer {
    private let graph: AUGraph
    private var audioUnitForMixer: AudioUnit!
    private var audioUnitForTimePitch: AudioUnit!
    private var audioStreamBasicDescription = HPManager.outputFormat()
    
    private var sampleRate: Float64 { audioStreamBasicDescription.mSampleRate }
    private var numberOfChannels: UInt32 { audioStreamBasicDescription.mChannelsPerFrame }
    
    //protocal
    var isPaused: Bool {
        get {
            var running = DarwinBoolean(false)
            if AUGraphIsRunning(graph, &running) == noErr {
                return !running.boolValue
            }
            return true
        }
        set {
            if newValue != isPaused {
                if newValue {
                    AUGraphStop(graph)
                } else {
                    AUGraphStart(graph)
                }
            }
        }
    }
    weak var delegate: HPAudioPlayerDelegate?
    var playbackRate: Float {
        set {
            AudioUnitSetParameter(audioUnitForTimePitch, kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0, newValue, 0)
        }
        get {
            var playbackRate = AudioUnitParameterValue(0.0)
            AudioUnitGetParameter(audioUnitForMixer, kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0, &playbackRate)
            return playbackRate
        }
    }

    var volume: Float {
        set {
            AudioUnitSetParameter(audioUnitForMixer, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, 0, newValue, 0)
        }
        get {
            var volume = AudioUnitParameterValue(0.0)
            AudioUnitGetParameter(audioUnitForMixer, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, 0, &volume)
            return volume
        }
    }

    public var isMuted: Bool {
        set {
            let value = newValue ? 0 : 1
            AudioUnitSetParameter(audioUnitForMixer, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, 0, AudioUnitParameterValue(value), 0)
        }
        get {
            var value = AudioUnitParameterValue(1.0)
            AudioUnitGetParameter(audioUnitForMixer, kMultiChannelMixerParam_Enable, kAudioUnitScope_Input, 0, &value)
            return value == 0
        }
    }

    
    init() {
        //创建AUGraph
        var newGraph: AUGraph!
        NewAUGraph(&newGraph)
        graph = newGraph
        
        //转换处理
        var descriptionForTimePitch = AudioComponentDescription()
        descriptionForTimePitch.componentType = kAudioUnitType_FormatConverter
        descriptionForTimePitch.componentSubType = kAudioUnitSubType_NewTimePitch
        descriptionForTimePitch.componentManufacturer = kAudioUnitManufacturer_Apple

        //混合处理
        var descriptionForMixer = AudioComponentDescription()
        descriptionForMixer.componentType = kAudioUnitType_Mixer
        descriptionForMixer.componentManufacturer = kAudioUnitManufacturer_Apple
        descriptionForMixer.componentSubType = kAudioUnitSubType_MultiChannelMixer
        
        //播放处理
        var descriptionForOutput = AudioComponentDescription()
        descriptionForOutput.componentType = kAudioUnitType_Output
        descriptionForOutput.componentManufacturer = kAudioUnitManufacturer_Apple
        descriptionForOutput.componentSubType = kAudioUnitSubType_RemoteIO
        
        //添加node
        var nodeForTimePitch = AUNode()
        var nodeForMixer = AUNode()
        var nodeForOutput = AUNode()
        AUGraphAddNode(graph, &descriptionForTimePitch, &nodeForTimePitch)
        AUGraphAddNode(graph, &descriptionForMixer, &nodeForMixer)
        AUGraphAddNode(graph, &descriptionForOutput, &nodeForOutput)
        
        //打开graph
        AUGraphOpen(graph)
        
        //链接node处理链条，从A的output连接到B的input
        AUGraphConnectNodeInput(graph, nodeForTimePitch, 0, nodeForMixer, 0)
        AUGraphConnectNodeInput(graph, nodeForMixer, 0, nodeForOutput, 0)
        
        var audioUnitForOutput: AudioUnit!
        //取出AudioUnit
        AUGraphNodeInfo(graph, nodeForTimePitch, &descriptionForTimePitch, &audioUnitForTimePitch)
        AUGraphNodeInfo(graph, nodeForMixer, &descriptionForMixer, &audioUnitForMixer)
        AUGraphNodeInfo(graph, nodeForOutput, &descriptionForOutput, &audioUnitForOutput)
        
        var inputCallbackStruct = renderCallbackStruct()
        AUGraphSetNodeInputCallback(graph, nodeForTimePitch, 0, &inputCallbackStruct)
        
        //监听输出（音频渲染处理）时的回调
        addRenderNotify(audioUnit: audioUnitForOutput)
       
        //设置每个AudioUnit的Scope点的参数
        let audioStreamBasicDescriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let inDataSize = UInt32(MemoryLayout.size(ofValue: HPManager.audioPlayerMaximumFramesPerSlice))
        [audioUnitForTimePitch, audioUnitForMixer, audioUnitForOutput].forEach { unit in
            guard let unit = unit else { return }
            //最大Slice
            AudioUnitSetProperty(unit,
                                 kAudioUnitProperty_MaximumFramesPerSlice,
                                 kAudioUnitScope_Global, 0,
                                 &HPManager.audioPlayerMaximumFramesPerSlice,
                                 inDataSize)
            //输入的ABSD格式（一般都是PCM格式）
            AudioUnitSetProperty(unit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Input, 0,
                                 &audioStreamBasicDescription,
                                 audioStreamBasicDescriptionSize)
            //输出的ABSD格式（一般都是PCM格式）
            AudioUnitSetProperty(unit,
                                 kAudioUnitProperty_StreamFormat,
                                 kAudioUnitScope_Output, 0,
                                 &audioStreamBasicDescription,
                                 audioStreamBasicDescriptionSize)
        }
        
        //初始化graph
        AUGraphInitialize(graph)
    }

    ///拿播放数据的回调
    private func renderCallbackStruct() -> AURenderCallbackStruct {
        var inputCallbackStruct = AURenderCallbackStruct()
        //回调过程中self不会被释放，所以passUnretained
        inputCallbackStruct.inputProcRefCon = Unmanaged.passUnretained(self).toOpaque()
        inputCallbackStruct.inputProc = { refCon, _, _, _, inNumberFrames, ioData in
            guard let ioData = ioData else {
                return noErr
            }
            let `self` = Unmanaged<HPAudioGraphPlayer>.fromOpaque(refCon).takeUnretainedValue()
            self.delegate?.audioPlayerShouldInputData(ioData: UnsafeMutableAudioBufferListPointer(ioData), numberOfFrames: inNumberFrames, numberOfChannels: self.numberOfChannels)
            return noErr
        }
        return inputCallbackStruct
    }

    private func addRenderNotify(audioUnit: AudioUnit) {
        AudioUnitAddRenderNotify(audioUnit, { refCon, ioActionFlags, inTimeStamp, _, _, _ in
            let `self` = Unmanaged<HPAudioGraphPlayer>.fromOpaque(refCon).takeUnretainedValue()
            autoreleasepool {
                //即将渲染
                if ioActionFlags.pointee.contains(.unitRenderAction_PreRender) {
                    self.delegate?.audioPlayerWillRenderSample(sampleTimestamp: inTimeStamp.pointee)
                //结束渲染
                } else if ioActionFlags.pointee.contains(.unitRenderAction_PostRender) {
                    self.delegate?.audioPlayerDidRenderSample(sampleTimestamp: inTimeStamp.pointee)
                }
            }
            return noErr
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        //释放处理，注意顺序，和初始化处理是反过来的，stop、Uninitialize、Close、dispose
        AUGraphStop(graph)
        AUGraphUninitialize(graph)
        AUGraphClose(graph)
        DisposeAUGraph(graph)
    }
}

import Accelerate
import AVFoundation

//AVAudioEngine是一个定义一组连接的音频节点的类,你在项目添加两个节点 AVAudioPlayerNode 和 AVAudioUnitTimePitch
//使用参考：https://blog.csdn.net/Philm_iOS/article/details/81664556
@available(OSX 10.13, tvOS 11.0, iOS 11.0, *)
final class AudioEnginePlayer: HPAudioPlayer {
    
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    ///此节点类型是效果节点，具体来说，它可以改变播放速率和音频音高。
    private let picth = AVAudioUnitTimePitch()
    
    var isPaused: Bool {
        get {
            engine.isRunning
        }
        set {
            if newValue {
                if !engine.isRunning {
                    try? engine.start()
                }
                player.play()
            } else {
                player.pause()
                engine.pause()
            }
        }
    }
    weak var delegate: HPAudioPlayerDelegate?

    var playbackRate: Float {
        get {
            picth.rate
        }
        set {
            picth.rate = min(32, max(1.0 / 32.0, newValue))
        }
    }

    var volume: Float {
        get {
            player.volume
        }
        set {
            player.volume = newValue
        }
    }

    var isMuted: Bool {
        get {
            volume == 0
        }
        set {}
    }

    init() {
        //添加node
        engine.attach(player)
        engine.attach(picth)
        
        //链接node
        let format = HPManager.audioDefaultFormat
        engine.connect(player, to: picth, format: format)
        engine.connect(picth, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try? engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: HPManager.audioPlayerMaximumFramesPerSlice)
        
        /* 原本就注释了的
        engine.inputNode.setManualRenderingInputPCMFormat(format) { count -> UnsafePointer<AudioBufferList>? in
            self.delegate?.audioPlayerShouldInputData(ioData: <#T##UnsafeMutableAudioBufferListPointer#>, numberOfSamples: <#T##UInt32#>, numberOfChannels: <#T##UInt32#>)
        }*/
    }

    func audioPlay(buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
}

extension AVAudioFormat {
    func toPCMBuffer(data: NSData) -> AVAudioPCMBuffer? {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: self, frameCapacity: UInt32(data.length) / streamDescription.pointee.mBytesPerFrame) else {
            return nil
        }
        pcmBuffer.frameLength = pcmBuffer.frameCapacity
        let channels = UnsafeBufferPointer(start: pcmBuffer.floatChannelData, count: Int(pcmBuffer.format.channelCount))
        data.getBytes(UnsafeMutableRawPointer(channels[0]), length: data.length)
        return pcmBuffer
    }
}



