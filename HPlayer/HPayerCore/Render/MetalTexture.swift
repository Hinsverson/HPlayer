//
//  MetalTexture.swift
//  HPlayer
//
//  Created by hinson on 2020/12/18.
//  Copyright © 2020 tommy. All rights reserved.
//

import MetalKit

/// 纹理的渲染缓存类
/// 使用CVMetalTextureCache 来管理 CVMetalTextureCacheCreateTextureFromImage
public final class HPMetalTextureCache {
    ///管理 通过CVMetalTextureCacheCreateTextureFromImageMTLTexture方法从CVPixelBuffer转化到的CVMetalTexture
    private var textureCache: CVMetalTextureCache?
    private let device: MTLDevice
    private var textures = [MTLTexture]()
   
    public init() {
        device = HPMetalRender.share.device
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    /// 通过CVPixelBuffer转化构造[MTLTexture]对象
    public func texture(pixelBuffer: CVPixelBuffer) -> [MTLTexture] {
        textures.removeAll()
        let formats: [MTLPixelFormat]
        if pixelBuffer.planeCount == 3 {
            formats = [.r8Unorm, .r8Unorm, .r8Unorm]
        } else if pixelBuffer.planeCount == 2 { //nv12
            formats = [.r8Unorm, .rg8Unorm]
        } else {
            formats = [.bgra8Unorm]
        }
        for index in 0 ..< pixelBuffer.planeCount {
            let width = pixelBuffer.widthOfPlane(at: index)
            let height = pixelBuffer.heightOfPlane(at: index)
            if let texture = texture(pixelBuffer: pixelBuffer, planeIndex: index, pixelFormat: formats[index], width: width, height: height) {
                textures.append(texture)
            }
        }
        return textures
    }

    /// 根据CVPixelBuffer里的特殊位置上的数据信息，构造一个MTLTexture对象
    private func texture(pixelBuffer: CVPixelBuffer, planeIndex: Int, pixelFormat: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        var cvTextureOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache!, pixelBuffer, nil, pixelFormat, width, height, planeIndex, &cvTextureOut)
        guard let cvTexture = cvTextureOut, let inputTexture = CVMetalTextureGetTexture(cvTexture) else {
            return nil
        }
        return inputTexture
    }

    /// 根据原始参数描述，生成[MTLTexture]纹理对象
    func textures(formats: [MTLPixelFormat], widths: [Int], heights: [Int], bytes: [UnsafeMutablePointer<UInt8>?], bytesPerRows: [Int32]) -> [MTLTexture] {
        let planeCount = formats.count
        if textures.count > planeCount {
            textures.removeLast(textures.count - planeCount)
        }
        for i in 0 ..< planeCount {
            let key = "MTLTexture" + [Int(formats[i].rawValue), widths[i], heights[i]].description
            if textures.count <= i || textures[i].key != key {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: formats[i], width: widths[i], height: heights[i], mipmapped: false)
                let texture = device.makeTexture(descriptor: descriptor)!
                if textures.count <= i {
                    textures.append(texture)
                } else {
                    textures[i] = texture
                }
            }
            textures[i].replace(region: MTLRegionMake2D(0, 0, widths[i], heights[i]), mipmapLevel: 0, withBytes: bytes[i]!, bytesPerRow: Int(bytesPerRows[i]))
        }
        return textures
    }

    deinit {
        textures.removeAll()
        if let textureCache = textureCache {
            CVMetalTextureCacheFlush(textureCache, 0)
        }
    }
}

extension MTLTexture {
    var key: String { "MTLTexture" + [Int(pixelFormat.rawValue), width, height].description }
}
