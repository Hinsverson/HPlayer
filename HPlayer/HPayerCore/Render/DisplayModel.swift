//
//  DisplayModel.swift
//  HPlayer
//
//  Created by hinson on 2020/12/18.
//  Copyright © 2020 tommy. All rights reserved.
//

import Foundation
import Metal
import simd

public enum HPDisplayEnum {
    case plane
}

extension HPDisplayEnum {
    private static var planeDisplay = HPPlaneDisplayModel()

    func set(encoder: MTLRenderCommandEncoder) {
        switch self {
        case .plane:
            HPDisplayEnum.planeDisplay.set(encoder: encoder)
        }
    }
}

private class HPPlaneDisplayModel {
    let indexCount: Int
    let indexType = MTLIndexType.uint16
    let primitiveType = MTLPrimitiveType.triangleStrip
    let indexBuffer: MTLBuffer
    let posBuffer: MTLBuffer?
    let uvBuffer: MTLBuffer?
    let matrixBuffer: MTLBuffer?

    fileprivate init() {
        let (indices, positions, uvs) = HPPlaneDisplayModel.genSphere()
        let device = HPMetalRender.share.device
        indexCount = indices.count
        indexBuffer = device.makeBuffer(bytes: indices, length: MemoryLayout<UInt16>.size * indexCount, options: .storageModeShared)!
        posBuffer = device.makeBuffer(bytes: positions, length: MemoryLayout<simd_float4>.size * positions.count, options: .storageModeShared)
        uvBuffer = device.makeBuffer(bytes: uvs, length: MemoryLayout<simd_float2>.size * uvs.count, options: .storageModeShared)
        var matrix = matrix_identity_float4x4
        matrixBuffer = device.makeBuffer(bytes: &matrix, length: MemoryLayout<simd_float4x4>.size, options: .storageModeShared)
    }

    private static func genSphere() -> ([UInt16], [simd_float4], [simd_float2]) {
        let indices: [UInt16] = [0, 1, 2, 3]
        //顶点坐标位置
        let positions: [simd_float4] = [
            [-1.0, -1.0, 0.0, 1.0],
            [-1.0, 1.0, 0.0, 1.0],
            [1.0, -1.0, 0.0, 1.0],
            [1.0, 1.0, 0.0, 1.0],
        ]
        let uvs: [simd_float2] = [
            [0.0, 1.0],
            [0.0, 0.0],
            [1.0, 1.0],
            [1.0, 0.0],
        ]
        return (indices, positions, uvs)
    }

    func set(encoder: MTLRenderCommandEncoder) {
        encoder.setFrontFacing(.clockwise)
        encoder.setVertexBuffer(posBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uvBuffer, offset: 0, index: 1)
        encoder.setVertexBuffer(matrixBuffer, offset: 0, index: 2)
        encoder.drawIndexedPrimitives(type: primitiveType, indexCount: indexCount, indexType: indexType, indexBuffer: indexBuffer, indexBufferOffset: 0)
    }
}

