//
//  MetalRenderer.swift
//  HPlayer
//
//  Created by hinson on 2020/12/18.
//  Copyright © 2020 tommy. All rights reserved.
//

import CoreVideo
import Foundation
import Metal
import QuartzCore
import simd
import VideoToolbox

/// Metal的渲染封装类
class HPMetalRender {
    static let share = HPMetalRender()
    
    /// GPU设备
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private let library: MTLLibrary
    
    /// 不同颜色空间的渲染管线
    private lazy var yuv = HPMetalRenderPipelineYUV(device: device, library: library)
    private lazy var nv12 = HPMetalRenderPipelineNV12(device: device, library: library)
    private lazy var bgra = HPMetalRenderPipelineBGRA(device: device, library: library)
    
    ///采样器创建
    private lazy var samplerState: MTLSamplerState? = {
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.mipFilter = .nearest
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.rAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        return device.makeSamplerState(descriptor: samplerDescriptor)
    }()

    private lazy var colorConversion601VideoRangeMatrixBuffer: MTLBuffer? = {
        var matrix = simd_float3x3([1.164, 1.164, 1.164], [0, -0.392, 2.017], [1.596, -0.813, 0])
        let buffer = device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float3x3>.size, options: .storageModeShared)
        buffer?.label = "colorConversionMatrix"
        return buffer
    }()

    private lazy var colorConversion601FullRangeMatrixBuffer: MTLBuffer? = {
        var matrix = simd_float3x3([1.0, 1.0, 1.0], [0.0, -0.343, 1.765], [1.4, -0.711, 0.0])
        let buffer = device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float3x3>.size, options: .storageModeShared)
        buffer?.label = "colorConversionMatrix"
        return buffer
    }()

    private lazy var colorConversion709VideoRangeMatrixBuffer: MTLBuffer? = {
        var matrix = simd_float3x3([1.164, 1.164, 1.164], [0.0, -0.213, 2.112], [1.793, -0.533, 0.0])
        let buffer = device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float3x3>.size, options: .storageModeShared)
        buffer?.label = "colorConversionMatrix"
        return buffer
    }()

    private lazy var colorConversion709FullRangeMatrixBuffer: MTLBuffer? = {
        var matrix = simd_float3x3([1, 1, 1], [0.0, -0.187, 1.856], [1.570, -0.467, 0.0])
        let buffer = device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float3x3>.size, options: .storageModeShared)
        buffer?.label = "colorConversionMatrix"
        return buffer
    }()

    private lazy var colorOffsetVideoRangeMatrixBuffer: MTLBuffer? = {
        var firstColumn = SIMD3<Float>(-(16.0 / 255.0), -0.5, -0.5)
        let buffer = device.makeBuffer(bytes: &firstColumn, length: MemoryLayout<SIMD3<Float>>.size, options: .storageModeShared)
        buffer?.label = "colorOffset"
        return buffer
    }()

    private lazy var colorOffsetFullRangeMatrixBuffer: MTLBuffer? = {
        var firstColumn = SIMD3<Float>(0, -0.5, -0.5)
        let buffer = device.makeBuffer(bytes: &firstColumn, length: MemoryLayout<SIMD3<Float>>.size, options: .storageModeShared)
        buffer?.label = "colorOffset"
        return buffer
    }()

    private init() {
        device = MTLCreateSystemDefaultDevice()! //macOS上命令行使用必须显示链接CoreGraphic
        var library: MTLLibrary!
        library = device.makeDefaultLibrary() //创建Metal默认资源库，包含编译时的metal资源文件
        if library == nil, let path = Bundle(for: type(of: self)).path(forResource: "Metal", ofType: "bundle"), let bundle = Bundle(path: path) {
            library = try? device.makeDefaultLibrary(bundle: bundle)
        }
        self.library = library
        commandQueue = device.makeCommandQueue()
    }

    //清屏渲染
    func clear(drawable: CAMetalDrawable, renderPassDescriptor: MTLRenderPassDescriptor) {
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        guard let commandBuffer = commandQueue?.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    ///根据渲染display（展示模式），把纹理和pixelBuffer渲染到drawable上，通过renderPassDescriptor来串联
    func draw(pixelBuffer: HPBuffer, display: HPDisplayEnum = .plane, inputTextures: [MTLTexture], drawable: CAMetalDrawable, renderPassDescriptor: MTLRenderPassDescriptor) {
        
        //colorAttachments: rendering pass产生的像素的目的地
        guard let renderPassColorAttachmentDescriptor = renderPassDescriptor.colorAttachments[0] else { return }
        //颜色渲染目标为屏幕texture上
        renderPassColorAttachmentDescriptor.texture = drawable.texture
    
        //commandQueue 创建 commandBuffer
        //commandBuffer 通过 renderPassDescriptor 创建 RenderCommandEncoder
        guard inputTextures.count > 0, let commandBuffer = commandQueue?.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        /*
          通过RenderCommandEncoder进行渲染操作的设置
          1.setRenderPipelineState 设置渲染管线
          2.setFragmentSamplerState 设置采样器
          3.setFragmentTexture 设置纹理到片元着色器对应的index上（多个纹理）
          4.setFragmentBuffer 设置缓冲区到对应的index上（渲染buffer、和colorOffsetcolorOffset）
         */
        encoder.pushDebugGroup("RenderFrame")
        
        encoder.setRenderPipelineState(pipeline(pixelBuffer: pixelBuffer).state)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        
        for (index, texture) in inputTextures.enumerated() {
            texture.label = "texture\(index)"
            encoder.setFragmentTexture(texture, index: index)
        }
        setFragmentBuffer(pixelBuffer: pixelBuffer, encoder: encoder)
        
        // 根据不同的展示模式，传递不同VBO数据并绘制出来
        display.set(encoder: encoder)
        
        encoder.popDebugGroup()
        
        encoder.endEncoding() //渲染命令装配完毕
        commandBuffer.present(drawable) //输出到屏幕（drawable可以理解为一块画布）
        commandBuffer.commit() //提交渲染，必须最后调用
    }

    /// 根据不同的颜色通道，使用不同颜色空间的渲染管线
    private func pipeline(pixelBuffer: HPBuffer) -> HPMetalRenderPipeline {
        switch pixelBuffer.planeCount {
        case 3:
            return yuv
        case 2:
            return nv12
        case 1:
            return bgra
        default:
            return bgra
        }
    }

    private func setFragmentBuffer(pixelBuffer: HPBuffer, encoder: MTLRenderCommandEncoder) {
        let pixelFormatType = pixelBuffer.format
        if pixelFormatType != kCVPixelFormatType_32BGRA {
            //根据colorAttachments、isFullRangeVideo取不同的格式buffer
            var buffer = colorConversion601FullRangeMatrixBuffer
            let isFullRangeVideo = pixelBuffer.isFullRangeVideo
            let colorAttachments = pixelBuffer.colorAttachments
            if colorAttachments == kCVImageBufferYCbCrMatrix_ITU_R_601_4 {
                buffer = isFullRangeVideo ? colorConversion601FullRangeMatrixBuffer : colorConversion601VideoRangeMatrixBuffer
            } else if colorAttachments == kCVImageBufferYCbCrMatrix_ITU_R_709_2 {
                buffer = isFullRangeVideo ? colorConversion709FullRangeMatrixBuffer : colorConversion709VideoRangeMatrixBuffer
            }
            //传递不同格式的颜色转换矩阵、偏移信息数据到fsh
            encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
            let colorOffset = isFullRangeVideo ? colorOffsetFullRangeMatrixBuffer : colorOffsetVideoRangeMatrixBuffer
            encoder.setFragmentBuffer(colorOffset, offset: 0, index: 1) //设置colorOffset buffer到片元1
        }
    }
}
