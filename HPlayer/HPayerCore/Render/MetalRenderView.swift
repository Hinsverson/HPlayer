//
//  Render.swift
//  HPlayer
//
//  Created by hinson on 2020/12/15.
//  Copyright © 2020 tommy. All rights reserved.
//

import CoreMedia
import MetalKit
import AVFoundation

/// 渲染接口：Item作为代理为渲染类型（View渲染层）提供渲染数据
protocol HPOutputRenderDelegate: AnyObject {
    ///var currentPlaybackTime: TimeInterval { get }
    ///代理提供Render数据帧来进行渲染，通过HPFrame来描述
    func getOutputRender(type: AVFoundation.AVMediaType) -> HPFrame?
    ///更新视频时间回调
    func setVideo(time: CMTime)
    func setAudio(time: CMTime)
}

/// 用来进行渲染的类型（View渲染层）的抽象描述
protocol HPFrameOutput {
    /// 被渲染的资源
    var renderSource: HPOutputRenderDelegate? { get set }
    ///var isPaused: Bool { get set }
    func clear()
}

/// Metal渲染类
final class HPMetalView: MTKView, MTKViewDelegate, HPFrameOutput {
    
    weak var renderSource: HPOutputRenderDelegate?
    
    private let textureCache = HPMetalTextureCache()
    private let renderPassDescriptor = MTLRenderPassDescriptor()
    var display: HPDisplayEnum = .plane
    private var pixelBuffer: HPBuffer? {
        didSet {
            if let pixelBuffer = pixelBuffer {
                autoreleasepool {
                    let size = display == .plane ? pixelBuffer.drawableSize : UIScreen.size
                    //渲染画布的分辨率大小，保持和视频画面一样
                    /*
                     这里就算在渲染第一桢前，外部设置contentMode = .scaleAspectFit, drawableSize = 原视频size，但是依然会撑满渲染，（待研究），临时解决方法是设置HPMetalView的布局size和视频size比例一样。
                     */
                    if drawableSize != size {
                        drawableSize = size //drawableSize会默认跟着View的bounds变化
                    }
                    
                    //拿到纹理并通过Cache管理
                    let textures = pixelBuffer.textures(frome: textureCache)
                    guard let drawable = currentDrawable else { return }
                    //绘制
                    HPMetalRender.share.draw(pixelBuffer: pixelBuffer, display: display, inputTextures: textures, drawable: drawable, renderPassDescriptor: renderPassDescriptor)
                }
            } //这里原本就有的注视，这里的逻辑如果pixelBuffer为空，说明取不到，不需要渲染而不是清空
//            else {
//                guard let drawable = currentDrawable else {
//                    return
//                }
//                HPMetalRender.share.clear(drawable: drawable, renderPassDescriptor: renderPassDescriptor)
//            }
        }
    }

    init() {
        let device = HPMetalRender.share.device
        super.init(frame: .zero, device: device)
        //MTLRenderPassDescriptor用来配置渲染结果的输出去向，缓存到一个或多个RT（MTLTexture）上，用于Tile阶段的后续计算或者输出到屏幕上。通常MTLRenderPassDescriptor对象设置好后会用来创建当前commandBuffer下的renderEncoder。
        //MTLRenderPassDescriptor对象包含一组attachments，作为rendering pass产生的像素的目的地
        //MTLRenderPassAttachmentDescriptor参考：https://zhuanlan.zhihu.com/p/92840318

        //clearColor：这个是loadAction为MTLLoadActionClear的清空颜色。
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        //loadAction：这个是在渲染开始时的RT动作，是清空RT还是保留原信息还是无所谓，默认是无所谓MTLLoadActionDontCare
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        delegate = self
        preferredFramesPerSecond = HPManager.preferredFramesPerSecond
        isPaused = true
    }

    required init(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func clear() {
        pixelBuffer = nil
    }

    func mtkView(_: MTKView, drawableSizeWillChange _: CGSize) {}

    func draw(in _: MTKView) {
        if let frame = renderSource?.getOutputRender(type: .video) as? HPVideoFrameVTB, let corePixelBuffer = frame.corePixelBuffer {
            renderSource?.setVideo(time: frame.cmtime)
            pixelBuffer = corePixelBuffer
            
            //HPLog("HPVideoFrameVTB Info: position(\(frame.position)) duration(\(frame.duration)) timebase(\(frame.timebase)) size(\(frame.size)) cmtime(\(frame.cmtime)) seconds(\(frame.seconds))")
        }
    }
    /*
    #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
    override func touchesMoved(_ touches: Set<UITouch>, with: UIEvent?) {
        if display == .plane {
            super.touchesMoved(touches, with: with)
        } else {
            display.touchesMoved(touch: touches.first!)
        }
    }
    #endif
     */
    func toImage() -> UIImage? {
        pixelBuffer?.image()
    }
}
