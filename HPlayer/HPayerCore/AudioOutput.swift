//
//  HPAudioOutput.swift
//  HPlayer
//
//  Created by hinson on 2020/12/21.
//  Copyright © 2020 tommy. All rights reserved.
//

import AudioToolbox
import CoreAudio
import CoreMedia
import QuartzCore

///播放器代理回调
protocol HPAudioPlayerDelegate: AnyObject {
    func audioPlayerShouldInputData(ioData: UnsafeMutableAudioBufferListPointer, numberOfFrames: UInt32, numberOfChannels: UInt32)
    func audioPlayerWillRenderSample(sampleTimestamp: AudioTimeStamp)
    func audioPlayerDidRenderSample(sampleTimestamp: AudioTimeStamp)
}

///播放器的抽象描述
protocol HPAudioPlayer: AnyObject {
    var delegate: HPAudioPlayerDelegate? { get set }
    var playbackRate: Float { get set }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var isPaused: Bool { get set }
}

///audio渲染类
final class HPAudioOutput: HPFrameOutput {
    
    weak var renderSource: HPOutputRenderDelegate?
    var isPaused: Bool {
        get {
            audioPlayer.isPaused
        }
        set {
            audioPlayer.isPaused = newValue
        }
    }
    
    private let semaphore = DispatchSemaphore(value: 1)
    private var currentRenderReadOffset = 0
    private var currentRender: HPAudioFrame? {
        didSet {
            if currentRender == nil {
                currentRenderReadOffset = 0
            }
        }
    }

    let audioPlayer: HPAudioPlayer = HPAudioGraphPlayer()

    init() {
        audioPlayer.delegate = self
    }

    func clear() {
        semaphore.wait()
        currentRender = nil
        semaphore.signal()
    }
}

///audio播放器的回调处理
extension HPAudioOutput: HPAudioPlayerDelegate {
    //为播放器喂数据
    func audioPlayerShouldInputData(ioData: UnsafeMutableAudioBufferListPointer, numberOfFrames: UInt32, numberOfChannels _: UInt32) {
        semaphore.wait()
        defer {
            semaphore.signal()
        }
        
        /* 把currentRender内的数据填充到ioData中，numberOfFrames是需要填充的采样点。
         
         一次audioPlayerShouldInputData必须保证填满ioData中numberOfFrames个采样点数据
         如果某个currentRender携带的采样数据不够一次numberOfFrames，则会getOutputRender取下一个HPAudioFrame填充
         HPAudioFrame内如果还有未被填充的数据，则等地下一次audioPlayerShouldInputData回调进来填充
         
         整体过程就是一边在给数据，一边再按规则填充数据，没有数据就找getOutputRender并更新偏移量，有剩余就等待下一次填充。
         第一趟audioPlayerShouldInputData回调需要读取471个采样点数据，numberOfSamples=471
         进入循环取出一个HPAudioFrame，此时residueLinesize=448=currentRender.numberOfSamples，currentRenderReadOffset=0
         本次准备读取的采样点数framesToCopy = 448
         读完448个采样点填充到ioData后，currentRenderReadOffset = 448，但是此时numberOfSamples=471-448=23
         再次进入循环发现currentRender != nil，但是residueLinesize=0，表面currentRender已被读完，设置为nil并更新currentRenderReadOffset=0最后continue再次进入循环
         再次进入循环currentRender==nil，新取一个队列内的HPAudioFrame，此时往后residueLinesize=1024=currentRender.numberOfSamples，currentRenderReadOffset=0
         但是本次准备读取的采样点数framesToCopy = min(numberOfSamples, residueLinesize) = 23
         读取剩余本次audioPlayerShouldInputData回调需要的23个采样点数据后跳出循环
         */
        
        var ioDataWriteOffset = 0
        var numberOfSamples = Int(numberOfFrames) //每次audioPlayerShouldInputData回调需要填充的采样点数量
        while numberOfSamples > 0 {
            //如果没有数据就去队列中取一个audioframe
            if currentRender == nil {
                currentRender = renderSource?.getOutputRender(type: .audio) as? HPAudioFrame
            }
            //开始数据填充时currentRender必须保证非空
            guard let currentRender = currentRender else {
                break
            }
            //currentRenderReadOffset：记录currentRender中已经被读的采样点的数量刻度
            let residueLinesize = currentRender.numberOfSamples - currentRenderReadOffset//currentRender中剩余的能被读取的采样点数
            guard residueLinesize > 0 else { //没有了的话就置空，并且继续从队列中读取audioframe
                self.currentRender = nil
                continue
            }
            let framesToCopy = min(numberOfSamples, residueLinesize)//准备要读取的采样点数
            
            //填充数据操作
            let bytesToCopy = framesToCopy * MemoryLayout<Float>.size
            let offset = currentRenderReadOffset * MemoryLayout<Float>.size
            for i in 0 ..< min(ioData.count, currentRender.dataWrap.data.count) {//ioData.count = 2 ，说明2个声道
                (ioData[i].mData! + ioDataWriteOffset).copyMemory(from: currentRender.dataWrap.data[i]! + offset, byteCount: bytesToCopy)
            }
            numberOfSamples -= framesToCopy //更新还需要被填充的采样点数
            ioDataWriteOffset += bytesToCopy //更新读取便宜
            currentRenderReadOffset += framesToCopy //更新currentRender中已经被读的采样点的数量刻度
        }
        
        //为ioData充满numberOfFrames个采样点数据后，如果ioData[i]的mDataByteSize-sizeCopied大于0表示ioData[i]容器还有剩余空间，那么直接填充0。
        //⚠️这里调试发现播放本地视频时不会触发，猜测是为了健壮性或者其他场景会导致ioData[i]内有残留数据。
        let sizeCopied = (Int(numberOfFrames) - numberOfSamples) * MemoryLayout<Float>.size//填充的字节数
        for i in 0 ..< ioData.count {
            let sizeLeft = Int(ioData[i].mDataByteSize) - sizeCopied
            if sizeLeft > 0 {
                memset(ioData[i].mData! + sizeCopied, 0, sizeLeft)
            }
        }
    }

    func audioPlayerWillRenderSample(sampleTimestamp _: AudioTimeStamp) {}

    ///渲染完音频数据后 去item中更新cmtime
    func audioPlayerDidRenderSample(sampleTimestamp _: AudioTimeStamp) {
        if let currentRender = currentRender {
            let currentPreparePosition = currentRender.position + currentRender.duration * Int64(currentRenderReadOffset) / Int64(currentRender.numberOfSamples)
            renderSource?.setAudio(time: currentRender.timebase.cmtime(for: currentPreparePosition))
        }
    }
}
