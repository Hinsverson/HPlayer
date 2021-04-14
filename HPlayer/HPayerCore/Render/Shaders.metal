//
//  Shaders.metal
#include <metal_stdlib>
using namespace metal;

typedef struct {
    float4 renderedCoordinate [[position]];
    float2 textureCoordinate;
} TextureMappingVertex;

//顶点着色器函数，参数从VB从传过来，vertex_id内建属性表示当前顶点是哪一个buffer(0)表示第0个传参点，传参时个外部对应。
vertex TextureMappingVertex mapTexture(unsigned int vertex_id [[ vertex_id ]],
                                       constant float4 * pos [[ buffer(0) ]],
                                       constant float2 * uv [[ buffer(1) ]],
                                       constant float4x4& uniforms [[ buffer(2) ]]) {
    TextureMappingVertex outVertex;
    outVertex.renderedCoordinate = uniforms * pos[vertex_id];
    outVertex.textureCoordinate = uv[vertex_id];

    return outVertex;
}

fragment half4 displayTexture(TextureMappingVertex mappingVertex [[ stage_in ]],
                              texture2d<half, access::sample> texture [[ texture(0) ]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    return half4(texture.sample(s, mappingVertex.textureCoordinate));
}

fragment float4 displayYUVTexture(TextureMappingVertex in [[ stage_in ]],
                                  texture2d<float> yTexture [[ texture(0) ]],
                                  texture2d<float> uTexture [[ texture(1) ]],
                                  texture2d<float> vTexture [[ texture(2) ]],
                                  sampler textureSampler [[ sampler(0) ]],
                                  constant float3x3& yuvToRGBMatrix [[ buffer(0) ]],
                                  constant float3& colorOffset [[ buffer(1) ]])
{
    float3 yuv;
    yuv.x = yTexture.sample(textureSampler, in.textureCoordinate).r;
    yuv.y = uTexture.sample(textureSampler, in.textureCoordinate).r;
    yuv.z = vTexture.sample(textureSampler, in.textureCoordinate).r;
    return float4(yuvToRGBMatrix * (yuv+colorOffset), 1);
}


fragment float4 displayNV12Texture(TextureMappingVertex in [[ stage_in ]],
                                  texture2d<float> lumaTexture [[ texture(0) ]],
                                  texture2d<float> chromaTexture [[ texture(1) ]],
                                  sampler textureSampler [[ sampler(0) ]],
                                  constant float3x3& yuvToRGBMatrix [[ buffer(0) ]],
                                  constant float3& colorOffset [[ buffer(1) ]])
{
    float3 yuv;
    yuv.x = lumaTexture.sample(textureSampler, in.textureCoordinate).r;
    yuv.yz = chromaTexture.sample(textureSampler, in.textureCoordinate).rg;
    return float4(yuvToRGBMatrix * (yuv+colorOffset), 1);
}

