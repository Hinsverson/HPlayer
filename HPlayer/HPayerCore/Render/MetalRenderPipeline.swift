//
//  HPMetalRenderPipeline.swift
//  HPlayer
//
//  Created by hinson on 2020/12/18.
//  Copyright © 2020 tommy. All rights reserved.
//

import CoreImage
import CoreVideo
import Foundation
import Metal
import simd
import VideoToolbox
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/*
 创建Metal渲染管线State？
 1.创建渲染管线描述对象MTLRenderPipelineDescriptor，配置vertexFunction、fragmentFunction、颜色格式
 1.通过device.makeRenderPipelineState(descriptor)
 */
protocol HPMetalRenderPipeline {
    var device: MTLDevice { get }
    var library: MTLLibrary { get }
    var state: MTLRenderPipelineState { get }
    var descriptor: MTLRenderPipelineDescriptor { get }
    init(device: MTLDevice, library: MTLLibrary)
}

struct HPMetalRenderPipelineNV12: HPMetalRenderPipeline {
    let device: MTLDevice
    let library: MTLLibrary
    let state: MTLRenderPipelineState
    let descriptor: MTLRenderPipelineDescriptor
    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
        descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "mapTexture")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.fragmentFunction = library.makeFunction(name: "displayNV12Texture")
        // swiftlint:disable force_try
        try! state = device.makeRenderPipelineState(descriptor: descriptor)
        // swftlint:enable force_try
    }
}

struct HPMetalRenderPipelineBGRA: HPMetalRenderPipeline {
    let device: MTLDevice
    let library: MTLLibrary
    let state: MTLRenderPipelineState
    let descriptor: MTLRenderPipelineDescriptor
    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
        descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "mapTexture")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.fragmentFunction = library.makeFunction(name: "displayTexture")
        // swiftlint:disable force_try
        try! state = device.makeRenderPipelineState(descriptor: descriptor)
        // swftlint:enable force_try
    }
}

struct HPMetalRenderPipelineYUV: HPMetalRenderPipeline {
    let device: MTLDevice
    let library: MTLLibrary
    let state: MTLRenderPipelineState
    let descriptor: MTLRenderPipelineDescriptor
    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
        descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "mapTexture")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.fragmentFunction = library.makeFunction(name: "displayYUVTexture")
        // swiftlint:disable force_try
        try! state = device.makeRenderPipelineState(descriptor: descriptor)
        // swftlint:enable force_try
    }
}
