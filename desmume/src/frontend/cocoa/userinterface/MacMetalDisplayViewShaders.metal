/*
	Copyright (C) 2017 DeSmuME team
 
	This file is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 2 of the License, or
	(at your option) any later version.
 
	This file is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.
 
	You should have received a copy of the GNU General Public License
	along with the this software.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <metal_stdlib>
using namespace metal;

#define LANCZOS_FIX(c) max(abs(c), 1e-5)

struct HUDVtx
{
	float4 position [[position]];
	float2 texCoord;
	bool isBox;
	bool lowerHUDMipMapLevel;
};

struct DisplayVtx
{
	float4 position [[position]];
	float2 texCoord;
};

struct DisplayViewShaderProperties
{
	float width;
	float height;
	float rotation;
	float viewScale;
	uint lowerHUDMipMapLevel;
};

float reduce(const float3 color);
float4 unpack_unorm1555_to_unorm8888(const ushort color16);
float3 color_interpolate_LTE(const float3 pixA, const float3 pixB, const float3 threshold);
float4 bicubic_weight_bspline(const float x);
float4 bicubic_weight_mitchell_netravali(const float x);
float4 bicubic_weight_lanczos2(const float x);
float3 bicubic_weight_lanczos3(const float x);
float dist_EPXPlus(const float3 pixA, const float3 pixB);
float GetEagleResult(const float v1, const float v2, const float v3, const float v4);
float3 Lerp(const float3 weight, const float3 p1, const float3 p2, const float3 p3);
bool InterpDiff(const float3 p1, const float3 p2);
float DistYCbCr(const float3 pixA, const float3 pixB);
bool IsPixEqual(const float3 pixA, const float3 pixB);
bool IsBlendingNeeded(const int4 blend);

float3 nds_apply_master_brightness(const float3 inColor, const uchar mode, const float intensity);

constexpr sampler genSampler = sampler(coord::pixel, address::clamp_to_edge, filter::nearest);
constexpr sampler outputSamplerBilinear = sampler(coord::pixel, address::clamp_to_edge, filter::linear);

float reduce(const float3 color)
{
	return dot(color, float3(65536.0f, 256.0f, 1.0f));
}

float GetEagleResult(const float v1, const float v2, const float v3, const float v4)
{
	return sign(abs(v1-v3)+abs(v1-v4))-sign(abs(v2-v3)+abs(v2-v4));
}

float3 Lerp(const float3 weight, const float3 p1, const float3 p2, const float3 p3)
{
	return p1*weight.r + p2*weight.g + p3*weight.b;
}

bool InterpDiff(const float3 p1, const float3 p2)
{
	const float3 diff = p1 - p2;
	float3 yuv = float3( diff.r + diff.g + diff.b,
	                     diff.r - diff.b,
	                    -diff.r + (2.0f*diff.g) - diff.b );
	yuv = abs(yuv);
	
	return any( yuv > float3(192.0f/255.0f, 28.0f/255.0f, 48.0f/255.0f) );
}

float4 unpack_unorm1555_to_unorm8888(const ushort color16)
{
	return float4((float)((color16 >>  0) & 0x1F) / 31.0f,
				  (float)((color16 >>  5) & 0x1F) / 31.0f,
				  (float)((color16 >> 10) & 0x1F) / 31.0f,
				  (float)(color16 >> 16));
}

float3 color_interpolate_LTE(const float3 pixA, const float3 pixB, const float3 threshold)
{
	const float3 interpPix = mix(pixA, pixB, 0.5f);
	const float3 pixCompare = float3( abs(pixB - pixA) <= threshold );
	
	return mix(pixA, interpPix, pixCompare);
}

float4 bicubic_weight_bspline(const float x)
{
	return float4( ((1.0f-x)*(1.0f-x)*(1.0f-x)) / 6.0f,
				   (4.0f - 6.0f*x*x + 3.0f*x*x*x) / 6.0f,
				   (1.0f + 3.0f*x + 3.0f*x*x - 3.0f*x*x*x) / 6.0f,
				   x*x*x / 6.0f );
}

float4 bicubic_weight_mitchell_netravali(const float x)
{
	return float4( (1.0f - 9.0f*x + 15.0f*x*x - 7.0f*x*x*x) / 18.0f,
				   (16.0f - 36.0f*x*x + 21.0f*x*x*x) / 18.0f,
				   (1.0f + 9.0f*x + 27.0f*x*x - 21.0f*x*x*x) / 18.0f,
				   (7.0f*x*x*x - 6.0f*x*x) / 18.0f );
}

float4 bicubic_weight_lanczos2(const float x)
{
	constexpr float RADIUS = 2.0f;
	const float4 sample = LANCZOS_FIX(M_PI_F * float4(1.0f + x, x, 1.0f - x, 2.0f - x));
	return ( sin(sample) * sin(sample / RADIUS) / (sample * sample) );
}

float3 bicubic_weight_lanczos3(const float x)
{
	constexpr float RADIUS = 3.0f;
	const float3 sample = LANCZOS_FIX(2.0f * M_PI_F * float3(x - 1.5f, x - 0.5f, x + 0.5f));
	return ( sin(sample) * sin(sample / RADIUS) / (sample * sample) );
}

float dist_EPXPlus(const float3 pixA, const float3 pixB)
{
	return dot(abs(pixA - pixB), float3(2.0f, 3.0f, 3.0f));
}

#pragma mark HUD Shader Functions

vertex HUDVtx hud_vertex(const device float2 *inPosition [[buffer(0)]],
						 const device float2 *inTexCoord [[buffer(1)]],
						 const constant DisplayViewShaderProperties &viewProps [[buffer(2)]],
						 const uint vid [[vertex_id]])
{
	const float2x2 projection	= float2x2(	float2(2.0/viewProps.width,                   0.0),
	                                        float2(                0.0, 2.0/viewProps.height));
	
	HUDVtx outVtx;
	outVtx.position = float4(projection * inPosition[vid], 0.0, 1.0);
	outVtx.texCoord = inTexCoord[vid];
	outVtx.isBox = (vid < 4);
	outVtx.lowerHUDMipMapLevel = (viewProps.lowerHUDMipMapLevel == 1);
	
	return outVtx;
}

fragment float4 hud_fragment(const HUDVtx vtx [[stage_in]],
							 const texture2d<float> tex [[texture(0)]],
							 const sampler samp [[sampler(0)]])
{
	return tex.sample(samp, vtx.texCoord, (vtx.lowerHUDMipMapLevel) ? level(-0.50f) : level(0.00f));
}

#pragma mark Output Filters

vertex DisplayVtx display_output_vertex(const device float2 *inPosition [[buffer(0)]],
										const device float2 *inTexCoord [[buffer(1)]],
										const constant DisplayViewShaderProperties &viewProps [[buffer(2)]],
										const uint vid [[vertex_id]])
{
	const float angleRadians    = viewProps.rotation * (M_PI_F/180.0);
	
	const float2x2 projection   = float2x2(	float2(2.0/viewProps.width,                  0.0),
	                                        float2(                0.0, 2.0/viewProps.height));
	
	const float2x2 rotation     = float2x2(	float2( cos(angleRadians), sin(angleRadians)),
	                                        float2(-sin(angleRadians), cos(angleRadians)));
	
	const float2x2 scale        = float2x2(	float2(viewProps.viewScale,                 0.0),
	                                        float2(                0.0, viewProps.viewScale));
	
	DisplayVtx outVtx;
	outVtx.position = float4(projection * rotation * scale * inPosition[vid], 0.0, 1.0);
	outVtx.texCoord = inTexCoord[vid];
	
	return outVtx;
}

vertex DisplayVtx display_output_bicubic_vertex(const device float2 *inPosition [[buffer(0)]],
												const device float2 *inTexCoord [[buffer(1)]],
												const constant DisplayViewShaderProperties &viewProps [[buffer(2)]],
												const uint vid [[vertex_id]])
{
	const float angleRadians    = viewProps.rotation * (M_PI_F/180.0);
	
	const float2x2 projection   = float2x2(	float2(2.0/viewProps.width,                  0.0),
	                                        float2(                0.0, 2.0/viewProps.height));
	
	const float2x2 rotation     = float2x2(	float2( cos(angleRadians), sin(angleRadians)),
	                                        float2(-sin(angleRadians), cos(angleRadians)));
	
	const float2x2 scale        = float2x2(	float2(viewProps.viewScale,                 0.0),
	                                        float2(                0.0, viewProps.viewScale));
	
	DisplayVtx outVtx;
	outVtx.position = float4(projection * rotation * scale * inPosition[vid], 0.0, 1.0);
	outVtx.texCoord = floor(inTexCoord[vid] - 0.5f) + 0.5f;
	
	return outVtx;
}

//---------------------------------------
// Input Pixel Mapping:  00
fragment float4 output_filter_nearest(const DisplayVtx vtx [[stage_in]], const texture2d<float> tex [[texture(0)]])
{
	return tex.sample(genSampler, vtx.texCoord);
}

//---------------------------------------
// Input Pixel Mapping:  00|01
//                       02|03
fragment float4 output_filter_bilinear(const DisplayVtx vtx [[stage_in]], const texture2d<float> tex [[texture(0)]])
{
	return tex.sample(outputSamplerBilinear, vtx.texCoord);
}

//---------------------------------------
// Input Pixel Mapping:  00|01|02|03
//                       04|05|06|07
//                       08|09|10|11
//                       12|13|14|15
fragment float4 output_filter_bicubic_bspline(const DisplayVtx vtx [[stage_in]], const texture2d<float> tex [[texture(0)]])
{
	float2 f = fract(vtx.texCoord);
	float4 wx = bicubic_weight_bspline(f.x);
	float4 wy = bicubic_weight_bspline(f.y);
	
	// Normalize weights
	wx /= dot(wx, float4(1.0f));
	wy /= dot(wy, float4(1.0f));
	
	float4 outFragment	=   (tex.sample(genSampler, vtx.texCoord, int2(-1,-1)) * wx.r
						  +  tex.sample(genSampler, vtx.texCoord, int2( 0,-1)) * wx.g
						  +  tex.sample(genSampler, vtx.texCoord, int2( 1,-1)) * wx.b
						  +  tex.sample(genSampler, vtx.texCoord, int2( 2,-1)) * wx.a) * wy.r
						  + (tex.sample(genSampler, vtx.texCoord, int2(-1, 0)) * wx.r
						  +  tex.sample(genSampler, vtx.texCoord, int2( 0, 0)) * wx.g
						  +  tex.sample(genSampler, vtx.texCoord, int2( 1, 0)) * wx.b
						  +  tex.sample(genSampler, vtx.texCoord, int2( 2, 0)) * wx.a) * wy.g
						  + (tex.sample(genSampler, vtx.texCoord, int2(-1, 1)) * wx.r
						  +  tex.sample(genSampler, vtx.texCoord, int2( 0, 1)) * wx.g
						  +  tex.sample(genSampler, vtx.texCoord, int2( 1, 1)) * wx.b
						  +  tex.sample(genSampler, vtx.texCoord, int2( 2, 1)) * wx.a) * wy.b
						  + (tex.sample(genSampler, vtx.texCoord, int2(-1, 2)) * wx.r
						  +  tex.sample(genSampler, vtx.texCoord, int2( 0, 2)) * wx.g
						  +  tex.sample(genSampler, vtx.texCoord, int2( 1, 2)) * wx.b
						  +  tex.sample(genSampler, vtx.texCoord, int2( 2, 2)) * wx.a) * wy.a;
	
	return float4(outFragment.rgb, 1.0f);
}

//---------------------------------------
// Input Pixel Mapping:  00|01|02|03
//                       04|05|06|07
//                       08|09|10|11
//                       12|13|14|15
fragment float4 output_filter_bicubic_mitchell_netravali(const DisplayVtx vtx [[stage_in]], const texture2d<float> tex [[texture(0)]])
{
	float2 f = fract(vtx.texCoord);
	float4 wx = bicubic_weight_mitchell_netravali(f.x);
	float4 wy = bicubic_weight_mitchell_netravali(f.y);
	
	// Normalize weights
	wx /= dot(wx, float4(1.0f));
	wy /= dot(wy, float4(1.0f));
	
	float4 outFragment	=   (tex.sample(genSampler, vtx.texCoord, int2(-1,-1)) * wx.r
						  +  tex.sample(genSampler, vtx.texCoord, int2( 0,-1)) * wx.g
						  +  tex.sample(genSampler, vtx.texCoord, int2( 1,-1)) * wx.b
						  +  tex.sample(genSampler, vtx.texCoord, int2( 2,-1)) * wx.a) * wy.r
						  + (tex.sample(genSampler, vtx.texCoord, int2(-1, 0)) * wx.r
						  +  tex.sample(genSampler, vtx.texCoord, int2( 0, 0)) * wx.g
						  +  tex.sample(genSampler, vtx.texCoord, int2( 1, 0)) * wx.b
						  +  tex.sample(genSampler, vtx.texCoord, int2( 2, 0)) * wx.a) * wy.g
						  + (tex.sample(genSampler, vtx.texCoord, int2(-1, 1)) * wx.r
						  +  tex.sample(genSampler, vtx.texCoord, int2( 0, 1)) * wx.g
						  +  tex.sample(genSampler, vtx.texCoord, int2( 1, 1)) * wx.b
						  +  tex.sample(genSampler, vtx.texCoord, int2( 2, 1)) * wx.a) * wy.b
						  + (tex.sample(genSampler, vtx.texCoord, int2(-1, 2)) * wx.r
						  +  tex.sample(genSampler, vtx.texCoord, int2( 0, 2)) * wx.g
						  +  tex.sample(genSampler, vtx.texCoord, int2( 1, 2)) * wx.b
						  +  tex.sample(genSampler, vtx.texCoord, int2( 2, 2)) * wx.a) * wy.a;
	
	return float4(outFragment.rgb, 1.0f);
}

//---------------------------------------
// Input Pixel Mapping:  00|01|02|03
//                       04|05|06|07
//                       08|09|10|11
//                       12|13|14|15
fragment float4 output_filter_lanczos2(const DisplayVtx vtx [[stage_in]], const texture2d<float> tex [[texture(0)]])
{
	const float2 f = fract(vtx.texCoord);
	float4 wx = bicubic_weight_lanczos2(f.x);
	float4 wy = bicubic_weight_lanczos2(f.y);
	
	// Normalize weights
	wx /= dot(wx, float4(1.0f));
	wy /= dot(wy, float4(1.0f));
	
	const float4 outFragment	= (tex.sample(genSampler, vtx.texCoord, int2(-1,-1)) * wx.r
								+  tex.sample(genSampler, vtx.texCoord, int2( 0,-1)) * wx.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 1,-1)) * wx.b
								+  tex.sample(genSampler, vtx.texCoord, int2( 2,-1)) * wx.a) * wy.r
								+ (tex.sample(genSampler, vtx.texCoord, int2(-1, 0)) * wx.r
								+  tex.sample(genSampler, vtx.texCoord, int2( 0, 0)) * wx.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 1, 0)) * wx.b
								+  tex.sample(genSampler, vtx.texCoord, int2( 2, 0)) * wx.a) * wy.g
								+ (tex.sample(genSampler, vtx.texCoord, int2(-1, 1)) * wx.r
								+  tex.sample(genSampler, vtx.texCoord, int2( 0, 1)) * wx.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 1, 1)) * wx.b
								+  tex.sample(genSampler, vtx.texCoord, int2( 2, 1)) * wx.a) * wy.b
								+ (tex.sample(genSampler, vtx.texCoord, int2(-1, 2)) * wx.r
								+  tex.sample(genSampler, vtx.texCoord, int2( 0, 2)) * wx.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 1, 2)) * wx.b
								+  tex.sample(genSampler, vtx.texCoord, int2( 2, 2)) * wx.a) * wy.a;
	
	return float4(outFragment.rgb, 1.0f);
}

//---------------------------------------
// Input Pixel Mapping: 00|01|02|03|04|05
//                      06|07|08|09|10|11
//                      12|13|14|15|16|17
//                      18|19|20|21|22|23
//                      24|25|26|27|28|29
//                      30|31|32|33|34|35
fragment float4 output_filter_lanczos3(const DisplayVtx vtx [[stage_in]], const texture2d<float> tex [[texture(0)]])
{
	const float2 f = fract(vtx.texCoord);
	float3 wx1 = bicubic_weight_lanczos3(0.5f - f.x * 0.5f);
	float3 wx2 = bicubic_weight_lanczos3(1.0f - f.x * 0.5f);
	float3 wy1 = bicubic_weight_lanczos3(0.5f - f.y * 0.5f);
	float3 wy2 = bicubic_weight_lanczos3(1.0f - f.y * 0.5f);
	
	// Normalize weights
	const float sumX = dot(wx1, float3(1.0f)) + dot(wx2, float3(1.0f));
	const float sumY = dot(wy1, float3(1.0f)) + dot(wy2, float3(1.0f));
	wx1 /= sumX;
	wx2 /= sumX;
	wy1 /= sumY;
	wy2 /= sumY;
	
	const float4 outFragment	= (tex.sample(genSampler, vtx.texCoord, int2(-2,-2)) * wx1.r
								+  tex.sample(genSampler, vtx.texCoord, int2(-1,-2)) * wx2.r
								+  tex.sample(genSampler, vtx.texCoord, int2( 0,-2)) * wx1.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 1,-2)) * wx2.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 2,-2)) * wx1.b
								+  tex.sample(genSampler, vtx.texCoord, int2( 3,-2)) * wx2.b) * wy1.r
								+ (tex.sample(genSampler, vtx.texCoord, int2(-2,-1)) * wx1.r
								+  tex.sample(genSampler, vtx.texCoord, int2(-1,-1)) * wx2.r
								+  tex.sample(genSampler, vtx.texCoord, int2( 0,-1)) * wx1.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 1,-1)) * wx2.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 2,-1)) * wx1.b
								+  tex.sample(genSampler, vtx.texCoord, int2( 3,-1)) * wx2.b) * wy2.r
								+ (tex.sample(genSampler, vtx.texCoord, int2(-2, 0)) * wx1.r
								+  tex.sample(genSampler, vtx.texCoord, int2(-1, 0)) * wx2.r
								+  tex.sample(genSampler, vtx.texCoord, int2( 0, 0)) * wx1.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 1, 0)) * wx2.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 2, 0)) * wx1.b
								+  tex.sample(genSampler, vtx.texCoord, int2( 3, 0)) * wx2.b) * wy1.g
								+ (tex.sample(genSampler, vtx.texCoord, int2(-2, 1)) * wx1.r
								+  tex.sample(genSampler, vtx.texCoord, int2(-1, 1)) * wx2.r
								+  tex.sample(genSampler, vtx.texCoord, int2( 0, 1)) * wx1.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 1, 1)) * wx2.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 2, 1)) * wx1.b
								+  tex.sample(genSampler, vtx.texCoord, int2( 3, 1)) * wx2.b) * wy2.g
								+ (tex.sample(genSampler, vtx.texCoord, int2(-2, 2)) * wx1.r
								+  tex.sample(genSampler, vtx.texCoord, int2(-1, 2)) * wx2.r
								+  tex.sample(genSampler, vtx.texCoord, int2( 0, 2)) * wx1.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 1, 2)) * wx2.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 2, 2)) * wx1.b
								+  tex.sample(genSampler, vtx.texCoord, int2( 3, 2)) * wx2.b) * wy1.b
								+ (tex.sample(genSampler, vtx.texCoord, int2(-2, 3)) * wx1.r
								+  tex.sample(genSampler, vtx.texCoord, int2(-1, 3)) * wx2.r
								+  tex.sample(genSampler, vtx.texCoord, int2( 0, 3)) * wx1.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 1, 3)) * wx2.g
								+  tex.sample(genSampler, vtx.texCoord, int2( 2, 3)) * wx1.b
								+  tex.sample(genSampler, vtx.texCoord, int2( 3, 3)) * wx2.b) * wy2.b;
	
	return float4(outFragment.rgb, 1.0f);
}

#pragma mark NDS Emulation Functions

kernel void nds_fetch555(const uint2 position [[thread_position_in_grid]],
						 const constant uchar *brightnessMode [[buffer(0)]],
						 const constant uchar *brightnessIntensity [[buffer(1)]],
						 const texture2d<ushort, access::read> inTexture [[texture(0)]],
						 texture2d<float, access::write> outTexture [[texture(1)]])
{
	const uint h = inTexture.get_height();
	
	if ( (position.x > inTexture.get_width() - 1) || (position.y > h - 1) )
	{
		return;
	}
	
	const float4 inColor = unpack_unorm1555_to_unorm8888( (ushort)inTexture.read(position).r );
	float3 outColor = inColor.rgb;
	
	const uint line = uint(((float)position.y + 0.01f) / ((float)h / 192.0f));
	outColor = nds_apply_master_brightness(outColor, brightnessMode[line], (float)brightnessIntensity[line] / 16.0f);
	
	outTexture.write(float4(outColor, 1.0f), position);
}

kernel void nds_fetch555ConvertOnly(const uint2 position [[thread_position_in_grid]],
									const texture2d<ushort, access::read> inTexture [[texture(0)]],
									texture2d<float, access::write> outTexture [[texture(1)]])
{
	if ( (position.x > inTexture.get_width() - 1) || (position.y > inTexture.get_height() - 1) )
	{
		return;
	}
	
	const float4 outColor = unpack_unorm1555_to_unorm8888( (ushort)inTexture.read(position).r );
	outTexture.write(float4(outColor.rgb, 1.0f), position);
}

kernel void nds_fetch666(const uint2 position [[thread_position_in_grid]],
						 const constant uchar *brightnessMode [[buffer(0)]],
						 const constant uchar *brightnessIntensity [[buffer(1)]],
						 const texture2d<float, access::read> inTexture [[texture(0)]],
						 texture2d<float, access::write> outTexture [[texture(1)]])
{
	const uint h = inTexture.get_height();
	
	if ( (position.x > inTexture.get_width() - 1) || (position.y > h - 1) )
	{
		return;
	}
	
	const float4 inColor = inTexture.read(position);
	float3 outColor = inColor.rgb * float3(255.0f/63.0f);
	
	const uint line = uint(((float)position.y + 0.01f) / ((float)h / 192.0f));
	outColor = nds_apply_master_brightness(outColor, brightnessMode[line], (float)brightnessIntensity[line] / 16.0f);
	
	outTexture.write(float4(outColor, 1.0f), position);
}

kernel void nds_fetch888(const uint2 position [[thread_position_in_grid]],
						 const constant uchar *brightnessMode [[buffer(0)]],
						 const constant uchar *brightnessIntensity [[buffer(1)]],
						 const texture2d<float, access::read> inTexture [[texture(0)]],
						 texture2d<float, access::write> outTexture [[texture(1)]])
{
	const uint h = inTexture.get_height();
	
	if ( (position.x > inTexture.get_width() - 1) || (position.y > h - 1) )
	{
		return;
	}
	
	const float4 inColor = inTexture.read(position);
	float3 outColor = inColor.rgb;
	
	const uint line = uint(((float)position.y + 0.01f) / ((float)h / 192.0f));
	outColor = nds_apply_master_brightness(outColor, brightnessMode[line], (float)brightnessIntensity[line] / 16.0f);
	
	outTexture.write(float4(outColor, 1.0f), position);
}

float3 nds_apply_master_brightness(const float3 inColor, const uchar mode, const float intensity)
{
	switch (mode)
	{
		case 1:
			return (inColor + ((1.0f - inColor) * intensity));
			break;
			
		case 2:
			return (inColor - (inColor * intensity));
			break;
			
		default:
			break;
	}
	
	return inColor;
}

#pragma mark Source Filters

//---------------------------------------
// Input Pixel Mapping:  00|01|02
//                       03|04|05
//                       06|07|08
//
// Output Pixel Mapping:    00
kernel void src_filter_deposterize(const uint2 position [[thread_position_in_grid]],
								   const texture2d<float, access::sample> inTexture [[texture(0)]],
								   texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src[9] = {
		inTexture.sample(genSampler, float2(position), int2( 0, 0)).rgb,
		inTexture.sample(genSampler, float2(position), int2( 1, 0)).rgb,
		inTexture.sample(genSampler, float2(position), int2( 1, 1)).rgb,
		inTexture.sample(genSampler, float2(position), int2( 0, 1)).rgb,
		inTexture.sample(genSampler, float2(position), int2(-1, 1)).rgb,
		inTexture.sample(genSampler, float2(position), int2(-1, 0)).rgb,
		inTexture.sample(genSampler, float2(position), int2(-1,-1)).rgb,
		inTexture.sample(genSampler, float2(position), int2( 0,-1)).rgb,
		inTexture.sample(genSampler, float2(position), int2( 1,-1)).rgb
	};
	
	const float3 threshold = float3(0.1020);
	const float2 weight = float2(0.90, 0.90 * 0.60);
	
	const float3 blend[9] = {
		src[0],
		color_interpolate_LTE(src[0], src[1], threshold),
		color_interpolate_LTE(src[0], src[2], threshold),
		color_interpolate_LTE(src[0], src[3], threshold),
		color_interpolate_LTE(src[0], src[4], threshold),
		color_interpolate_LTE(src[0], src[5], threshold),
		color_interpolate_LTE(src[0], src[6], threshold),
		color_interpolate_LTE(src[0], src[7], threshold),
		color_interpolate_LTE(src[0], src[8], threshold)
	};
	
	const float3 outColor =	mix(
								mix(
									mix(
										mix(blend[0], blend[5], weight[0]), mix(blend[0], blend[1], weight[0]),
									0.50f),
									mix(
										mix(blend[0], blend[7], weight[0]), mix(blend[0], blend[3], weight[0]),
									0.50f),
								0.50f),
								mix(
									mix(
										mix(blend[0], blend[6], weight[1]), mix(blend[0], blend[2], weight[1]),
									0.50f),
									mix(
										mix(blend[0], blend[8], weight[1]), mix(blend[0], blend[4], weight[1]),
									0.50f),
								0.50f),
							0.25f);
	
	outTexture.write( float4(outColor, 1.0f), position );
}

#pragma mark Pixel Scalers

//---------------------------------------
// Input Pixel Mapping:  00
//
// Output Pixel Mapping: 00|01
//                       02|03
kernel void pixel_scaler_nearest2x(const uint2 inPosition [[thread_position_in_grid]],
								   const texture2d<float, access::read> inTexture [[texture(0)]],
								   texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src = inTexture.read(inPosition).rgb;
	const float4 dst = float4(src, 1.0f);
	
	const uint2 outPosition = inPosition * 2;
	outTexture.write( dst, outPosition + uint2(0, 0) );
	outTexture.write( dst, outPosition + uint2(1, 0) );
	outTexture.write( dst, outPosition + uint2(0, 1) );
	outTexture.write( dst, outPosition + uint2(1, 1) );
}

//---------------------------------------
// Input Pixel Mapping:  00
//
// Output Pixel Mapping: 00|01
//                       02|03
kernel void pixel_scaler_scanline(const uint2 inPosition [[thread_position_in_grid]],
								  const texture2d<float, access::read> inTexture [[texture(0)]],
								  texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src = inTexture.read(inPosition).rgb;
	const uint2 outPosition = inPosition * 2;
	
	outTexture.write( float4(src * 1.000f, 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(src * 0.875f, 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(src * 0.875f, 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(src * 0.750f, 1.0f), outPosition + uint2(1, 1) );
}

//---------------------------------------
// Input Pixel Mapping:  --|07|--
//                       05|00|01
//                       --|03|--
//
// Output Pixel Mapping:  00|01
//                        02|03
kernel void pixel_scaler_2xEPX(const uint2 inPosition [[thread_position_in_grid]],
							   const texture2d<float, access::sample> inTexture [[texture(0)]],
							   texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src0 = inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb;
	const float3 src1 = inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb;
	const float3 src3 = inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb;
	const float3 src5 = inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb;
	const float3 src7 = inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb;
	
	const float v7 = reduce(src7);
	const float v5 = reduce(src5);
	const float v1 = reduce(src1);
	const float v3 = reduce(src3);
	
	const bool pixCompare = (v5 != v1) && (v7 != v3);
	
	const float3 dst[4] = {
		(pixCompare && (v7 == v5)) ? src7 : src0,
		(pixCompare && (v1 == v7)) ? src1 : src0,
		(pixCompare && (v5 == v3)) ? src5 : src0,
		(pixCompare && (v3 == v1)) ? src3 : src0
	};
	
	const uint2 outPosition = inPosition * 2;
	outTexture.write( float4(dst[0], 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(dst[1], 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(dst[2], 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(dst[3], 1.0f), outPosition + uint2(1, 1) );
}

//---------------------------------------
// Input Pixel Mapping:  --|07|--
//                       05|00|01
//                       --|03|--
//
// Output Pixel Mapping:  00|01
//                        02|03
kernel void pixel_scaler_2xEPXPlus(const uint2 inPosition [[thread_position_in_grid]],
								   const texture2d<float, access::sample> inTexture [[texture(0)]],
								   texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src0 = inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb;
	const float3 src1 = inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb;
	const float3 src3 = inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb;
	const float3 src5 = inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb;
	const float3 src7 = inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb;
	
	const float3 dst[4] = {
		( dist_EPXPlus(src5, src7) < min(dist_EPXPlus(src5, src3), dist_EPXPlus(src1, src7)) ) ? mix(src5, src7, 0.5f) : src0,
		( dist_EPXPlus(src1, src7) < min(dist_EPXPlus(src5, src7), dist_EPXPlus(src1, src3)) ) ? mix(src1, src7, 0.5f) : src0,
		( dist_EPXPlus(src5, src3) < min(dist_EPXPlus(src5, src7), dist_EPXPlus(src1, src3)) ) ? mix(src5, src3, 0.5f) : src0,
		( dist_EPXPlus(src1, src3) < min(dist_EPXPlus(src5, src3), dist_EPXPlus(src1, src7)) ) ? mix(src1, src3, 0.5f) : src0
	};
	
	const uint2 outPosition = inPosition * 2;
	outTexture.write( float4(dst[0], 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(dst[1], 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(dst[2], 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(dst[3], 1.0f), outPosition + uint2(1, 1) );
}

//---------------------------------------
// Input Pixel Mapping:  00|01|02|03
//                       04|05|06|07
//                       08|09|10|11
//                       12|13|14|15
//
// Output Pixel Mapping:    00|01
//                          02|03
//
//---------------------------------------
// 2xSaI Pixel Mapping:    I|E|F|J
//                         G|A|B|K
//                         H|C|D|L
//                         M|N|O|P
kernel void pixel_scaler_2xSaI(const uint2 inPosition [[thread_position_in_grid]],
							   const texture2d<float, access::sample> inTexture [[texture(0)]],
							   texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float  Iv = reduce( inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb );
	const float  Ev = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb );
	const float  Fv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb );
	const float  Jv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 2,-1)).rgb );
	
	const float  Gv = reduce( inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb );
	const float3 Ac = inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb; const float Av = reduce(Ac);
	const float3 Bc = inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb; const float Bv = reduce(Bc);
	const float  Kv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 2, 0)).rgb );
	
	const float  Hv = reduce( inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb );
	const float3 Cc = inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb; const float Cv = reduce(Cc);
	const float3 Dc = inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb; const float Dv = reduce(Dc);
	const float  Lv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 2, 1)).rgb );
	
	const float  Mv = reduce( inTexture.sample(genSampler, float2(inPosition), int2(-1, 2)).rgb );
	const float  Nv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 0, 2)).rgb );
	const float  Ov = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 1, 2)).rgb );
	// Pv is unused, so skip this one.
	
	const bool compAD = (Av == Dv);
	const bool compBC = (Bv == Cv);
	
	float3 dst[4] = { Ac, Ac, Ac, Ac };
	
	if (compAD && !compBC)
	{
		dst[1] = ((Av == Ev) && (Bv == Lv)) || ((Av == Cv) && (Av == Fv) && (Bv != Ev) && (Bv == Jv)) ? Ac : mix(Ac, Bc, 0.5f);
		dst[2] = ((Av == Gv) && (Cv == Ov)) || ((Av == Bv) && (Av == Hv) && (Cv != Gv) && (Cv == Mv)) ? Ac : mix(Ac, Cc, 0.5f);
	}
	else if (!compAD && compBC)
	{
		dst[1] = ((Bv == Fv) && (Av == Hv)) || ((Bv == Ev) && (Bv == Dv) && (Av != Fv) && (Av == Iv)) ? Bc : mix(Ac, Bc, 0.5f);
		dst[2] = ((Cv == Hv) && (Av == Fv)) || ((Cv == Gv) && (Cv == Dv) && (Av != Hv) && (Av == Iv)) ? Cc : mix(Ac, Cc, 0.5f);
		dst[3] = Bc;
	}
	else if (compAD && compBC)
	{
		dst[1] = (Av == Bv) ? Ac : mix(Ac, Bc, 0.5f);
		dst[2] = (Av == Bv) ? Ac : mix(Ac, Cc, 0.5f);
		
		const float r = (Av == Bv) ? 1.0f : GetEagleResult(Av, Bv, Gv, Ev) - GetEagleResult(Bv, Av, Kv, Fv) - GetEagleResult(Bv, Av, Hv, Nv) + GetEagleResult(Av, Bv, Lv, Ov);
		dst[3] = (r > 0.0f) ? Ac : ( (r < 0.0f) ? Bc : mix( mix(Ac, Bc, 0.5f), mix(Cc, Dc, 0.5f), 0.5f) );
	}
	else
	{
		dst[1] = ((Av == Cv) && (Av == Fv) && (Bv != Ev) && (Bv == Jv)) ? Ac : ( ((Bv == Ev) && (Bv == Dv) && (Av != Fv) && (Av == Iv)) ? Bc : mix(Ac, Bc, 0.5f) );
		dst[2] = ((Av == Bv) && (Av == Hv) && (Cv != Gv) && (Cv == Mv)) ? Ac : ( ((Cv == Gv) && (Cv == Dv) && (Av != Hv) && (Av == Iv)) ? Cc : mix(Ac, Cc, 0.5f) );
		dst[3] = mix( mix(Ac, Bc, 0.5f), mix(Cc, Dc, 0.5f), 0.5f );
	}
	
	const uint2 outPosition = inPosition * 2;
	outTexture.write( float4(dst[0], 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(dst[1], 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(dst[2], 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(dst[3], 1.0f), outPosition + uint2(1, 1) );
}

//---------------------------------------
// Input Pixel Mapping:  00|01|02|03
//                       04|05|06|07
//                       08|09|10|11
//                       12|13|14|15
//
// Output Pixel Mapping:    00|01
//                          02|03
//
//---------------------------------------
// S2xSaI Pixel Mapping:   I|E|F|J
//                         G|A|B|K
//                         H|C|D|L
//                         M|N|O|P
kernel void pixel_scaler_Super2xSaI(const uint2 inPosition [[thread_position_in_grid]],
									const texture2d<float, access::sample> inTexture [[texture(0)]],
									texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float  Iv = reduce( inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb );
	const float  Ev = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb );
	const float  Fv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb );
	const float  Jv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 2,-1)).rgb );
	
	const float  Gv = reduce( inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb );
	const float3 Ac = inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb; const float Av = reduce(Ac);
	const float3 Bc = inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb; const float Bv = reduce(Bc);
	const float  Kv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 2, 0)).rgb );
	
	const float  Hv = reduce( inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb );
	const float3 Cc = inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb; const float Cv = reduce(Cc);
	const float3 Dc = inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb; const float Dv = reduce(Dc);
	const float  Lv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 2, 1)).rgb );
	
	const float  Mv = reduce( inTexture.sample(genSampler, float2(inPosition), int2(-1, 2)).rgb );
	const float  Nv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 0, 2)).rgb );
	const float  Ov = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 1, 2)).rgb );
	const float  Pv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 2, 2)).rgb );
	
	const bool compAD = (Av == Dv);
	const bool compBC = (Bv == Cv);
	
	float3 dst[4];
	dst[0] = ( (compBC && !compAD && (Hv == Cv) && (Cv != Fv)) || ((Gv == Cv) && (Dv == Cv) && (Hv != Av) && (Cv != Iv)) ) ? mix(Ac, Cc, 0.5f) : Ac;
	dst[1] = Bc;
	dst[2] = ( (compAD && !compBC && (Gv == Av) && (Av != Ov)) || ((Av == Hv) && (Av == Bv) && (Gv != Cv) && (Av != Mv)) ) ? mix(Ac, Cc, 0.5f) : Cc;
	dst[3] = Dc;
	
	if (compBC && !compAD)
	{
		dst[1] = dst[3] = Cc;
	}
	else if (!compBC && compAD)
	{
		dst[1] = dst[3] = Ac;
	}
	else if (compBC && compAD)
	{
		const float r = GetEagleResult(Bv, Av, Hv, Nv) + GetEagleResult(Bv, Av, Gv, Ev) + GetEagleResult(Bv, Av, Ov, Lv) + GetEagleResult(Bv, Av, Fv, Kv);
		dst[1] = dst[3] = (r > 0.0f) ? Bc : ( (r < 0.0f) ? Ac : mix(Ac, Bc, 0.5f) );
	}
	else
	{
		dst[1] = ( (Bv == Dv) && (Bv == Ev) && (Av != Fv) && (Bv != Iv) ) ? mix(Ac, Bc, 0.75f) : ( ( (Av == Cv) && (Av == Fv) && (Ev != Bv) && (Av != Jv) ) ? mix(Ac, Bc, 0.25f) : mix(Ac, Bc, 0.5f) );
		dst[3] = ( (Bv == Dv) && (Dv == Nv) && (Cv != Ov) && (Dv != Mv) ) ? mix(Cc, Dc, 0.75f) : ( ( (Av == Cv) && (Cv == Ov) && (Nv != Dv) && (Cv != Pv) ) ? mix(Cc, Dc, 0.25f) : mix(Cc, Dc, 0.5f) );
	}
	
	const uint2 outPosition = inPosition * 2;
	outTexture.write( float4(dst[0], 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(dst[1], 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(dst[2], 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(dst[3], 1.0f), outPosition + uint2(1, 1) );
}

//---------------------------------------
// Input Pixel Mapping:  --|01|02|--
//                       04|05|06|07
//                       08|09|10|11
//                       --|13|14|--
//
// Output Pixel Mapping:    00|01
//                          02|03
//
//---------------------------------------
// SEagle Pixel Mapping:   -|E|F|-
//                         G|A|B|K
//                         H|C|D|L
//                         -|N|O|-
kernel void pixel_scaler_2xSuperEagle(const uint2 inPosition [[thread_position_in_grid]],
									  const texture2d<float, access::sample> inTexture [[texture(0)]],
									  texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float  Ev = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb );
	const float  Fv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb );
	
	const float  Gv = reduce( inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb );
	const float3 Ac = inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb; const float Av = reduce(Ac);
	const float3 Bc = inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb; const float Bv = reduce(Bc);
	const float  Kv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 2, 0)).rgb );
	
	const float  Hv = reduce( inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb );
	const float3 Cc = inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb; const float Cv = reduce(Cc);
	const float3 Dc = inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb; const float Dv = reduce(Dc);
	const float  Lv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 2, 1)).rgb );
	
	const float  Nv = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 0, 2)).rgb );
	const float  Ov = reduce( inTexture.sample(genSampler, float2(inPosition), int2( 1, 2)).rgb );
	
	const bool compAD = (Av == Dv);
	const bool compBC = (Bv == Cv);
	
	float3 dst[4] = { Ac, Bc, Cc, Dc };
	
	if (compBC && !compAD)
	{
		dst[0] = (Cv == Hv || Bv == Fv) ? mix(Ac, Cc, 0.75f) : mix(Ac, Bc, 0.5f);
		dst[1] = Cc;
		//dst[2] = Cc;
		dst[3] = mix( mix(Dc, Cc, 0.5f), mix(Dc, Cc, 0.75f), float(Bv == Kv || Cv == Nv) );
	}
	else if (!compBC && compAD)
	{
		//dst[0] = Ac;
		dst[1] = mix( mix(Ac, Bc, 0.5f), mix(Ac, Bc, 0.25f), float(Av == Ev || Dv == Lv) );
		dst[2] = mix( mix(Cc, Dc, 0.5f), mix(Ac, Cc, 0.25f), float(Dv == Ov || Av == Gv) );
		dst[3] = Ac;
	}
	else if (compBC && compAD)
	{
		const float r = GetEagleResult(Bv, Av, Hv, Nv) + GetEagleResult(Bv, Av, Gv, Ev) + GetEagleResult(Bv, Av, Ov, Lv) + GetEagleResult(Bv, Av, Fv, Kv);
		if (r > 0.0f)
		{
			dst[0] = mix(Ac, Bc, 0.5f);
			dst[1] = Cc;
			//dst[2] = Cc;
			dst[3] = dst[0];
		}
		else if (r < 0.0f)
		{
			//dst[0] = Ac;
			dst[1] = mix(Ac, Bc, 0.5f);
			dst[2] = dst[1];
			dst[3] = Ac;
		}
		else
		{
			//dst[0] = Ac;
			dst[1] = Cc;
			//dst[2] = Cc;
			dst[3] = Ac;
		}
	}
	else
	{
		dst[0] = mix(mix(Bc, Cc, 0.5f), Ac, 0.75f);
		dst[1] = mix(mix(Ac, Dc, 0.5f), Bc, 0.75f);
		dst[2] = mix(mix(Ac, Dc, 0.5f), Cc, 0.75f);
		dst[3] = mix(mix(Bc, Cc, 0.5f), Dc, 0.75f);
	}
	
	const uint2 outPosition = inPosition * 2;
	outTexture.write( float4(dst[0], 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(dst[1], 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(dst[2], 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(dst[3], 1.0f), outPosition + uint2(1, 1) );
}

//---------------------------------------
// Input Pixel Mapping:  00|01|02
//                       03|04|05
//                       06|07|08
//
// Output Pixel Mapping:  00|01
//                        02|03
kernel void pixel_scaler_LQ2x(const uint2 inPosition [[thread_position_in_grid]],
							  const texture2d<float, access::sample> inTexture [[texture(0)]],
							  const texture3d<float, access::read> lut [[texture(2)]],
							  texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src[9] = {
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb
	};
	
	const float v[9] = {
		reduce(src[0]),
		reduce(src[1]),
		reduce(src[2]),
		reduce(src[3]),
		reduce(src[4]),
		reduce(src[5]),
		reduce(src[6]),
		reduce(src[7]),
		reduce(src[8])
	};
	
	const int pattern = (int(v[0] != v[4]) * 1) +
	                    (int(v[1] != v[4]) * 2) +
	                    (int(v[2] != v[4]) * 4) +
	                    (int(v[3] != v[4]) * 8) +
	                    (int(v[5] != v[4]) * 16) +
	                    (int(v[6] != v[4]) * 32) +
	                    (int(v[7] != v[4]) * 64) +
	                    (int(v[8] != v[4]) * 128);
	
	const int compare = (int(v[1] != v[5]) * 1) +
	                    (int(v[5] != v[7]) * 2) +
	                    (int(v[7] != v[3]) * 4) +
	                    (int(v[3] != v[1]) * 8);
	
	const float3 p[4] = {
		lut.read(uint3(pattern*2+0, 0, compare)).rgb,
		lut.read(uint3(pattern*2+0, 1, compare)).rgb,
		lut.read(uint3(pattern*2+0, 2, compare)).rgb,
		lut.read(uint3(pattern*2+0, 3, compare)).rgb
	};
	
	const float3 w[4] = {
		lut.read(uint3(pattern*2+1, 0, compare)).rgb,
		lut.read(uint3(pattern*2+1, 1, compare)).rgb,
		lut.read(uint3(pattern*2+1, 2, compare)).rgb,
		lut.read(uint3(pattern*2+1, 3, compare)).rgb
	};
	
	const uint2 outPosition = inPosition * 2;
	outTexture.write( float4(Lerp(w[0], src[int(p[0].r*255.0f/30.95f)], src[int(p[0].g*255.0f/30.95f)], src[int(p[0].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(Lerp(w[1], src[int(p[1].r*255.0f/30.95f)], src[int(p[1].g*255.0f/30.95f)], src[int(p[1].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(Lerp(w[2], src[int(p[2].r*255.0f/30.95f)], src[int(p[2].g*255.0f/30.95f)], src[int(p[2].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(Lerp(w[3], src[int(p[3].r*255.0f/30.95f)], src[int(p[3].g*255.0f/30.95f)], src[int(p[3].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 1) );
}

//---------------------------------------
// Input Pixel Mapping:  00|01|02
//                       03|04|05
//                       06|07|08
//
// Output Pixel Mapping:  00|01
//                        02|03
kernel void pixel_scaler_LQ2xS(const uint2 inPosition [[thread_position_in_grid]],
							   const texture2d<float, access::sample> inTexture [[texture(0)]],
							   const texture3d<float, access::read> lut [[texture(2)]],
							   texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src[9] = {
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb
	};
	
	float b[9];
	float minBright = 10.0f;
	float maxBright = 0.0f;
	
	for (int i = 0; i < 9; i++)
	{
		b[i] = (src[i].r + src[i].r + src[i].r) + (src[i].g + src[i].g + src[i].g) + (src[i].b + src[i].b);
		minBright = min(minBright, b[i]);
		maxBright = max(maxBright, b[i]);
	}
	
	const float diffBright = (maxBright - minBright) / 16.0f;
	const int pattern = int(step((0.5f*1.0f/127.5f), diffBright)) *	((int(abs(b[0] - b[4]) > diffBright) * 1) +
																	 (int(abs(b[1] - b[4]) > diffBright) * 2) +
																	 (int(abs(b[2] - b[4]) > diffBright) * 4) +
																	 (int(abs(b[3] - b[4]) > diffBright) * 8) +
																	 (int(abs(b[5] - b[4]) > diffBright) * 16) +
																	 (int(abs(b[6] - b[4]) > diffBright) * 32) +
																	 (int(abs(b[7] - b[4]) > diffBright) * 64) +
																	 (int(abs(b[8] - b[4]) > diffBright) * 128));
	
	const float3 p[4] = {
		lut.read(uint3(pattern*2+0, 0, 0)).rgb,
		lut.read(uint3(pattern*2+0, 1, 0)).rgb,
		lut.read(uint3(pattern*2+0, 2, 0)).rgb,
		lut.read(uint3(pattern*2+0, 3, 0)).rgb
	};
	
	const float3 w[4] = {
		lut.read(uint3(pattern*2+1, 0, 0)).rgb,
		lut.read(uint3(pattern*2+1, 1, 0)).rgb,
		lut.read(uint3(pattern*2+1, 2, 0)).rgb,
		lut.read(uint3(pattern*2+1, 3, 0)).rgb
	};
	
	const uint2 outPosition = inPosition * 2;
	outTexture.write( float4(Lerp(w[0], src[int(p[0].r*255.0f/30.95f)], src[int(p[0].g*255.0f/30.95f)], src[int(p[0].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(Lerp(w[1], src[int(p[1].r*255.0f/30.95f)], src[int(p[1].g*255.0f/30.95f)], src[int(p[1].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(Lerp(w[2], src[int(p[2].r*255.0f/30.95f)], src[int(p[2].g*255.0f/30.95f)], src[int(p[2].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(Lerp(w[3], src[int(p[3].r*255.0f/30.95f)], src[int(p[3].g*255.0f/30.95f)], src[int(p[3].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 1) );
}

//---------------------------------------
// Input Pixel Mapping:  00|01|02
//                       03|04|05
//                       06|07|08
//
// Output Pixel Mapping:  00|01
//                        02|03
kernel void pixel_scaler_HQ2x(const uint2 inPosition [[thread_position_in_grid]],
							  const texture2d<float, access::sample> inTexture [[texture(0)]],
							  const texture3d<float, access::read> lut [[texture(2)]],
							  texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src[9] = {
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb
	};
	
	const int pattern	= (int(InterpDiff(src[0], src[4])) * 1) +
						  (int(InterpDiff(src[1], src[4])) * 2) +
						  (int(InterpDiff(src[2], src[4])) * 4) +
						  (int(InterpDiff(src[3], src[4])) * 8) +
						  (int(InterpDiff(src[5], src[4])) * 16) +
						  (int(InterpDiff(src[6], src[4])) * 32) +
						  (int(InterpDiff(src[7], src[4])) * 64) +
						  (int(InterpDiff(src[8], src[4])) * 128);
	
	const int compare	= (int(InterpDiff(src[1], src[5])) * 1) +
						  (int(InterpDiff(src[5], src[7])) * 2) +
						  (int(InterpDiff(src[7], src[3])) * 4) +
						  (int(InterpDiff(src[3], src[1])) * 8);
	
	const float3 p[4] = {
		lut.read(uint3(pattern*2+0, 0, compare)).rgb,
		lut.read(uint3(pattern*2+0, 1, compare)).rgb,
		lut.read(uint3(pattern*2+0, 2, compare)).rgb,
		lut.read(uint3(pattern*2+0, 3, compare)).rgb
	};
	
	const float3 w[4] = {
		lut.read(uint3(pattern*2+1, 0, compare)).rgb,
		lut.read(uint3(pattern*2+1, 1, compare)).rgb,
		lut.read(uint3(pattern*2+1, 2, compare)).rgb,
		lut.read(uint3(pattern*2+1, 3, compare)).rgb
	};
	
	const uint2 outPosition = inPosition * 2;
	outTexture.write( float4(Lerp(w[0], src[int(p[0].r*255.0f/30.95f)], src[int(p[0].g*255.0f/30.95f)], src[int(p[0].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(Lerp(w[1], src[int(p[1].r*255.0f/30.95f)], src[int(p[1].g*255.0f/30.95f)], src[int(p[1].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(Lerp(w[2], src[int(p[2].r*255.0f/30.95f)], src[int(p[2].g*255.0f/30.95f)], src[int(p[2].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(Lerp(w[3], src[int(p[3].r*255.0f/30.95f)], src[int(p[3].g*255.0f/30.95f)], src[int(p[3].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 1) );
}

//---------------------------------------
// Input Pixel Mapping:  00|01|02
//                       03|04|05
//                       06|07|08
//
// Output Pixel Mapping:  00|01
//                        02|03
kernel void pixel_scaler_HQ2xS(const uint2 inPosition [[thread_position_in_grid]],
							   const texture2d<float, access::sample> inTexture [[texture(0)]],
							   const texture3d<float, access::read> lut [[texture(2)]],
							   texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src[9] = {
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb
	};
	
	float b[9];
	float minBright = 10.0f;
	float maxBright = 0.0f;
	
	for (int i = 0; i < 9; i++)
	{
		b[i] = (src[i].r + src[i].r + src[i].r) + (src[i].g + src[i].g + src[i].g) + (src[i].b + src[i].b);
		minBright = min(minBright, b[i]);
		maxBright = max(maxBright, b[i]);
	}
	
	const float diffBright = (maxBright - minBright) * (7.0f/16.0f);
	const int pattern = int(step((3.5f*7.0f/892.5f), diffBright)) *	((int(abs(b[0] - b[4]) > diffBright) * 1) +
																	 (int(abs(b[1] - b[4]) > diffBright) * 2) +
																	 (int(abs(b[2] - b[4]) > diffBright) * 4) +
																	 (int(abs(b[3] - b[4]) > diffBright) * 8) +
																	 (int(abs(b[5] - b[4]) > diffBright) * 16) +
																	 (int(abs(b[6] - b[4]) > diffBright) * 32) +
																	 (int(abs(b[7] - b[4]) > diffBright) * 64) +
																	 (int(abs(b[8] - b[4]) > diffBright) * 128));
	
	const float3 p[4] = {
		lut.read(uint3(pattern*2+0, 0, 0)).rgb,
		lut.read(uint3(pattern*2+0, 1, 0)).rgb,
		lut.read(uint3(pattern*2+0, 2, 0)).rgb,
		lut.read(uint3(pattern*2+0, 3, 0)).rgb
	};
	
	const float3 w[4] = {
		lut.read(uint3(pattern*2+1, 0, 0)).rgb,
		lut.read(uint3(pattern*2+1, 1, 0)).rgb,
		lut.read(uint3(pattern*2+1, 2, 0)).rgb,
		lut.read(uint3(pattern*2+1, 3, 0)).rgb
	};
	
	const uint2 outPosition = inPosition * 2;
	outTexture.write( float4(Lerp(w[0], src[int(p[0].r*255.0f/30.95f)], src[int(p[0].g*255.0f/30.95f)], src[int(p[0].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(Lerp(w[1], src[int(p[1].r*255.0f/30.95f)], src[int(p[1].g*255.0f/30.95f)], src[int(p[1].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(Lerp(w[2], src[int(p[2].r*255.0f/30.95f)], src[int(p[2].g*255.0f/30.95f)], src[int(p[2].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(Lerp(w[3], src[int(p[3].r*255.0f/30.95f)], src[int(p[3].g*255.0f/30.95f)], src[int(p[3].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 1) );
}

//---------------------------------------
// Input Pixel Mapping:  00|01|02
//                       03|04|05
//                       06|07|08
//
// Output Pixel Mapping: 00|01|02
//                       03|04|05
//                       06|07|08
kernel void pixel_scaler_HQ3x(const uint2 inPosition [[thread_position_in_grid]],
							  const texture2d<float, access::sample> inTexture [[texture(0)]],
							  const texture3d<float, access::read> lut [[texture(2)]],
							  texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src[9] = {
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb
	};
	
	const int pattern	= (int(InterpDiff(src[0], src[4])) * 1) +
						  (int(InterpDiff(src[1], src[4])) * 2) +
						  (int(InterpDiff(src[2], src[4])) * 4) +
						  (int(InterpDiff(src[3], src[4])) * 8) +
						  (int(InterpDiff(src[5], src[4])) * 16) +
						  (int(InterpDiff(src[6], src[4])) * 32) +
						  (int(InterpDiff(src[7], src[4])) * 64) +
						  (int(InterpDiff(src[8], src[4])) * 128);
	
	const int compare	= (int(InterpDiff(src[1], src[5])) * 1) +
						  (int(InterpDiff(src[5], src[7])) * 2) +
						  (int(InterpDiff(src[7], src[3])) * 4) +
						  (int(InterpDiff(src[3], src[1])) * 8);
	
	const float3 p[9] = {
		lut.read(uint3(pattern*2+0, 0, compare)).rgb,
		lut.read(uint3(pattern*2+0, 1, compare)).rgb,
		lut.read(uint3(pattern*2+0, 2, compare)).rgb,
		lut.read(uint3(pattern*2+0, 3, compare)).rgb,
		lut.read(uint3(pattern*2+0, 4, compare)).rgb,
		lut.read(uint3(pattern*2+0, 5, compare)).rgb,
		lut.read(uint3(pattern*2+0, 6, compare)).rgb,
		lut.read(uint3(pattern*2+0, 7, compare)).rgb,
		lut.read(uint3(pattern*2+0, 8, compare)).rgb
	};
	
	const float3 w[9] = {
		lut.read(uint3(pattern*2+1, 0, compare)).rgb,
		lut.read(uint3(pattern*2+1, 1, compare)).rgb,
		lut.read(uint3(pattern*2+1, 2, compare)).rgb,
		lut.read(uint3(pattern*2+1, 3, compare)).rgb,
		lut.read(uint3(pattern*2+1, 4, compare)).rgb,
		lut.read(uint3(pattern*2+1, 5, compare)).rgb,
		lut.read(uint3(pattern*2+1, 6, compare)).rgb,
		lut.read(uint3(pattern*2+1, 7, compare)).rgb,
		lut.read(uint3(pattern*2+1, 8, compare)).rgb
	};
	
	const uint2 outPosition = inPosition * 3;
	outTexture.write( float4(Lerp(w[0], src[int(p[0].r*255.0f/30.95f)], src[int(p[0].g*255.0f/30.95f)], src[int(p[0].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(Lerp(w[1], src[int(p[1].r*255.0f/30.95f)], src[int(p[1].g*255.0f/30.95f)], src[int(p[1].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(Lerp(w[2], src[int(p[2].r*255.0f/30.95f)], src[int(p[2].g*255.0f/30.95f)], src[int(p[2].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(2, 0) );
	outTexture.write( float4(Lerp(w[3], src[int(p[3].r*255.0f/30.95f)], src[int(p[3].g*255.0f/30.95f)], src[int(p[3].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(Lerp(w[4], src[int(p[4].r*255.0f/30.95f)], src[int(p[4].g*255.0f/30.95f)], src[int(p[4].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 1) );
	outTexture.write( float4(Lerp(w[5], src[int(p[5].r*255.0f/30.95f)], src[int(p[5].g*255.0f/30.95f)], src[int(p[5].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(2, 1) );
	outTexture.write( float4(Lerp(w[6], src[int(p[6].r*255.0f/30.95f)], src[int(p[6].g*255.0f/30.95f)], src[int(p[6].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 2) );
	outTexture.write( float4(Lerp(w[7], src[int(p[7].r*255.0f/30.95f)], src[int(p[7].g*255.0f/30.95f)], src[int(p[7].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 2) );
	outTexture.write( float4(Lerp(w[8], src[int(p[8].r*255.0f/30.95f)], src[int(p[8].g*255.0f/30.95f)], src[int(p[8].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(2, 2) );
}

//---------------------------------------
// Input Pixel Mapping:  00|01|02
//                       03|04|05
//                       06|07|08
//
// Output Pixel Mapping: 00|01|02
//                       03|04|05
//                       06|07|08
kernel void pixel_scaler_HQ3xS(const uint2 inPosition [[thread_position_in_grid]],
							   const texture2d<float, access::sample> inTexture [[texture(0)]],
							   const texture3d<float, access::read> lut [[texture(2)]],
							   texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src[9] = {
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb
	};
	
	float b[9];
	float minBright = 10.0f;
	float maxBright = 0.0f;
	
	for (int i = 0; i < 9; i++)
	{
		b[i] = (src[i].r + src[i].r + src[i].r) + (src[i].g + src[i].g + src[i].g) + (src[i].b + src[i].b);
		minBright = min(minBright, b[i]);
		maxBright = max(maxBright, b[i]);
	}
	
	const float diffBright = (maxBright - minBright) * (7.0f/16.0f);
	const int pattern = int(step((3.5f*7.0f/892.5f), diffBright)) *	((int(abs(b[0] - b[4]) > diffBright) * 1) +
																	 (int(abs(b[1] - b[4]) > diffBright) * 2) +
																	 (int(abs(b[2] - b[4]) > diffBright) * 4) +
																	 (int(abs(b[3] - b[4]) > diffBright) * 8) +
																	 (int(abs(b[5] - b[4]) > diffBright) * 16) +
																	 (int(abs(b[6] - b[4]) > diffBright) * 32) +
																	 (int(abs(b[7] - b[4]) > diffBright) * 64) +
																	 (int(abs(b[8] - b[4]) > diffBright) * 128));
	
	const float3 p[9] = {
		lut.read(uint3(pattern*2+0, 0, 0)).rgb,
		lut.read(uint3(pattern*2+0, 1, 0)).rgb,
		lut.read(uint3(pattern*2+0, 2, 0)).rgb,
		lut.read(uint3(pattern*2+0, 3, 0)).rgb,
		lut.read(uint3(pattern*2+0, 4, 0)).rgb,
		lut.read(uint3(pattern*2+0, 5, 0)).rgb,
		lut.read(uint3(pattern*2+0, 6, 0)).rgb,
		lut.read(uint3(pattern*2+0, 7, 0)).rgb,
		lut.read(uint3(pattern*2+0, 8, 0)).rgb
	};
	
	const float3 w[9] = {
		lut.read(uint3(pattern*2+1, 0, 0)).rgb,
		lut.read(uint3(pattern*2+1, 1, 0)).rgb,
		lut.read(uint3(pattern*2+1, 2, 0)).rgb,
		lut.read(uint3(pattern*2+1, 3, 0)).rgb,
		lut.read(uint3(pattern*2+1, 4, 0)).rgb,
		lut.read(uint3(pattern*2+1, 5, 0)).rgb,
		lut.read(uint3(pattern*2+1, 6, 0)).rgb,
		lut.read(uint3(pattern*2+1, 7, 0)).rgb,
		lut.read(uint3(pattern*2+1, 8, 0)).rgb
	};
	
	const uint2 outPosition = inPosition * 3;
	outTexture.write( float4(Lerp(w[0], src[int(p[0].r*255.0f/30.95f)], src[int(p[0].g*255.0f/30.95f)], src[int(p[0].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(Lerp(w[1], src[int(p[1].r*255.0f/30.95f)], src[int(p[1].g*255.0f/30.95f)], src[int(p[1].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(Lerp(w[2], src[int(p[2].r*255.0f/30.95f)], src[int(p[2].g*255.0f/30.95f)], src[int(p[2].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(2, 0) );
	outTexture.write( float4(Lerp(w[3], src[int(p[3].r*255.0f/30.95f)], src[int(p[3].g*255.0f/30.95f)], src[int(p[3].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(Lerp(w[4], src[int(p[4].r*255.0f/30.95f)], src[int(p[4].g*255.0f/30.95f)], src[int(p[4].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 1) );
	outTexture.write( float4(Lerp(w[5], src[int(p[5].r*255.0f/30.95f)], src[int(p[5].g*255.0f/30.95f)], src[int(p[5].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(2, 1) );
	outTexture.write( float4(Lerp(w[6], src[int(p[6].r*255.0f/30.95f)], src[int(p[6].g*255.0f/30.95f)], src[int(p[6].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 2) );
	outTexture.write( float4(Lerp(w[7], src[int(p[7].r*255.0f/30.95f)], src[int(p[7].g*255.0f/30.95f)], src[int(p[7].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 2) );
	outTexture.write( float4(Lerp(w[8], src[int(p[8].r*255.0f/30.95f)], src[int(p[8].g*255.0f/30.95f)], src[int(p[8].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(2, 2) );
}

//---------------------------------------
// Input Pixel Mapping:    00|01|02
//                         03|04|05
//                         06|07|08
//
// Output Pixel Mapping:  00|01|02|03
//                        04|05|06|07
//                        08|09|10|11
//                        12|13|14|15
kernel void pixel_scaler_HQ4x(const uint2 inPosition [[thread_position_in_grid]],
							  const texture2d<float, access::sample> inTexture [[texture(0)]],
							  const texture3d<float, access::read> lut [[texture(2)]],
							  texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src[9] = {
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb
	};
	
	const int pattern = (int(InterpDiff(src[0], src[4])) * 1) +
	                    (int(InterpDiff(src[1], src[4])) * 2) +
	                    (int(InterpDiff(src[2], src[4])) * 4) +
	                    (int(InterpDiff(src[3], src[4])) * 8) +
	                    (int(InterpDiff(src[5], src[4])) * 16) +
	                    (int(InterpDiff(src[6], src[4])) * 32) +
	                    (int(InterpDiff(src[7], src[4])) * 64) +
	                    (int(InterpDiff(src[8], src[4])) * 128);
	
	const int compare = (int(InterpDiff(src[1], src[5])) * 1) +
	                    (int(InterpDiff(src[5], src[7])) * 2) +
	                    (int(InterpDiff(src[7], src[3])) * 4) +
	                    (int(InterpDiff(src[3], src[1])) * 8);
	
	const float3 p[16] = {
		lut.read(uint3(pattern*2+0,  0, compare)).rgb,
		lut.read(uint3(pattern*2+0,  1, compare)).rgb,
		lut.read(uint3(pattern*2+0,  2, compare)).rgb,
		lut.read(uint3(pattern*2+0,  3, compare)).rgb,
		lut.read(uint3(pattern*2+0,  4, compare)).rgb,
		lut.read(uint3(pattern*2+0,  5, compare)).rgb,
		lut.read(uint3(pattern*2+0,  6, compare)).rgb,
		lut.read(uint3(pattern*2+0,  7, compare)).rgb,
		lut.read(uint3(pattern*2+0,  8, compare)).rgb,
		lut.read(uint3(pattern*2+0,  9, compare)).rgb,
		lut.read(uint3(pattern*2+0, 10, compare)).rgb,
		lut.read(uint3(pattern*2+0, 11, compare)).rgb,
		lut.read(uint3(pattern*2+0, 12, compare)).rgb,
		lut.read(uint3(pattern*2+0, 13, compare)).rgb,
		lut.read(uint3(pattern*2+0, 14, compare)).rgb,
		lut.read(uint3(pattern*2+0, 15, compare)).rgb
	};
	
	const float3 w[16] = {
		lut.read(uint3(pattern*2+1,  0, compare)).rgb,
		lut.read(uint3(pattern*2+1,  1, compare)).rgb,
		lut.read(uint3(pattern*2+1,  2, compare)).rgb,
		lut.read(uint3(pattern*2+1,  3, compare)).rgb,
		lut.read(uint3(pattern*2+1,  4, compare)).rgb,
		lut.read(uint3(pattern*2+1,  5, compare)).rgb,
		lut.read(uint3(pattern*2+1,  6, compare)).rgb,
		lut.read(uint3(pattern*2+1,  7, compare)).rgb,
		lut.read(uint3(pattern*2+1,  8, compare)).rgb,
		lut.read(uint3(pattern*2+1,  9, compare)).rgb,
		lut.read(uint3(pattern*2+1, 10, compare)).rgb,
		lut.read(uint3(pattern*2+1, 11, compare)).rgb,
		lut.read(uint3(pattern*2+1, 12, compare)).rgb,
		lut.read(uint3(pattern*2+1, 13, compare)).rgb,
		lut.read(uint3(pattern*2+1, 14, compare)).rgb,
		lut.read(uint3(pattern*2+1, 15, compare)).rgb
	};
	
	const uint2 outPosition = inPosition * 4;
	outTexture.write( float4(Lerp(w[ 0], src[int(p[ 0].r*255.0f/30.95f)], src[int(p[ 0].g*255.0f/30.95f)], src[int(p[ 0].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(Lerp(w[ 1], src[int(p[ 1].r*255.0f/30.95f)], src[int(p[ 1].g*255.0f/30.95f)], src[int(p[ 1].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(Lerp(w[ 2], src[int(p[ 2].r*255.0f/30.95f)], src[int(p[ 2].g*255.0f/30.95f)], src[int(p[ 2].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(2, 0) );
	outTexture.write( float4(Lerp(w[ 3], src[int(p[ 3].r*255.0f/30.95f)], src[int(p[ 3].g*255.0f/30.95f)], src[int(p[ 3].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(3, 0) );
	outTexture.write( float4(Lerp(w[ 4], src[int(p[ 4].r*255.0f/30.95f)], src[int(p[ 4].g*255.0f/30.95f)], src[int(p[ 4].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(Lerp(w[ 5], src[int(p[ 5].r*255.0f/30.95f)], src[int(p[ 5].g*255.0f/30.95f)], src[int(p[ 5].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 1) );
	outTexture.write( float4(Lerp(w[ 6], src[int(p[ 6].r*255.0f/30.95f)], src[int(p[ 6].g*255.0f/30.95f)], src[int(p[ 6].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(2, 1) );
	outTexture.write( float4(Lerp(w[ 7], src[int(p[ 7].r*255.0f/30.95f)], src[int(p[ 7].g*255.0f/30.95f)], src[int(p[ 7].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(3, 1) );
	outTexture.write( float4(Lerp(w[ 8], src[int(p[ 8].r*255.0f/30.95f)], src[int(p[ 8].g*255.0f/30.95f)], src[int(p[ 8].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 2) );
	outTexture.write( float4(Lerp(w[ 9], src[int(p[ 9].r*255.0f/30.95f)], src[int(p[ 9].g*255.0f/30.95f)], src[int(p[ 9].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 2) );
	outTexture.write( float4(Lerp(w[10], src[int(p[10].r*255.0f/30.95f)], src[int(p[10].g*255.0f/30.95f)], src[int(p[10].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(2, 2) );
	outTexture.write( float4(Lerp(w[11], src[int(p[11].r*255.0f/30.95f)], src[int(p[11].g*255.0f/30.95f)], src[int(p[11].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(3, 2) );
	outTexture.write( float4(Lerp(w[12], src[int(p[12].r*255.0f/30.95f)], src[int(p[12].g*255.0f/30.95f)], src[int(p[12].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 3) );
	outTexture.write( float4(Lerp(w[13], src[int(p[13].r*255.0f/30.95f)], src[int(p[13].g*255.0f/30.95f)], src[int(p[13].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 3) );
	outTexture.write( float4(Lerp(w[14], src[int(p[14].r*255.0f/30.95f)], src[int(p[14].g*255.0f/30.95f)], src[int(p[14].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(2, 3) );
	outTexture.write( float4(Lerp(w[15], src[int(p[15].r*255.0f/30.95f)], src[int(p[15].g*255.0f/30.95f)], src[int(p[15].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(3, 3) );
}

//---------------------------------------
// Input Pixel Mapping:    00|01|02
//                         03|04|05
//                         06|07|08
//
// Output Pixel Mapping:  00|01|02|03
//                        04|05|06|07
//                        08|09|10|11
//                        12|13|14|15
kernel void pixel_scaler_HQ4xS(const uint2 inPosition [[thread_position_in_grid]],
							   const texture2d<float, access::sample> inTexture [[texture(0)]],
							   const texture3d<float, access::read> lut [[texture(2)]],
							   texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src[9] = {
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb
	};
	
	float b[9];
	float minBright = 10.0f;
	float maxBright = 0.0f;
	
	for (int i = 0; i < 9; i++)
	{
		b[i] = (src[i].r + src[i].r + src[i].r) + (src[i].g + src[i].g + src[i].g) + (src[i].b + src[i].b);
		minBright = min(minBright, b[i]);
		maxBright = max(maxBright, b[i]);
	}
	
	const float diffBright = (maxBright - minBright) * (7.0f/16.0f);
	const int pattern = int(step((3.5f*7.0f/892.5f), diffBright)) *	((int(abs(b[0] - b[4]) > diffBright) * 1) +
																	 (int(abs(b[1] - b[4]) > diffBright) * 2) +
																	 (int(abs(b[2] - b[4]) > diffBright) * 4) +
																	 (int(abs(b[3] - b[4]) > diffBright) * 8) +
																	 (int(abs(b[5] - b[4]) > diffBright) * 16) +
																	 (int(abs(b[6] - b[4]) > diffBright) * 32) +
																	 (int(abs(b[7] - b[4]) > diffBright) * 64) +
																	 (int(abs(b[8] - b[4]) > diffBright) * 128));
	
	const float3 p[16] = {
		lut.read(uint3(pattern*2+0,  0, 0)).rgb,
		lut.read(uint3(pattern*2+0,  1, 0)).rgb,
		lut.read(uint3(pattern*2+0,  2, 0)).rgb,
		lut.read(uint3(pattern*2+0,  3, 0)).rgb,
		lut.read(uint3(pattern*2+0,  4, 0)).rgb,
		lut.read(uint3(pattern*2+0,  5, 0)).rgb,
		lut.read(uint3(pattern*2+0,  6, 0)).rgb,
		lut.read(uint3(pattern*2+0,  7, 0)).rgb,
		lut.read(uint3(pattern*2+0,  8, 0)).rgb,
		lut.read(uint3(pattern*2+0,  9, 0)).rgb,
		lut.read(uint3(pattern*2+0, 10, 0)).rgb,
		lut.read(uint3(pattern*2+0, 11, 0)).rgb,
		lut.read(uint3(pattern*2+0, 12, 0)).rgb,
		lut.read(uint3(pattern*2+0, 13, 0)).rgb,
		lut.read(uint3(pattern*2+0, 14, 0)).rgb,
		lut.read(uint3(pattern*2+0, 15, 0)).rgb
	};
	
	const float3 w[16] = {
		lut.read(uint3(pattern*2+1,  0, 0)).rgb,
		lut.read(uint3(pattern*2+1,  1, 0)).rgb,
		lut.read(uint3(pattern*2+1,  2, 0)).rgb,
		lut.read(uint3(pattern*2+1,  3, 0)).rgb,
		lut.read(uint3(pattern*2+1,  4, 0)).rgb,
		lut.read(uint3(pattern*2+1,  5, 0)).rgb,
		lut.read(uint3(pattern*2+1,  6, 0)).rgb,
		lut.read(uint3(pattern*2+1,  7, 0)).rgb,
		lut.read(uint3(pattern*2+1,  8, 0)).rgb,
		lut.read(uint3(pattern*2+1,  9, 0)).rgb,
		lut.read(uint3(pattern*2+1, 10, 0)).rgb,
		lut.read(uint3(pattern*2+1, 11, 0)).rgb,
		lut.read(uint3(pattern*2+1, 12, 0)).rgb,
		lut.read(uint3(pattern*2+1, 13, 0)).rgb,
		lut.read(uint3(pattern*2+1, 14, 0)).rgb,
		lut.read(uint3(pattern*2+1, 15, 0)).rgb
	};
	
	const uint2 outPosition = inPosition * 4;
	outTexture.write( float4(Lerp(w[ 0], src[int(p[ 0].r*255.0f/30.95f)], src[int(p[ 0].g*255.0f/30.95f)], src[int(p[ 0].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(Lerp(w[ 1], src[int(p[ 1].r*255.0f/30.95f)], src[int(p[ 1].g*255.0f/30.95f)], src[int(p[ 1].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(Lerp(w[ 2], src[int(p[ 2].r*255.0f/30.95f)], src[int(p[ 2].g*255.0f/30.95f)], src[int(p[ 2].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(2, 0) );
	outTexture.write( float4(Lerp(w[ 3], src[int(p[ 3].r*255.0f/30.95f)], src[int(p[ 3].g*255.0f/30.95f)], src[int(p[ 3].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(3, 0) );
	outTexture.write( float4(Lerp(w[ 4], src[int(p[ 4].r*255.0f/30.95f)], src[int(p[ 4].g*255.0f/30.95f)], src[int(p[ 4].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(Lerp(w[ 5], src[int(p[ 5].r*255.0f/30.95f)], src[int(p[ 5].g*255.0f/30.95f)], src[int(p[ 5].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 1) );
	outTexture.write( float4(Lerp(w[ 6], src[int(p[ 6].r*255.0f/30.95f)], src[int(p[ 6].g*255.0f/30.95f)], src[int(p[ 6].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(2, 1) );
	outTexture.write( float4(Lerp(w[ 7], src[int(p[ 7].r*255.0f/30.95f)], src[int(p[ 7].g*255.0f/30.95f)], src[int(p[ 7].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(3, 1) );
	outTexture.write( float4(Lerp(w[ 8], src[int(p[ 8].r*255.0f/30.95f)], src[int(p[ 8].g*255.0f/30.95f)], src[int(p[ 8].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 2) );
	outTexture.write( float4(Lerp(w[ 9], src[int(p[ 9].r*255.0f/30.95f)], src[int(p[ 9].g*255.0f/30.95f)], src[int(p[ 9].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 2) );
	outTexture.write( float4(Lerp(w[10], src[int(p[10].r*255.0f/30.95f)], src[int(p[10].g*255.0f/30.95f)], src[int(p[10].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(2, 2) );
	outTexture.write( float4(Lerp(w[11], src[int(p[11].r*255.0f/30.95f)], src[int(p[11].g*255.0f/30.95f)], src[int(p[11].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(3, 2) );
	outTexture.write( float4(Lerp(w[12], src[int(p[12].r*255.0f/30.95f)], src[int(p[12].g*255.0f/30.95f)], src[int(p[12].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(0, 3) );
	outTexture.write( float4(Lerp(w[13], src[int(p[13].r*255.0f/30.95f)], src[int(p[13].g*255.0f/30.95f)], src[int(p[13].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(1, 3) );
	outTexture.write( float4(Lerp(w[14], src[int(p[14].r*255.0f/30.95f)], src[int(p[14].g*255.0f/30.95f)], src[int(p[14].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(2, 3) );
	outTexture.write( float4(Lerp(w[15], src[int(p[15].r*255.0f/30.95f)], src[int(p[15].g*255.0f/30.95f)], src[int(p[15].b*255.0f/30.95f)]), 1.0f), outPosition + uint2(3, 3) );
}

#define BLEND_NONE 0
#define BLEND_NORMAL 1
#define BLEND_DOMINANT 2
#define LUMINANCE_WEIGHT 1.0
#define EQUAL_COLOR_TOLERANCE 30.0/255.0
#define STEEP_DIRECTION_THRESHOLD 2.2
#define DOMINANT_DIRECTION_THRESHOLD 3.6

float DistYCbCr(const float3 pixA, const float3 pixB)
{
	const float3 w = float3(0.2627f, 0.6780f, 0.0593f);
	const float scaleB = 0.5f / (1.0f - w.b);
	const float scaleR = 0.5f / (1.0f - w.r);
	float3 diff = pixA - pixB;
	float Y = dot(diff, w);
	float Cb = scaleB * (diff.b - Y);
	float Cr = scaleR * (diff.r - Y);
	
	return sqrt( ((LUMINANCE_WEIGHT*Y) * (LUMINANCE_WEIGHT*Y)) + (Cb * Cb) + (Cr * Cr) );
}

bool IsPixEqual(const float3 pixA, const float3 pixB)
{
	return (DistYCbCr(pixA, pixB) < EQUAL_COLOR_TOLERANCE);
}

bool IsBlendingNeeded(const int4 blend)
{
	return any(blend != int4(BLEND_NONE));
}

//---------------------------------------
// Input Pixel Mapping:  --|21|22|23|--
//                       19|06|07|08|09
//                       18|05|00|01|10
//                       17|04|03|02|11
//                       --|15|14|13|--
//
// Output Pixel Mapping:     00|01
//                           03|02
kernel void pixel_scaler_2xBRZ(const uint2 inPosition [[thread_position_in_grid]],
							   const texture2d<float, access::sample> inTexture [[texture(0)]],
							   texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src[25] = {
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2,-2)).rgb
	};
	
	const float v[9] = {
		reduce(src[0]),
		reduce(src[1]),
		reduce(src[2]),
		reduce(src[3]),
		reduce(src[4]),
		reduce(src[5]),
		reduce(src[6]),
		reduce(src[7]),
		reduce(src[8])
	};
	
	int4 blendResult = int4(BLEND_NONE);
	
	// Preprocess corners
	// Pixel Tap Mapping: --|--|--|--|--
	//                    --|--|07|08|--
	//                    --|05|00|01|10
	//                    --|04|03|02|11
	//                    --|--|14|13|--
	
	// Corner (1, 1)
	if ( !((v[0] == v[1] && v[3] == v[2]) || (v[0] == v[3] && v[1] == v[2])) )
	{
		const float dist_03_01 = DistYCbCr(src[ 4], src[ 0]) + DistYCbCr(src[ 0], src[ 8]) + DistYCbCr(src[14], src[ 2]) + DistYCbCr(src[ 2], src[10]) + (4.0 * DistYCbCr(src[ 3], src[ 1]));
		const float dist_00_02 = DistYCbCr(src[ 5], src[ 3]) + DistYCbCr(src[ 3], src[13]) + DistYCbCr(src[ 7], src[ 1]) + DistYCbCr(src[ 1], src[11]) + (4.0 * DistYCbCr(src[ 0], src[ 2]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_03_01) < dist_00_02;
		
		blendResult[2] = ((dist_03_01 < dist_00_02) && (v[0] != v[1]) && (v[0] != v[3])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	
	// Pixel Tap Mapping: --|--|--|--|--
	//                    --|06|07|--|--
	//                    18|05|00|01|--
	//                    17|04|03|02|--
	//                    --|15|14|--|--
	// Corner (0, 1)
	if ( !((v[5] == v[0] && v[4] == v[3]) || (v[5] == v[4] && v[0] == v[3])) )
	{
		const float dist_04_00 = DistYCbCr(src[17], src[ 5]) + DistYCbCr(src[ 5], src[ 7]) + DistYCbCr(src[15], src[ 3]) + DistYCbCr(src[ 3], src[ 1]) + (4.0 * DistYCbCr(src[ 4], src[ 0]));
		const float dist_05_03 = DistYCbCr(src[18], src[ 4]) + DistYCbCr(src[ 4], src[14]) + DistYCbCr(src[ 6], src[ 0]) + DistYCbCr(src[ 0], src[ 2]) + (4.0 * DistYCbCr(src[ 5], src[ 3]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_05_03) < dist_04_00;
		
		blendResult[3] = ((dist_04_00 > dist_05_03) && (v[0] != v[5]) && (v[0] != v[3])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	// Pixel Tap Mapping: --|--|22|23|--
	//                    --|06|07|08|09
	//                    --|05|00|01|10
	//                    --|--|03|02|--
	//                    --|--|--|--|--
	// Corner (1, 0)
	if ( !((v[7] == v[8] && v[0] == v[1]) || (v[7] == v[0] && v[8] == v[1])) )
	{
		const float dist_00_08 = DistYCbCr(src[ 5], src[ 7]) + DistYCbCr(src[ 7], src[23]) + DistYCbCr(src[ 3], src[ 1]) + DistYCbCr(src[ 1], src[ 9]) + (4.0 * DistYCbCr(src[ 0], src[ 8]));
		const float dist_07_01 = DistYCbCr(src[ 6], src[ 0]) + DistYCbCr(src[ 0], src[ 2]) + DistYCbCr(src[22], src[ 8]) + DistYCbCr(src[ 8], src[10]) + (4.0 * DistYCbCr(src[ 7], src[ 1]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_07_01) < dist_00_08;
		
		blendResult[1] = ((dist_00_08 > dist_07_01) && (v[0] != v[7]) && (v[0] != v[1])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	// Pixel Tap Mapping: --|21|22|--|--
	//                    19|06|07|08|--
	//                    18|05|00|01|--
	//                    --|04|03|--|--
	//                    --|--|--|--|--
	// Corner (0, 0)
	if ( !((v[6] == v[7] && v[5] == v[0]) || (v[6] == v[5] && v[7] == v[0])) )
	{
		const float dist_05_07 = DistYCbCr(src[18], src[ 6]) + DistYCbCr(src[ 6], src[22]) + DistYCbCr(src[ 4], src[ 0]) + DistYCbCr(src[ 0], src[ 8]) + (4.0 * DistYCbCr(src[ 5], src[ 7]));
		const float dist_06_00 = DistYCbCr(src[19], src[ 5]) + DistYCbCr(src[ 5], src[ 3]) + DistYCbCr(src[21], src[ 7]) + DistYCbCr(src[ 7], src[ 1]) + (4.0 * DistYCbCr(src[ 6], src[ 0]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_05_07) < dist_06_00;
		
		blendResult[0] = ((dist_05_07 < dist_06_00) && (v[0] != v[5]) && (v[0] != v[7])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	float3 dst[4] = {
		src[0],
		src[0],
		src[0],
		src[0]
	};
	
	// Scale pixel
	if (IsBlendingNeeded(blendResult))
	{
		float4 dist_01_04 = float4( DistYCbCr(src[1], src[4]), DistYCbCr(src[7], src[2]), DistYCbCr(src[5], src[8]), DistYCbCr(src[3], src[6]) );
		float4 dist_03_08 = float4( DistYCbCr(src[3], src[8]), DistYCbCr(src[1], src[6]), DistYCbCr(src[7], src[4]), DistYCbCr(src[5], src[2]) );
		bool4 haveShallowLine = (STEEP_DIRECTION_THRESHOLD * dist_01_04 <= dist_03_08);
		bool4 haveSteepLine = (STEEP_DIRECTION_THRESHOLD * dist_03_08 <= dist_01_04);
		bool4 needBlend = (blendResult.zyxw != int4(BLEND_NONE));
		bool4 doLineBlend = (blendResult.zyxw >= int4(BLEND_DOMINANT));
		float3 blendPix[4];
		
		haveShallowLine[0] = haveShallowLine[0] && (v[0] != v[4]) && (v[5] != v[4]);
		haveSteepLine[0]   = haveSteepLine[0] && (v[0] != v[8]) && (v[7] != v[8]);
		doLineBlend[0] = (  doLineBlend[0] ||
						   !((blendResult[1] != BLEND_NONE && !IsPixEqual(src[0], src[4])) ||
							 (blendResult[3] != BLEND_NONE && !IsPixEqual(src[0], src[8])) ||
							 (IsPixEqual(src[4], src[3]) && IsPixEqual(src[3], src[2]) && IsPixEqual(src[2], src[1]) && IsPixEqual(src[1], src[8]) && !IsPixEqual(src[0], src[2])) ) );
		blendPix[0] = ( DistYCbCr(src[0], src[1]) <= DistYCbCr(src[0], src[3]) ) ? src[1] : src[3];
		
		dst[1] = mix(dst[1], blendPix[0], (needBlend[0] && doLineBlend[0] && haveSteepLine[0]) ? 0.25f : 0.00f);
		dst[2] = mix(dst[2], blendPix[0], (needBlend[0]) ? ((doLineBlend[0]) ? ((haveShallowLine[0]) ? ((haveSteepLine[0]) ? 5.0f/6.0f : 0.75f) : ((haveSteepLine[0]) ? 0.75f : 0.50f)) : 1.0f - (M_PI_F/4.0f)) : 0.00f);
		dst[3] = mix(dst[3], blendPix[0], (needBlend[0] && doLineBlend[0] && haveShallowLine[0]) ? 0.25f : 0.00f);
		
		haveShallowLine[1] = haveShallowLine[1] && (v[0] != v[2]) && (v[3] != v[2]);
		haveSteepLine[1]   = haveSteepLine[1] && (v[0] != v[6]) && (v[5] != v[6]);
		doLineBlend[1] = (  doLineBlend[1] ||
					  !((blendResult[0] != BLEND_NONE && !IsPixEqual(src[0], src[2])) ||
						(blendResult[2] != BLEND_NONE && !IsPixEqual(src[0], src[6])) ||
						(IsPixEqual(src[2], src[1]) && IsPixEqual(src[1], src[8]) && IsPixEqual(src[8], src[7]) && IsPixEqual(src[7], src[6]) && !IsPixEqual(src[0], src[8])) ) );
		blendPix[1] = ( DistYCbCr(src[0], src[7]) <= DistYCbCr(src[0], src[1]) ) ? src[7] : src[1];
		
		dst[0] = mix(dst[0], blendPix[1], (needBlend[1] && doLineBlend[1] && haveSteepLine[1]) ? 0.25f : 0.00f);
		dst[1] = mix(dst[1], blendPix[1], (needBlend[1]) ? ((doLineBlend[1]) ? ((haveShallowLine[1]) ? ((haveSteepLine[1]) ? 5.0f/6.0f : 0.75f) : ((haveSteepLine[1]) ? 0.75f : 0.50f)) : 1.0f - (M_PI_F/4.0f)) : 0.00f);
		dst[2] = mix(dst[2], blendPix[1], (needBlend[1] && doLineBlend[1] && haveShallowLine[1]) ? 0.25f : 0.00f);
		
		haveShallowLine[2] = haveShallowLine[2] && (v[0] != v[8]) && (v[1] != v[8]);
		haveSteepLine[2]   = haveSteepLine[2] && (v[0] != v[4]) && (v[3] != v[4]);
		doLineBlend[2] = (  doLineBlend[2] ||
					  !((blendResult[3] != BLEND_NONE && !IsPixEqual(src[0], src[8])) ||
						(blendResult[1] != BLEND_NONE && !IsPixEqual(src[0], src[4])) ||
						(IsPixEqual(src[8], src[7]) && IsPixEqual(src[7], src[6]) && IsPixEqual(src[6], src[5]) && IsPixEqual(src[5], src[4]) && !IsPixEqual(src[0], src[6])) ) );
		blendPix[2] = ( DistYCbCr(src[0], src[5]) <= DistYCbCr(src[0], src[7]) ) ? src[5] : src[7];
		
		dst[3] = mix(dst[3], blendPix[2], (needBlend[2] && doLineBlend[2] && haveSteepLine[2]) ? 0.25f : 0.00f);
		dst[0] = mix(dst[0], blendPix[2], (needBlend[2]) ? ((doLineBlend[2]) ? ((haveShallowLine[2]) ? ((haveSteepLine[2]) ? 5.0f/6.0f : 0.75f) : ((haveSteepLine[2]) ? 0.75f : 0.50f)) : 1.0f - (M_PI_F/4.0f)) : 0.00f);
		dst[1] = mix(dst[1], blendPix[2], (needBlend[2] && doLineBlend[2] && haveShallowLine[2]) ? 0.25f : 0.00f);
		
		haveShallowLine[3] = haveShallowLine[3] && (v[0] != v[6]) && (v[7] != v[6]);
		haveSteepLine[3]   = haveSteepLine[3] && (v[0] != v[2]) && (v[1] != v[2]);
		doLineBlend[3] = (  doLineBlend[3] ||
					  !((blendResult[2] != BLEND_NONE && !IsPixEqual(src[0], src[6])) ||
						(blendResult[0] != BLEND_NONE && !IsPixEqual(src[0], src[2])) ||
						(IsPixEqual(src[6], src[5]) && IsPixEqual(src[5], src[4]) && IsPixEqual(src[4], src[3]) && IsPixEqual(src[3], src[2]) && !IsPixEqual(src[0], src[4])) ) );
		blendPix[3] = ( DistYCbCr(src[0], src[3]) <= DistYCbCr(src[0], src[5]) ) ? src[3] : src[5];
		
		dst[2] = mix(dst[2], blendPix[3], (needBlend[3] && doLineBlend[3] && haveSteepLine[3]) ? 0.25f : 0.00f);
		dst[3] = mix(dst[3], blendPix[3], (needBlend[3]) ? ((doLineBlend[3]) ? ((haveShallowLine[3]) ? ((haveSteepLine[3]) ? 5.0f/6.0f : 0.75f) : ((haveSteepLine[3]) ? 0.75f : 0.50f)) : 1.0f - (M_PI_F/4.0f)) : 0.00f);
		dst[0] = mix(dst[0], blendPix[3], (needBlend[3] && doLineBlend[3] && haveShallowLine[3]) ? 0.25f : 0.00f);
	}
	
	const uint2 outPosition = inPosition * 2;
	outTexture.write( float4(dst[0], 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(dst[1], 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(dst[3], 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(dst[2], 1.0f), outPosition + uint2(1, 1) );
}

//---------------------------------------
// Input Pixel Mapping:  --|21|22|23|--
//                       19|06|07|08|09
//                       18|05|00|01|10
//                       17|04|03|02|11
//                       --|15|14|13|--
//
// Output Pixel Mapping:    06|07|08
//                          05|00|01
//                          04|03|02
kernel void pixel_scaler_3xBRZ(const uint2 inPosition [[thread_position_in_grid]],
							   const texture2d<float, access::sample> inTexture [[texture(0)]],
							   texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src[25] = {
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2,-2)).rgb
	};
	
	const float v[9] = {
		reduce(src[0]),
		reduce(src[1]),
		reduce(src[2]),
		reduce(src[3]),
		reduce(src[4]),
		reduce(src[5]),
		reduce(src[6]),
		reduce(src[7]),
		reduce(src[8])
	};
	
	int4 blendResult = int4(BLEND_NONE);
	
	// Preprocess corners
	// Pixel Tap Mapping: --|--|--|--|--
	//                    --|--|07|08|--
	//                    --|05|00|01|10
	//                    --|04|03|02|11
	//                    --|--|14|13|--
	
	// Corner (1, 1)
	if ( !((v[0] == v[1] && v[3] == v[2]) || (v[0] == v[3] && v[1] == v[2])) )
	{
		const float dist_03_01 = DistYCbCr(src[ 4], src[ 0]) + DistYCbCr(src[ 0], src[ 8]) + DistYCbCr(src[14], src[ 2]) + DistYCbCr(src[ 2], src[10]) + (4.0 * DistYCbCr(src[ 3], src[ 1]));
		const float dist_00_02 = DistYCbCr(src[ 5], src[ 3]) + DistYCbCr(src[ 3], src[13]) + DistYCbCr(src[ 7], src[ 1]) + DistYCbCr(src[ 1], src[11]) + (4.0 * DistYCbCr(src[ 0], src[ 2]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_03_01) < dist_00_02;
		
		blendResult[2] = ((dist_03_01 < dist_00_02) && (v[0] != v[1]) && (v[0] != v[3])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	
	// Pixel Tap Mapping: --|--|--|--|--
	//                    --|06|07|--|--
	//                    18|05|00|01|--
	//                    17|04|03|02|--
	//                    --|15|14|--|--
	// Corner (0, 1)
	if ( !((v[5] == v[0] && v[4] == v[3]) || (v[5] == v[4] && v[0] == v[3])) )
	{
		const float dist_04_00 = DistYCbCr(src[17], src[ 5]) + DistYCbCr(src[ 5], src[ 7]) + DistYCbCr(src[15], src[ 3]) + DistYCbCr(src[ 3], src[ 1]) + (4.0 * DistYCbCr(src[ 4], src[ 0]));
		const float dist_05_03 = DistYCbCr(src[18], src[ 4]) + DistYCbCr(src[ 4], src[14]) + DistYCbCr(src[ 6], src[ 0]) + DistYCbCr(src[ 0], src[ 2]) + (4.0 * DistYCbCr(src[ 5], src[ 3]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_05_03) < dist_04_00;
		
		blendResult[3] = ((dist_04_00 > dist_05_03) && (v[0] != v[5]) && (v[0] != v[3])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	// Pixel Tap Mapping: --|--|22|23|--
	//                    --|06|07|08|09
	//                    --|05|00|01|10
	//                    --|--|03|02|--
	//                    --|--|--|--|--
	// Corner (1, 0)
	if ( !((v[7] == v[8] && v[0] == v[1]) || (v[7] == v[0] && v[8] == v[1])) )
	{
		const float dist_00_08 = DistYCbCr(src[ 5], src[ 7]) + DistYCbCr(src[ 7], src[23]) + DistYCbCr(src[ 3], src[ 1]) + DistYCbCr(src[ 1], src[ 9]) + (4.0 * DistYCbCr(src[ 0], src[ 8]));
		const float dist_07_01 = DistYCbCr(src[ 6], src[ 0]) + DistYCbCr(src[ 0], src[ 2]) + DistYCbCr(src[22], src[ 8]) + DistYCbCr(src[ 8], src[10]) + (4.0 * DistYCbCr(src[ 7], src[ 1]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_07_01) < dist_00_08;
		
		blendResult[1] = ((dist_00_08 > dist_07_01) && (v[0] != v[7]) && (v[0] != v[1])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	// Pixel Tap Mapping: --|21|22|--|--
	//                    19|06|07|08|--
	//                    18|05|00|01|--
	//                    --|04|03|--|--
	//                    --|--|--|--|--
	// Corner (0, 0)
	if ( !((v[6] == v[7] && v[5] == v[0]) || (v[6] == v[5] && v[7] == v[0])) )
	{
		const float dist_05_07 = DistYCbCr(src[18], src[ 6]) + DistYCbCr(src[ 6], src[22]) + DistYCbCr(src[ 4], src[ 0]) + DistYCbCr(src[ 0], src[ 8]) + (4.0 * DistYCbCr(src[ 5], src[ 7]));
		const float dist_06_00 = DistYCbCr(src[19], src[ 5]) + DistYCbCr(src[ 5], src[ 3]) + DistYCbCr(src[21], src[ 7]) + DistYCbCr(src[ 7], src[ 1]) + (4.0 * DistYCbCr(src[ 6], src[ 0]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_05_07) < dist_06_00;
		
		blendResult[0] = ((dist_05_07 < dist_06_00) && (v[0] != v[5]) && (v[0] != v[7])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	float3 dst[9] = {
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0]
	};
	
	// Scale pixel
	if (IsBlendingNeeded(blendResult))
	{
		float4 dist_01_04 = float4( DistYCbCr(src[1], src[4]), DistYCbCr(src[7], src[2]), DistYCbCr(src[5], src[8]), DistYCbCr(src[3], src[6]) );
		float4 dist_03_08 = float4( DistYCbCr(src[3], src[8]), DistYCbCr(src[1], src[6]), DistYCbCr(src[7], src[4]), DistYCbCr(src[5], src[2]) );
		bool4 haveShallowLine = (STEEP_DIRECTION_THRESHOLD * dist_01_04 <= dist_03_08);
		bool4 haveSteepLine = (STEEP_DIRECTION_THRESHOLD * dist_03_08 <= dist_01_04);
		bool4 needBlend = (blendResult.zyxw != int4(BLEND_NONE));
		bool4 doLineBlend = (blendResult.zyxw >= int4(BLEND_DOMINANT));
		float3 blendPix[4];
		
		haveShallowLine[0] = haveShallowLine[0] && (v[0] != v[4]) && (v[5] != v[4]);
		haveSteepLine[0]   = haveSteepLine[0] && (v[0] != v[8]) && (v[7] != v[8]);
		doLineBlend[0] = (  doLineBlend[0] ||
						   !((blendResult[1] != BLEND_NONE && !IsPixEqual(src[0], src[4])) ||
							 (blendResult[3] != BLEND_NONE && !IsPixEqual(src[0], src[8])) ||
							 (IsPixEqual(src[4], src[3]) && IsPixEqual(src[3], src[2]) && IsPixEqual(src[2], src[1]) && IsPixEqual(src[1], src[8]) && !IsPixEqual(src[0], src[2])) ) );
		blendPix[0] = ( DistYCbCr(src[0], src[1]) <= DistYCbCr(src[0], src[3]) ) ? src[1] : src[3];
		
		dst[1] = mix(dst[1], blendPix[0], (needBlend[0] && doLineBlend[0]) ? ((haveSteepLine[0]) ? 0.750f : ((haveShallowLine[0]) ? 0.250f : 0.125f)) : 0.000f);
		dst[2] = mix(dst[2], blendPix[0], (needBlend[0]) ? ((doLineBlend[0]) ? ((!haveShallowLine[0] && !haveSteepLine[0]) ? 0.875f : 1.000f) : 0.4545939598) : 0.000f);
		dst[3] = mix(dst[3], blendPix[0], (needBlend[0] && doLineBlend[0]) ? ((haveShallowLine[0]) ? 0.750f : ((haveSteepLine[0]) ? 0.250f : 0.125f)) : 0.000f);
		dst[4] = mix(dst[4], blendPix[0], (needBlend[0] && doLineBlend[0] && haveShallowLine[0]) ? 0.250f : 0.000f);
		dst[8] = mix(dst[8], blendPix[0], (needBlend[0] && doLineBlend[0] && haveSteepLine[0]) ? 0.250f : 0.000f);
		
		haveShallowLine[1] = haveShallowLine[1] && (v[0] != v[2]) && (v[3] != v[2]);
		haveSteepLine[1]   = haveSteepLine[1] && (v[0] != v[6]) && (v[5] != v[6]);
		doLineBlend[1] = (  doLineBlend[1] ||
					  !((blendResult[0] != BLEND_NONE && !IsPixEqual(src[0], src[2])) ||
						(blendResult[2] != BLEND_NONE && !IsPixEqual(src[0], src[6])) ||
						(IsPixEqual(src[2], src[1]) && IsPixEqual(src[1], src[8]) && IsPixEqual(src[8], src[7]) && IsPixEqual(src[7], src[6]) && !IsPixEqual(src[0], src[8])) ) );
		blendPix[1] = ( DistYCbCr(src[0], src[7]) <= DistYCbCr(src[0], src[1]) ) ? src[7] : src[1];
		
		dst[7] = mix(dst[7], blendPix[1], (needBlend[1] && doLineBlend[1]) ? ((haveSteepLine[1]) ? 0.750f : ((haveShallowLine[1]) ? 0.250f : 0.125f)) : 0.000f);
		dst[8] = mix(dst[8], blendPix[1], (needBlend[1]) ? ((doLineBlend[1]) ? ((!haveShallowLine[1] && !haveSteepLine[1]) ? 0.875f : 1.000f) : 0.4545939598f) : 0.000f);
		dst[1] = mix(dst[1], blendPix[1], (needBlend[1] && doLineBlend[1]) ? ((haveShallowLine[1]) ? 0.750f : ((haveSteepLine[1]) ? 0.250f : 0.125f)) : 0.000f);
		dst[2] = mix(dst[2], blendPix[1], (needBlend[1] && doLineBlend[1] && haveShallowLine[1]) ? 0.250f : 0.000f);
		dst[6] = mix(dst[6], blendPix[1], (needBlend[1] && doLineBlend[1] && haveSteepLine[1]) ? 0.250f : 0.000f);
		
		haveShallowLine[2] = haveShallowLine[2] && (v[0] != v[8]) && (v[1] != v[8]);
		haveSteepLine[2]   = haveSteepLine[2] && (v[0] != v[4]) && (v[3] != v[4]);
		doLineBlend[2] = (  doLineBlend[2] ||
					  !((blendResult[3] != BLEND_NONE && !IsPixEqual(src[0], src[8])) ||
						(blendResult[1] != BLEND_NONE && !IsPixEqual(src[0], src[4])) ||
						(IsPixEqual(src[8], src[7]) && IsPixEqual(src[7], src[6]) && IsPixEqual(src[6], src[5]) && IsPixEqual(src[5], src[4]) && !IsPixEqual(src[0], src[6])) ) );
		blendPix[2] = ( DistYCbCr(src[0], src[5]) <= DistYCbCr(src[0], src[7]) ) ? src[5] : src[7];
		
		dst[5] = mix(dst[5], blendPix[2], (needBlend[2] && doLineBlend[2]) ? ((haveSteepLine[2]) ? 0.750f : ((haveShallowLine[2]) ? 0.250f : 0.125f)) : 0.000f);
		dst[6] = mix(dst[6], blendPix[2], (needBlend[2]) ? ((doLineBlend[2]) ? ((!haveShallowLine[2] && !haveSteepLine[2]) ? 0.875f : 1.000f) : 0.4545939598f) : 0.000f);
		dst[7] = mix(dst[7], blendPix[2], (needBlend[2] && doLineBlend[2]) ? ((haveShallowLine[2]) ? 0.750f : ((haveSteepLine[2]) ? 0.250f : 0.125f)) : 0.000f);
		dst[8] = mix(dst[8], blendPix[2], (needBlend[2] && doLineBlend[2] && haveShallowLine[2]) ? 0.250f : 0.000f);
		dst[4] = mix(dst[4], blendPix[2], (needBlend[2] && doLineBlend[2] && haveSteepLine[2]) ? 0.250f : 0.000f);
		
		haveShallowLine[3] = haveShallowLine[3] && (v[0] != v[6]) && (v[7] != v[6]);
		haveSteepLine[3]   = haveSteepLine[3] && (v[0] != v[2]) && (v[1] != v[2]);
		doLineBlend[3] = (  doLineBlend[3] ||
					  !((blendResult[2] != BLEND_NONE && !IsPixEqual(src[0], src[6])) ||
						(blendResult[0] != BLEND_NONE && !IsPixEqual(src[0], src[2])) ||
						(IsPixEqual(src[6], src[5]) && IsPixEqual(src[5], src[4]) && IsPixEqual(src[4], src[3]) && IsPixEqual(src[3], src[2]) && !IsPixEqual(src[0], src[4])) ) );
		blendPix[3] = ( DistYCbCr(src[0], src[3]) <= DistYCbCr(src[0], src[5]) ) ? src[3] : src[5];
		
		dst[3] = mix(dst[3], blendPix[3], (needBlend[3] && doLineBlend[3]) ? ((haveSteepLine[3]) ? 0.750f : ((haveShallowLine[3]) ? 0.250f : 0.125f)) : 0.000f);
		dst[4] = mix(dst[4], blendPix[3], (needBlend[3]) ? ((doLineBlend[3]) ? ((!haveShallowLine[3] && !haveSteepLine[3]) ? 0.875f : 1.000f) : 0.4545939598f) : 0.000f);
		dst[5] = mix(dst[5], blendPix[3], (needBlend[3] && doLineBlend[3]) ? ((haveShallowLine[3]) ? 0.750f : ((haveSteepLine[3]) ? 0.250f : 0.125f)) : 0.000f);
		dst[6] = mix(dst[6], blendPix[3], (needBlend[3] && doLineBlend[3] && haveShallowLine[3]) ? 0.250f : 0.000f);
		dst[2] = mix(dst[2], blendPix[3], (needBlend[3] && doLineBlend[3] && haveSteepLine[3]) ? 0.250f : 0.000f);
	}
	
	const uint2 outPosition = inPosition * 3;
	outTexture.write( float4(dst[6], 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(dst[7], 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(dst[8], 1.0f), outPosition + uint2(2, 0) );
	outTexture.write( float4(dst[5], 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(dst[0], 1.0f), outPosition + uint2(1, 1) );
	outTexture.write( float4(dst[1], 1.0f), outPosition + uint2(2, 1) );
	outTexture.write( float4(dst[4], 1.0f), outPosition + uint2(0, 2) );
	outTexture.write( float4(dst[3], 1.0f), outPosition + uint2(1, 2) );
	outTexture.write( float4(dst[2], 1.0f), outPosition + uint2(2, 2) );
}

//---------------------------------------
// Input Pixel Mapping:  --|21|22|23|--
//                       19|06|07|08|09
//                       18|05|00|01|10
//                       17|04|03|02|11
//                       --|15|14|13|--
//
// Output Pixel Mapping:  00|01|02|03
//                        04|05|06|07
//                        08|09|10|11
//                        12|13|14|15
kernel void pixel_scaler_4xBRZ(const uint2 inPosition [[thread_position_in_grid]],
							   const texture2d<float, access::sample> inTexture [[texture(0)]],
							   texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src[25] = {
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2,-2)).rgb
	};
	
	const float v[9] = {
		reduce(src[0]),
		reduce(src[1]),
		reduce(src[2]),
		reduce(src[3]),
		reduce(src[4]),
		reduce(src[5]),
		reduce(src[6]),
		reduce(src[7]),
		reduce(src[8])
	};
	
	int4 blendResult = int4(BLEND_NONE);
	
	// Preprocess corners
	// Pixel Tap Mapping: --|--|--|--|--
	//                    --|--|07|08|--
	//                    --|05|00|01|10
	//                    --|04|03|02|11
	//                    --|--|14|13|--
	
	// Corner (1, 1)
	if ( !((v[0] == v[1] && v[3] == v[2]) || (v[0] == v[3] && v[1] == v[2])) )
	{
		const float dist_03_01 = DistYCbCr(src[ 4], src[ 0]) + DistYCbCr(src[ 0], src[ 8]) + DistYCbCr(src[14], src[ 2]) + DistYCbCr(src[ 2], src[10]) + (4.0 * DistYCbCr(src[ 3], src[ 1]));
		const float dist_00_02 = DistYCbCr(src[ 5], src[ 3]) + DistYCbCr(src[ 3], src[13]) + DistYCbCr(src[ 7], src[ 1]) + DistYCbCr(src[ 1], src[11]) + (4.0 * DistYCbCr(src[ 0], src[ 2]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_03_01) < dist_00_02;
		
		blendResult[2] = ((dist_03_01 < dist_00_02) && (v[0] != v[1]) && (v[0] != v[3])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	
	// Pixel Tap Mapping: --|--|--|--|--
	//                    --|06|07|--|--
	//                    18|05|00|01|--
	//                    17|04|03|02|--
	//                    --|15|14|--|--
	// Corner (0, 1)
	if ( !((v[5] == v[0] && v[4] == v[3]) || (v[5] == v[4] && v[0] == v[3])) )
	{
		const float dist_04_00 = DistYCbCr(src[17], src[ 5]) + DistYCbCr(src[ 5], src[ 7]) + DistYCbCr(src[15], src[ 3]) + DistYCbCr(src[ 3], src[ 1]) + (4.0 * DistYCbCr(src[ 4], src[ 0]));
		const float dist_05_03 = DistYCbCr(src[18], src[ 4]) + DistYCbCr(src[ 4], src[14]) + DistYCbCr(src[ 6], src[ 0]) + DistYCbCr(src[ 0], src[ 2]) + (4.0 * DistYCbCr(src[ 5], src[ 3]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_05_03) < dist_04_00;
		
		blendResult[3] = ((dist_04_00 > dist_05_03) && (v[0] != v[5]) && (v[0] != v[3])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	// Pixel Tap Mapping: --|--|22|23|--
	//                    --|06|07|08|09
	//                    --|05|00|01|10
	//                    --|--|03|02|--
	//                    --|--|--|--|--
	// Corner (1, 0)
	if ( !((v[7] == v[8] && v[0] == v[1]) || (v[7] == v[0] && v[8] == v[1])) )
	{
		const float dist_00_08 = DistYCbCr(src[ 5], src[ 7]) + DistYCbCr(src[ 7], src[23]) + DistYCbCr(src[ 3], src[ 1]) + DistYCbCr(src[ 1], src[ 9]) + (4.0 * DistYCbCr(src[ 0], src[ 8]));
		const float dist_07_01 = DistYCbCr(src[ 6], src[ 0]) + DistYCbCr(src[ 0], src[ 2]) + DistYCbCr(src[22], src[ 8]) + DistYCbCr(src[ 8], src[10]) + (4.0 * DistYCbCr(src[ 7], src[ 1]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_07_01) < dist_00_08;
		
		blendResult[1] = ((dist_00_08 > dist_07_01) && (v[0] != v[7]) && (v[0] != v[1])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	// Pixel Tap Mapping: --|21|22|--|--
	//                    19|06|07|08|--
	//                    18|05|00|01|--
	//                    --|04|03|--|--
	//                    --|--|--|--|--
	// Corner (0, 0)
	if ( !((v[6] == v[7] && v[5] == v[0]) || (v[6] == v[5] && v[7] == v[0])) )
	{
		const float dist_05_07 = DistYCbCr(src[18], src[ 6]) + DistYCbCr(src[ 6], src[22]) + DistYCbCr(src[ 4], src[ 0]) + DistYCbCr(src[ 0], src[ 8]) + (4.0 * DistYCbCr(src[ 5], src[ 7]));
		const float dist_06_00 = DistYCbCr(src[19], src[ 5]) + DistYCbCr(src[ 5], src[ 3]) + DistYCbCr(src[21], src[ 7]) + DistYCbCr(src[ 7], src[ 1]) + (4.0 * DistYCbCr(src[ 6], src[ 0]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_05_07) < dist_06_00;
		
		blendResult[0] = ((dist_05_07 < dist_06_00) && (v[0] != v[5]) && (v[0] != v[7])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	float3 dst[16] = {
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0]
	};
	
	// Scale pixel
	if (IsBlendingNeeded(blendResult))
	{
		const float4 dist_01_04 = float4( DistYCbCr(src[1], src[4]), DistYCbCr(src[7], src[2]), DistYCbCr(src[5], src[8]), DistYCbCr(src[3], src[6]) );
		const float4 dist_03_08 = float4( DistYCbCr(src[3], src[8]), DistYCbCr(src[1], src[6]), DistYCbCr(src[7], src[4]), DistYCbCr(src[5], src[2]) );
		const bool4 haveShallowLine = (STEEP_DIRECTION_THRESHOLD * dist_01_04 <= dist_03_08);
		const bool4 haveSteepLine = (STEEP_DIRECTION_THRESHOLD * dist_03_08 <= dist_01_04);
		const bool4 needBlend = (blendResult.zyxw != int4(BLEND_NONE));
		const bool4 doLineBlend = (blendResult.zyxw >= int4(BLEND_DOMINANT));
		float3 blendPix[4];
		
		haveShallowLine[0] = haveShallowLine[0] && (v[0] != v[4]) && (v[5] != v[4]);
		haveSteepLine[0]   = haveSteepLine[0] && (v[0] != v[8]) && (v[7] != v[8]);
		doLineBlend[0] = (  doLineBlend[0] ||
						   !((blendResult[1] != BLEND_NONE && !IsPixEqual(src[0], src[4])) ||
							 (blendResult[3] != BLEND_NONE && !IsPixEqual(src[0], src[8])) ||
							 (IsPixEqual(src[4], src[3]) && IsPixEqual(src[3], src[2]) && IsPixEqual(src[2], src[1]) && IsPixEqual(src[1], src[8]) && !IsPixEqual(src[0], src[2])) ) );
		blendPix[0] = ( DistYCbCr(src[0], src[1]) <= DistYCbCr(src[0], src[3]) ) ? src[1] : src[3];
		
		haveShallowLine[1] = haveShallowLine[1] && (v[0] != v[2]) && (v[3] != v[2]);
		haveSteepLine[1]   = haveSteepLine[1] && (v[0] != v[6]) && (v[5] != v[6]);
		doLineBlend[1] = (  doLineBlend[1] ||
					  !((blendResult[0] != BLEND_NONE && !IsPixEqual(src[0], src[2])) ||
						(blendResult[2] != BLEND_NONE && !IsPixEqual(src[0], src[6])) ||
						(IsPixEqual(src[2], src[1]) && IsPixEqual(src[1], src[8]) && IsPixEqual(src[8], src[7]) && IsPixEqual(src[7], src[6]) && !IsPixEqual(src[0], src[8])) ) );
		blendPix[1] = ( DistYCbCr(src[0], src[7]) <= DistYCbCr(src[0], src[1]) ) ? src[7] : src[1];
		
		haveShallowLine[2] = haveShallowLine[2] && (v[0] != v[8]) && (v[1] != v[8]);
		haveSteepLine[2]   = haveSteepLine[2] && (v[0] != v[4]) && (v[3] != v[4]);
		doLineBlend[2] = (  doLineBlend[2] ||
					  !((blendResult[3] != BLEND_NONE && !IsPixEqual(src[0], src[8])) ||
						(blendResult[1] != BLEND_NONE && !IsPixEqual(src[0], src[4])) ||
						(IsPixEqual(src[8], src[7]) && IsPixEqual(src[7], src[6]) && IsPixEqual(src[6], src[5]) && IsPixEqual(src[5], src[4]) && !IsPixEqual(src[0], src[6])) ) );
		blendPix[2] = ( DistYCbCr(src[0], src[5]) <= DistYCbCr(src[0], src[7]) ) ? src[5] : src[7];
		
		haveShallowLine[3] = haveShallowLine[3] && (v[0] != v[6]) && (v[7] != v[6]);
		haveSteepLine[3]   = haveSteepLine[3] && (v[0] != v[2]) && (v[1] != v[2]);
		doLineBlend[3] = (  doLineBlend[3] ||
					  !((blendResult[2] != BLEND_NONE && !IsPixEqual(src[0], src[6])) ||
						(blendResult[0] != BLEND_NONE && !IsPixEqual(src[0], src[2])) ||
						(IsPixEqual(src[6], src[5]) && IsPixEqual(src[5], src[4]) && IsPixEqual(src[4], src[3]) && IsPixEqual(src[3], src[2]) && !IsPixEqual(src[0], src[4])) ) );
		blendPix[3] = ( DistYCbCr(src[0], src[3]) <= DistYCbCr(src[0], src[5]) ) ? src[3] : src[5];
		
		dst[ 0] = mix(dst[ 0], blendPix[1], (needBlend[1] && doLineBlend[1] && haveSteepLine[1]) ? 0.25f : 0.00f);
		dst[ 0] = mix(dst[ 0], blendPix[2], (needBlend[2]) ? ((doLineBlend[2]) ? 1.00f : 0.6848532563f) : 0.00f);
		dst[ 0] = mix(dst[ 0], blendPix[3], (needBlend[3] && doLineBlend[3] && haveShallowLine[3]) ? 0.25f : 0.00f);

		dst[ 1] = mix(dst[ 1], blendPix[1], (needBlend[1] && doLineBlend[1] && haveSteepLine[1]) ? 0.75f : 0.00f);
		dst[ 1] = mix(dst[ 1], blendPix[2], (needBlend[2]) ? ((doLineBlend[2]) ? ((haveShallowLine[2]) ? 1.00f : ((haveSteepLine[2]) ? 0.75f : 0.50f)) : 0.08677704501f) : 0.00f);

		dst[ 2] = mix(dst[ 2], blendPix[1], (needBlend[1]) ? ((doLineBlend[1]) ? ((haveSteepLine[1]) ? 1.00f : ((haveShallowLine[1]) ? 0.75f : 0.50f)) : 0.08677704501f) : 0.00f);
		dst[ 2] = mix(dst[ 2], blendPix[2], (needBlend[2] && doLineBlend[2] && haveShallowLine[2]) ? 0.75f : 0.00f);

		dst[ 3] = mix(dst[ 3], blendPix[0], (needBlend[0] && doLineBlend[0] && haveSteepLine[0]) ? 0.25f : 0.00f);
		dst[ 3] = mix(dst[ 3], blendPix[1], (needBlend[1]) ? ((doLineBlend[1]) ? 1.00f : 0.6848532563f) : 0.00f);
		dst[ 3] = mix(dst[ 3], blendPix[2], (needBlend[2] && doLineBlend[2] && haveShallowLine[2]) ? 0.25f : 0.00f);

		dst[ 4] = mix(dst[ 4], blendPix[2], (needBlend[2]) ? ((doLineBlend[2]) ? ((haveSteepLine[2]) ? 1.00f : ((haveShallowLine[2]) ? 0.75f : 0.50f)) : 0.08677704501f) : 0.00f);
		dst[ 4] = mix(dst[ 4], blendPix[3], (needBlend[3] && doLineBlend[3] && haveShallowLine[3]) ? 0.75f : 0.00f);

		dst[ 5] = mix(dst[ 5], blendPix[2], (needBlend[2] && doLineBlend[2]) ? ((haveShallowLine[2]) ? ((haveSteepLine[2]) ? 1.0f/3.0f : 0.25f) : ((haveSteepLine[2]) ? 0.25f : 0.00f)) : 0.00f);

		dst[ 6] = mix(dst[ 6], blendPix[1], (needBlend[1] && doLineBlend[1]) ? ((haveShallowLine[1]) ? ((haveSteepLine[1]) ? 1.0f/3.0f : 0.25f) : ((haveSteepLine[1]) ? 0.25f : 0.00f)) : 0.00f);

		dst[ 7] = mix(dst[ 7], blendPix[0], (needBlend[0] && doLineBlend[0] && haveSteepLine[0]) ? 0.75f : 0.00f);
		dst[ 7] = mix(dst[ 7], blendPix[1], (needBlend[1]) ? ((doLineBlend[1]) ? ((haveShallowLine[1]) ? 1.00f : ((haveSteepLine[1]) ? 0.75f : 0.50f)) : 0.08677704501f) : 0.00f);

		dst[ 8] = mix(dst[ 8], blendPix[2], (needBlend[2] && doLineBlend[2] && haveSteepLine[2]) ? 0.75f : 0.00f);
		dst[ 8] = mix(dst[ 8], blendPix[3], (needBlend[3]) ? ((doLineBlend[3]) ? ((haveShallowLine[3]) ? 1.00f : ((haveSteepLine[3]) ? 0.75f : 0.50f)) : 0.08677704501f) : 0.00f);

		dst[ 9] = mix(dst[ 9], blendPix[3], (needBlend[3] && doLineBlend[3]) ? ((haveShallowLine[3]) ? ((haveSteepLine[3]) ? 1.0f/3.0f : 0.25f) : ((haveSteepLine[3]) ? 0.25f : 0.00f)) : 0.00f);

		dst[10] = mix(dst[10], blendPix[0], (needBlend[0] && doLineBlend[0]) ? ((haveShallowLine[0]) ? ((haveSteepLine[0]) ? 1.0f/3.0f : 0.25f) : ((haveSteepLine[0]) ? 0.25f : 0.00f)) : 0.00f);

		dst[11] = mix(dst[11], blendPix[0], (needBlend[0]) ? ((doLineBlend[0]) ? ((haveSteepLine[0]) ? 1.00f : ((haveShallowLine[0]) ? 0.75f : 0.50f)) : 0.08677704501f) : 0.00f);
		dst[11] = mix(dst[11], blendPix[1], (needBlend[1] && doLineBlend[1] && haveShallowLine[1]) ? 0.75f : 0.00f);

		dst[12] = mix(dst[12], blendPix[0], (needBlend[0] && doLineBlend[0] && haveShallowLine[0]) ? 0.25f : 0.00f);
		dst[12] = mix(dst[12], blendPix[2], (needBlend[2] && doLineBlend[2] && haveSteepLine[2]) ? 0.25f : 0.00f);
		dst[12] = mix(dst[12], blendPix[3], (needBlend[3]) ? ((doLineBlend[3]) ? 1.00f : 0.6848532563f) : 0.00f);

		dst[13] = mix(dst[13], blendPix[0], (needBlend[0] && doLineBlend[0] && haveShallowLine[0]) ? 0.75f : 0.00f);
		dst[13] = mix(dst[13], blendPix[3], (needBlend[3]) ? ((doLineBlend[3]) ? ((haveSteepLine[3]) ? 1.00f : ((haveShallowLine[3]) ? 0.75f : 0.50f)) : 0.08677704501f) : 0.00f);

		dst[14] = mix(dst[14], blendPix[0], (needBlend[0]) ? ((doLineBlend[0]) ? ((haveShallowLine[0]) ? 1.00f : ((haveSteepLine[0]) ? 0.75f : 0.50f)) : 0.08677704501f) : 0.00f);
		dst[14] = mix(dst[14], blendPix[3], (needBlend[3] && doLineBlend[3] && haveSteepLine[3]) ? 0.75f : 0.00f);

		dst[15] = mix(dst[15], blendPix[0], (needBlend[0]) ? ((doLineBlend[0]) ? 1.00f : 0.6848532563f) : 0.00f);
		dst[15] = mix(dst[15], blendPix[1], (needBlend[1] && doLineBlend[1] && haveShallowLine[1]) ? 0.25f : 0.00f);
		dst[15] = mix(dst[15], blendPix[3], (needBlend[3] && doLineBlend[3] && haveSteepLine[3]) ? 0.25f : 0.00f);
	}
	
	const uint2 outPosition = inPosition * 4;
	outTexture.write( float4(dst[ 0], 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(dst[ 1], 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(dst[ 2], 1.0f), outPosition + uint2(2, 0) );
	outTexture.write( float4(dst[ 3], 1.0f), outPosition + uint2(3, 0) );
	outTexture.write( float4(dst[ 4], 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(dst[ 5], 1.0f), outPosition + uint2(1, 1) );
	outTexture.write( float4(dst[ 6], 1.0f), outPosition + uint2(2, 1) );
	outTexture.write( float4(dst[ 7], 1.0f), outPosition + uint2(3, 1) );
	outTexture.write( float4(dst[ 8], 1.0f), outPosition + uint2(0, 2) );
	outTexture.write( float4(dst[ 9], 1.0f), outPosition + uint2(1, 2) );
	outTexture.write( float4(dst[10], 1.0f), outPosition + uint2(2, 2) );
	outTexture.write( float4(dst[11], 1.0f), outPosition + uint2(3, 2) );
	outTexture.write( float4(dst[12], 1.0f), outPosition + uint2(0, 3) );
	outTexture.write( float4(dst[13], 1.0f), outPosition + uint2(1, 3) );
	outTexture.write( float4(dst[14], 1.0f), outPosition + uint2(2, 3) );
	outTexture.write( float4(dst[15], 1.0f), outPosition + uint2(3, 3) );
}

//---------------------------------------
// Input Pixel Mapping:  --|21|22|23|--
//                       19|06|07|08|09
//                       18|05|00|01|10
//                       17|04|03|02|11
//                       --|15|14|13|--
//
// Output Pixel Mapping: 00|01|02|03|04
//                       05|06|07|08|09
//                       10|11|12|13|14
//                       15|16|17|18|19
//                       20|21|22|23|24
kernel void pixel_scaler_5xBRZ(const uint2 inPosition [[thread_position_in_grid]],
							   const texture2d<float, access::sample> inTexture [[texture(0)]],
							   texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src[25] = {
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2,-2)).rgb
	};
	
	const float v[9] = {
		reduce(src[0]),
		reduce(src[1]),
		reduce(src[2]),
		reduce(src[3]),
		reduce(src[4]),
		reduce(src[5]),
		reduce(src[6]),
		reduce(src[7]),
		reduce(src[8])
	};
	
	int4 blendResult = int4(BLEND_NONE);
	
	// Preprocess corners
	// Pixel Tap Mapping: --|--|--|--|--
	//                    --|--|07|08|--
	//                    --|05|00|01|10
	//                    --|04|03|02|11
	//                    --|--|14|13|--
	
	// Corner (1, 1)
	if ( !((v[0] == v[1] && v[3] == v[2]) || (v[0] == v[3] && v[1] == v[2])) )
	{
		const float dist_03_01 = DistYCbCr(src[ 4], src[ 0]) + DistYCbCr(src[ 0], src[ 8]) + DistYCbCr(src[14], src[ 2]) + DistYCbCr(src[ 2], src[10]) + (4.0 * DistYCbCr(src[ 3], src[ 1]));
		const float dist_00_02 = DistYCbCr(src[ 5], src[ 3]) + DistYCbCr(src[ 3], src[13]) + DistYCbCr(src[ 7], src[ 1]) + DistYCbCr(src[ 1], src[11]) + (4.0 * DistYCbCr(src[ 0], src[ 2]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_03_01) < dist_00_02;
		
		blendResult[2] = ((dist_03_01 < dist_00_02) && (v[0] != v[1]) && (v[0] != v[3])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	
	// Pixel Tap Mapping: --|--|--|--|--
	//                    --|06|07|--|--
	//                    18|05|00|01|--
	//                    17|04|03|02|--
	//                    --|15|14|--|--
	// Corner (0, 1)
	if ( !((v[5] == v[0] && v[4] == v[3]) || (v[5] == v[4] && v[0] == v[3])) )
	{
		const float dist_04_00 = DistYCbCr(src[17], src[ 5]) + DistYCbCr(src[ 5], src[ 7]) + DistYCbCr(src[15], src[ 3]) + DistYCbCr(src[ 3], src[ 1]) + (4.0 * DistYCbCr(src[ 4], src[ 0]));
		const float dist_05_03 = DistYCbCr(src[18], src[ 4]) + DistYCbCr(src[ 4], src[14]) + DistYCbCr(src[ 6], src[ 0]) + DistYCbCr(src[ 0], src[ 2]) + (4.0 * DistYCbCr(src[ 5], src[ 3]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_05_03) < dist_04_00;
		
		blendResult[3] = ((dist_04_00 > dist_05_03) && (v[0] != v[5]) && (v[0] != v[3])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	// Pixel Tap Mapping: --|--|22|23|--
	//                    --|06|07|08|09
	//                    --|05|00|01|10
	//                    --|--|03|02|--
	//                    --|--|--|--|--
	// Corner (1, 0)
	if ( !((v[7] == v[8] && v[0] == v[1]) || (v[7] == v[0] && v[8] == v[1])) )
	{
		const float dist_00_08 = DistYCbCr(src[ 5], src[ 7]) + DistYCbCr(src[ 7], src[23]) + DistYCbCr(src[ 3], src[ 1]) + DistYCbCr(src[ 1], src[ 9]) + (4.0 * DistYCbCr(src[ 0], src[ 8]));
		const float dist_07_01 = DistYCbCr(src[ 6], src[ 0]) + DistYCbCr(src[ 0], src[ 2]) + DistYCbCr(src[22], src[ 8]) + DistYCbCr(src[ 8], src[10]) + (4.0 * DistYCbCr(src[ 7], src[ 1]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_07_01) < dist_00_08;
		
		blendResult[1] = ((dist_00_08 > dist_07_01) && (v[0] != v[7]) && (v[0] != v[1])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	// Pixel Tap Mapping: --|21|22|--|--
	//                    19|06|07|08|--
	//                    18|05|00|01|--
	//                    --|04|03|--|--
	//                    --|--|--|--|--
	// Corner (0, 0)
	if ( !((v[6] == v[7] && v[5] == v[0]) || (v[6] == v[5] && v[7] == v[0])) )
	{
		const float dist_05_07 = DistYCbCr(src[18], src[ 6]) + DistYCbCr(src[ 6], src[22]) + DistYCbCr(src[ 4], src[ 0]) + DistYCbCr(src[ 0], src[ 8]) + (4.0 * DistYCbCr(src[ 5], src[ 7]));
		const float dist_06_00 = DistYCbCr(src[19], src[ 5]) + DistYCbCr(src[ 5], src[ 3]) + DistYCbCr(src[21], src[ 7]) + DistYCbCr(src[ 7], src[ 1]) + (4.0 * DistYCbCr(src[ 6], src[ 0]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_05_07) < dist_06_00;
		
		blendResult[0] = ((dist_05_07 < dist_06_00) && (v[0] != v[5]) && (v[0] != v[7])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	float3 dst[25] = {
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0]
	};
	
	// Scale pixel
	if (IsBlendingNeeded(blendResult))
	{
		const float4 dist_01_04 = float4( DistYCbCr(src[1], src[4]), DistYCbCr(src[7], src[2]), DistYCbCr(src[5], src[8]), DistYCbCr(src[3], src[6]) );
		const float4 dist_03_08 = float4( DistYCbCr(src[3], src[8]), DistYCbCr(src[1], src[6]), DistYCbCr(src[7], src[4]), DistYCbCr(src[5], src[2]) );
		const bool4 haveShallowLine = (STEEP_DIRECTION_THRESHOLD * dist_01_04 <= dist_03_08);
		const bool4 haveSteepLine = (STEEP_DIRECTION_THRESHOLD * dist_03_08 <= dist_01_04);
		const bool4 needBlend = (blendResult.zyxw != int4(BLEND_NONE));
		const bool4 doLineBlend = (blendResult.zyxw >= int4(BLEND_DOMINANT));
		float3 blendPix[4];
		
		haveShallowLine[0] = haveShallowLine[0] && (v[0] != v[4]) && (v[5] != v[4]);
		haveSteepLine[0]   = haveSteepLine[0] && (v[0] != v[8]) && (v[7] != v[8]);
		doLineBlend[0] = (  doLineBlend[0] ||
						   !((blendResult[1] != BLEND_NONE && !IsPixEqual(src[0], src[4])) ||
							 (blendResult[3] != BLEND_NONE && !IsPixEqual(src[0], src[8])) ||
							 (IsPixEqual(src[4], src[3]) && IsPixEqual(src[3], src[2]) && IsPixEqual(src[2], src[1]) && IsPixEqual(src[1], src[8]) && !IsPixEqual(src[0], src[2])) ) );
		blendPix[0] = ( DistYCbCr(src[0], src[1]) <= DistYCbCr(src[0], src[3]) ) ? src[1] : src[3];
		
		haveShallowLine[1] = haveShallowLine[1] && (v[0] != v[2]) && (v[3] != v[2]);
		haveSteepLine[1]   = haveSteepLine[1] && (v[0] != v[6]) && (v[5] != v[6]);
		doLineBlend[1] = (  doLineBlend[1] ||
					  !((blendResult[0] != BLEND_NONE && !IsPixEqual(src[0], src[2])) ||
						(blendResult[2] != BLEND_NONE && !IsPixEqual(src[0], src[6])) ||
						(IsPixEqual(src[2], src[1]) && IsPixEqual(src[1], src[8]) && IsPixEqual(src[8], src[7]) && IsPixEqual(src[7], src[6]) && !IsPixEqual(src[0], src[8])) ) );
		blendPix[1] = ( DistYCbCr(src[0], src[7]) <= DistYCbCr(src[0], src[1]) ) ? src[7] : src[1];
		
		haveShallowLine[2] = haveShallowLine[2] && (v[0] != v[8]) && (v[1] != v[8]);
		haveSteepLine[2]   = haveSteepLine[2] && (v[0] != v[4]) && (v[3] != v[4]);
		doLineBlend[2] = (  doLineBlend[2] ||
					  !((blendResult[3] != BLEND_NONE && !IsPixEqual(src[0], src[8])) ||
						(blendResult[1] != BLEND_NONE && !IsPixEqual(src[0], src[4])) ||
						(IsPixEqual(src[8], src[7]) && IsPixEqual(src[7], src[6]) && IsPixEqual(src[6], src[5]) && IsPixEqual(src[5], src[4]) && !IsPixEqual(src[0], src[6])) ) );
		blendPix[2] = ( DistYCbCr(src[0], src[5]) <= DistYCbCr(src[0], src[7]) ) ? src[5] : src[7];
		
		haveShallowLine[3] = haveShallowLine[3] && (v[0] != v[6]) && (v[7] != v[6]);
		haveSteepLine[3]   = haveSteepLine[3] && (v[0] != v[2]) && (v[1] != v[2]);
		doLineBlend[3] = (  doLineBlend[3] ||
					  !((blendResult[2] != BLEND_NONE && !IsPixEqual(src[0], src[6])) ||
						(blendResult[0] != BLEND_NONE && !IsPixEqual(src[0], src[2])) ||
						(IsPixEqual(src[6], src[5]) && IsPixEqual(src[5], src[4]) && IsPixEqual(src[4], src[3]) && IsPixEqual(src[3], src[2]) && !IsPixEqual(src[0], src[4])) ) );
		blendPix[3] = ( DistYCbCr(src[0], src[3]) <= DistYCbCr(src[0], src[5]) ) ? src[3] : src[5];
		
		dst[ 0] = mix(dst[ 0], blendPix[1], (needBlend[1] && doLineBlend[1] && haveSteepLine[1]) ? 0.250f : 0.000f);
		dst[ 0] = mix(dst[ 0], blendPix[2], (needBlend[2]) ? ((doLineBlend[2]) ? 1.000f : 0.8631434088f) : 0.000f);
		dst[ 0] = mix(dst[ 0], blendPix[3], (needBlend[3] && doLineBlend[3] && haveShallowLine[3]) ? 0.250f : 0.000f);

		dst[ 1] = mix(dst[ 1], blendPix[1], (needBlend[1] && doLineBlend[1] && haveSteepLine[1]) ? 0.750f : 0.000f);
		dst[ 1] = mix(dst[ 1], blendPix[2], (needBlend[2]) ? ((doLineBlend[2]) ? ((!haveShallowLine[2] && !haveSteepLine[2]) ? 0.875f : 1.000f) : 0.2306749731f) : 0.000f);

		dst[ 2] = mix(dst[ 2], blendPix[1], (needBlend[1] && doLineBlend[1]) ? ((haveSteepLine[1]) ? 1.000f : ((haveShallowLine[1]) ? 0.250f : 0.125f)) : 0.000f);
		dst[ 2] = mix(dst[ 2], blendPix[2], (needBlend[2] && doLineBlend[2]) ? ((haveShallowLine[2]) ? 1.000f : ((haveSteepLine[2]) ? 0.250f : 0.125f)) : 0.000f);

		dst[ 3] = mix(dst[ 3], blendPix[1], (needBlend[1]) ? ((doLineBlend[1]) ? ((!haveShallowLine[1] && !haveSteepLine[1]) ? 0.875f : 1.000f) : 0.2306749731f) : 0.000f);
		dst[ 3] = mix(dst[ 3], blendPix[2], (needBlend[2] && doLineBlend[2] && haveShallowLine[2]) ? 0.750f : 0.000f);

		dst[ 4] = mix(dst[ 4], blendPix[0], (needBlend[0] && doLineBlend[0] && haveSteepLine[0]) ? 0.250f : 0.000f);
		dst[ 4] = mix(dst[ 4], blendPix[1], (needBlend[1]) ? ((doLineBlend[1]) ? 1.000f : 0.8631434088f) : 0.000f);
		dst[ 4] = mix(dst[ 4], blendPix[2], (needBlend[2] && doLineBlend[2] && haveShallowLine[2]) ? 0.250f : 0.000f);

		dst[ 5] = mix(dst[ 5], blendPix[2], (needBlend[2]) ? ((doLineBlend[2]) ? ((!haveShallowLine[2] && !haveSteepLine[2]) ? 0.875f : 1.000f) : 0.2306749731f) : 0.000f);
		dst[ 5] = mix(dst[ 5], blendPix[3], (needBlend[3] && doLineBlend[3] && haveShallowLine[3]) ? 0.750f : 0.000f);

		dst[ 6] = mix(dst[ 6], blendPix[2], (needBlend[2] && doLineBlend[2]) ? ((haveShallowLine[2]) ? ((haveSteepLine[2]) ? 2.0f/3.0f : 0.750f) : ((haveSteepLine[2]) ? 0.750f : 0.125f)) : 0.000f);

		dst[ 7] = mix(dst[ 7], blendPix[1], (needBlend[1] && doLineBlend[1] && haveSteepLine[1]) ? 0.250f : 0.000f);
		dst[ 7] = mix(dst[ 7], blendPix[2], (needBlend[2] && doLineBlend[2] && haveShallowLine[2]) ? 0.250f : 0.000f);

		dst[ 8] = mix(dst[ 8], blendPix[1], (needBlend[1] && doLineBlend[1]) ? ((haveShallowLine[1]) ? ((haveSteepLine[1]) ? 2.0f/3.0f : 0.750f) : ((haveSteepLine[1]) ? 0.750f : 0.125f)) : 0.000f);

		dst[ 9] = mix(dst[ 9], blendPix[0], (needBlend[0] && doLineBlend[0] && haveSteepLine[0]) ? 0.750f : 0.000f);
		dst[ 9] = mix(dst[ 9], blendPix[1], (needBlend[1]) ? ((doLineBlend[1]) ? ((!haveShallowLine[1] && !haveSteepLine[1]) ? 0.875f : 1.000f) : 0.2306749731f) : 0.000f);

		dst[10] = mix(dst[10], blendPix[2], (needBlend[2] && doLineBlend[2]) ? ((haveSteepLine[2]) ? 1.000f : ((haveShallowLine[2]) ? 0.250f : 0.125f)) : 0.000f);
		dst[10] = mix(dst[10], blendPix[3], (needBlend[3] && doLineBlend[3]) ? ((haveShallowLine[3]) ? 1.000f : ((haveSteepLine[3]) ? 0.250f : 0.125f)) : 0.000f);

		dst[11] = mix(dst[11], blendPix[2], (needBlend[2] && doLineBlend[2] && haveSteepLine[2]) ? 0.250f : 0.000f);
		dst[11] = mix(dst[11], blendPix[3], (needBlend[3] && doLineBlend[3] && haveShallowLine[3]) ? 0.250f : 0.000f);

		dst[13] = mix(dst[13], blendPix[0], (needBlend[0] && doLineBlend[0] && haveSteepLine[0]) ? 0.250f : 0.000f);
		dst[13] = mix(dst[13], blendPix[1], (needBlend[1] && doLineBlend[1] && haveShallowLine[1]) ? 0.250f : 0.000f);

		dst[14] = mix(dst[14], blendPix[0], (needBlend[0] && doLineBlend[0]) ? ((haveSteepLine[0]) ? 1.000f : ((haveShallowLine[0]) ? 0.250f : 0.125f)) : 0.000f);
		dst[14] = mix(dst[14], blendPix[1], (needBlend[1] && doLineBlend[1]) ? ((haveShallowLine[1]) ? 1.000f : ((haveSteepLine[1]) ? 0.250f : 0.125f)) : 0.000f);

		dst[15] = mix(dst[15], blendPix[2], (needBlend[2] && doLineBlend[2] && haveSteepLine[2]) ? 0.750f : 0.000f);
		dst[15] = mix(dst[15], blendPix[3], (needBlend[3]) ? ((doLineBlend[3]) ? ((!haveShallowLine[3] && !haveSteepLine[3]) ? 0.875f : 1.000f) : 0.2306749731f) : 0.000f);

		dst[16] = mix(dst[16], blendPix[3], (needBlend[3] && doLineBlend[3]) ? ((haveShallowLine[3]) ? ((haveSteepLine[3]) ? 2.0f/3.0f : 0.750f) : ((haveSteepLine[3]) ? 0.750f : 0.125f)) : 0.000f);

		dst[17] = mix(dst[17], blendPix[0], (needBlend[0] && doLineBlend[0] && haveShallowLine[0]) ? 0.250f : 0.000f);
		dst[17] = mix(dst[17], blendPix[3], (needBlend[3] && doLineBlend[3] && haveSteepLine[3]) ? 0.250f : 0.000f);

		dst[18] = mix(dst[18], blendPix[0], (needBlend[0] && doLineBlend[0]) ? ((haveShallowLine[0]) ? ((haveSteepLine[0]) ? 2.0f/3.0f : 0.750f) : ((haveSteepLine[0]) ? 0.750f : 0.125f)) : 0.000f);

		dst[19] = mix(dst[19], blendPix[0], (needBlend[0]) ? ((doLineBlend[0]) ? ((!haveShallowLine[0] && !haveSteepLine[0]) ? 0.875f : 1.000f) : 0.2306749731f) : 0.000f);
		dst[19] = mix(dst[19], blendPix[1], (needBlend[1] && doLineBlend[1] && haveShallowLine[1]) ? 0.750f : 0.000f);

		dst[20] = mix(dst[20], blendPix[0], (needBlend[0] && doLineBlend[0] && haveShallowLine[0]) ? 0.250f : 0.000f);
		dst[20] = mix(dst[20], blendPix[2], (needBlend[2] && doLineBlend[2] && haveSteepLine[2]) ? 0.250f : 0.000f);
		dst[20] = mix(dst[20], blendPix[3], (needBlend[3]) ? ((doLineBlend[3]) ? 1.000f : 0.8631434088f) : 0.000f);

		dst[21] = mix(dst[21], blendPix[0], (needBlend[0] && doLineBlend[0] && haveShallowLine[0]) ? 0.750f : 0.000f);
		dst[21] = mix(dst[21], blendPix[3], (needBlend[3]) ? ((doLineBlend[3]) ? ((!haveShallowLine[3] && !haveSteepLine[3]) ? 0.875f : 1.000f) : 0.2306749731f) : 0.000f);

		dst[22] = mix(dst[22], blendPix[0], (needBlend[0] && doLineBlend[0]) ? ((haveShallowLine[0]) ? 1.000f : ((haveSteepLine[0]) ? 0.250f : 0.125f)) : 0.000f);
		dst[22] = mix(dst[22], blendPix[3], (needBlend[3] && doLineBlend[3]) ? ((haveSteepLine[3]) ? 1.000f : ((haveShallowLine[3]) ? 0.250f : 0.125f)) : 0.000f);

		dst[23] = mix(dst[23], blendPix[0], (needBlend[0]) ? ((doLineBlend[0]) ? ((!haveShallowLine[0] && !haveSteepLine[0]) ? 0.875f : 1.000f) : 0.2306749731f) : 0.000f);
		dst[23] = mix(dst[23], blendPix[3], (needBlend[3] && doLineBlend[3] && haveSteepLine[3]) ? 0.750f : 0.000f);

		dst[24] = mix(dst[24], blendPix[0], (needBlend[0]) ? ((doLineBlend[0]) ? 1.000f : 0.8631434088f) : 0.000f);
		dst[24] = mix(dst[24], blendPix[1], (needBlend[1] && doLineBlend[1] && haveShallowLine[1]) ? 0.250f : 0.000f);
		dst[24] = mix(dst[24], blendPix[3], (needBlend[3] && doLineBlend[3] && haveSteepLine[3]) ? 0.250f : 0.000f);
	}
	
	const uint2 outPosition = inPosition * 5;
	outTexture.write( float4(dst[ 0], 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(dst[ 1], 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(dst[ 2], 1.0f), outPosition + uint2(2, 0) );
	outTexture.write( float4(dst[ 3], 1.0f), outPosition + uint2(3, 0) );
	outTexture.write( float4(dst[ 4], 1.0f), outPosition + uint2(4, 0) );
	outTexture.write( float4(dst[ 5], 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(dst[ 6], 1.0f), outPosition + uint2(1, 1) );
	outTexture.write( float4(dst[ 7], 1.0f), outPosition + uint2(2, 1) );
	outTexture.write( float4(dst[ 8], 1.0f), outPosition + uint2(3, 1) );
	outTexture.write( float4(dst[ 9], 1.0f), outPosition + uint2(4, 1) );
	outTexture.write( float4(dst[10], 1.0f), outPosition + uint2(0, 2) );
	outTexture.write( float4(dst[11], 1.0f), outPosition + uint2(1, 2) );
	outTexture.write( float4(dst[12], 1.0f), outPosition + uint2(2, 2) );
	outTexture.write( float4(dst[13], 1.0f), outPosition + uint2(3, 2) );
	outTexture.write( float4(dst[14], 1.0f), outPosition + uint2(4, 2) );
	outTexture.write( float4(dst[15], 1.0f), outPosition + uint2(0, 3) );
	outTexture.write( float4(dst[16], 1.0f), outPosition + uint2(1, 3) );
	outTexture.write( float4(dst[17], 1.0f), outPosition + uint2(2, 3) );
	outTexture.write( float4(dst[18], 1.0f), outPosition + uint2(3, 3) );
	outTexture.write( float4(dst[19], 1.0f), outPosition + uint2(4, 3) );
	outTexture.write( float4(dst[20], 1.0f), outPosition + uint2(0, 4) );
	outTexture.write( float4(dst[21], 1.0f), outPosition + uint2(1, 4) );
	outTexture.write( float4(dst[22], 1.0f), outPosition + uint2(2, 4) );
	outTexture.write( float4(dst[23], 1.0f), outPosition + uint2(3, 4) );
	outTexture.write( float4(dst[24], 1.0f), outPosition + uint2(4, 4) );
}

//----------------------------------------
// Input Pixel Mapping:   --|21|22|23|--
//                        19|06|07|08|09
//                        18|05|00|01|10
//                        17|04|03|02|11
//                        --|15|14|13|--
//
// Output Pixel Mapping: 00|01|02|03|04|05
//                       06|07|08|09|10|11
//                       12|13|14|15|16|17
//                       18|19|20|21|22|23
//                       24|25|26|27|28|29
//                       30|31|32|33|34|35
kernel void pixel_scaler_6xBRZ(const uint2 inPosition [[thread_position_in_grid]],
							   const texture2d<float, access::sample> inTexture [[texture(0)]],
							   texture2d<float, access::write> outTexture [[texture(1)]])
{
	const float3 src[25] = {
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2, 0)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2,-1)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-2,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2(-1,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 0,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 1,-2)).rgb,
		inTexture.sample(genSampler, float2(inPosition), int2( 2,-2)).rgb
	};
	
	const float v[9] = {
		reduce(src[0]),
		reduce(src[1]),
		reduce(src[2]),
		reduce(src[3]),
		reduce(src[4]),
		reduce(src[5]),
		reduce(src[6]),
		reduce(src[7]),
		reduce(src[8])
	};
	
	int4 blendResult = int4(BLEND_NONE);
	
	// Preprocess corners
	// Pixel Tap Mapping: --|--|--|--|--
	//                    --|--|07|08|--
	//                    --|05|00|01|10
	//                    --|04|03|02|11
	//                    --|--|14|13|--
	
	// Corner (1, 1)
	if ( !((v[0] == v[1] && v[3] == v[2]) || (v[0] == v[3] && v[1] == v[2])) )
	{
		const float dist_03_01 = DistYCbCr(src[ 4], src[ 0]) + DistYCbCr(src[ 0], src[ 8]) + DistYCbCr(src[14], src[ 2]) + DistYCbCr(src[ 2], src[10]) + (4.0 * DistYCbCr(src[ 3], src[ 1]));
		const float dist_00_02 = DistYCbCr(src[ 5], src[ 3]) + DistYCbCr(src[ 3], src[13]) + DistYCbCr(src[ 7], src[ 1]) + DistYCbCr(src[ 1], src[11]) + (4.0 * DistYCbCr(src[ 0], src[ 2]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_03_01) < dist_00_02;
		
		blendResult[2] = ((dist_03_01 < dist_00_02) && (v[0] != v[1]) && (v[0] != v[3])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	
	// Pixel Tap Mapping: --|--|--|--|--
	//                    --|06|07|--|--
	//                    18|05|00|01|--
	//                    17|04|03|02|--
	//                    --|15|14|--|--
	// Corner (0, 1)
	if ( !((v[5] == v[0] && v[4] == v[3]) || (v[5] == v[4] && v[0] == v[3])) )
	{
		const float dist_04_00 = DistYCbCr(src[17], src[ 5]) + DistYCbCr(src[ 5], src[ 7]) + DistYCbCr(src[15], src[ 3]) + DistYCbCr(src[ 3], src[ 1]) + (4.0 * DistYCbCr(src[ 4], src[ 0]));
		const float dist_05_03 = DistYCbCr(src[18], src[ 4]) + DistYCbCr(src[ 4], src[14]) + DistYCbCr(src[ 6], src[ 0]) + DistYCbCr(src[ 0], src[ 2]) + (4.0 * DistYCbCr(src[ 5], src[ 3]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_05_03) < dist_04_00;
		
		blendResult[3] = ((dist_04_00 > dist_05_03) && (v[0] != v[5]) && (v[0] != v[3])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	// Pixel Tap Mapping: --|--|22|23|--
	//                    --|06|07|08|09
	//                    --|05|00|01|10
	//                    --|--|03|02|--
	//                    --|--|--|--|--
	// Corner (1, 0)
	if ( !((v[7] == v[8] && v[0] == v[1]) || (v[7] == v[0] && v[8] == v[1])) )
	{
		const float dist_00_08 = DistYCbCr(src[ 5], src[ 7]) + DistYCbCr(src[ 7], src[23]) + DistYCbCr(src[ 3], src[ 1]) + DistYCbCr(src[ 1], src[ 9]) + (4.0 * DistYCbCr(src[ 0], src[ 8]));
		const float dist_07_01 = DistYCbCr(src[ 6], src[ 0]) + DistYCbCr(src[ 0], src[ 2]) + DistYCbCr(src[22], src[ 8]) + DistYCbCr(src[ 8], src[10]) + (4.0 * DistYCbCr(src[ 7], src[ 1]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_07_01) < dist_00_08;
		
		blendResult[1] = ((dist_00_08 > dist_07_01) && (v[0] != v[7]) && (v[0] != v[1])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	// Pixel Tap Mapping: --|21|22|--|--
	//                    19|06|07|08|--
	//                    18|05|00|01|--
	//                    --|04|03|--|--
	//                    --|--|--|--|--
	// Corner (0, 0)
	if ( !((v[6] == v[7] && v[5] == v[0]) || (v[6] == v[5] && v[7] == v[0])) )
	{
		const float dist_05_07 = DistYCbCr(src[18], src[ 6]) + DistYCbCr(src[ 6], src[22]) + DistYCbCr(src[ 4], src[ 0]) + DistYCbCr(src[ 0], src[ 8]) + (4.0 * DistYCbCr(src[ 5], src[ 7]));
		const float dist_06_00 = DistYCbCr(src[19], src[ 5]) + DistYCbCr(src[ 5], src[ 3]) + DistYCbCr(src[21], src[ 7]) + DistYCbCr(src[ 7], src[ 1]) + (4.0 * DistYCbCr(src[ 6], src[ 0]));
		const bool dominantGradient = (DOMINANT_DIRECTION_THRESHOLD * dist_05_07) < dist_06_00;
		
		blendResult[0] = ((dist_05_07 < dist_06_00) && (v[0] != v[5]) && (v[0] != v[7])) ? ((dominantGradient) ? BLEND_DOMINANT : BLEND_NORMAL) : BLEND_NONE;
	}
	
	float3 dst[36] = {
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0],
		src[0]
	};
	
	//float3 dst[36] = {src[0]};
	
	// Scale pixel
	if (IsBlendingNeeded(blendResult))
	{
		const float4 dist_01_04 = float4( DistYCbCr(src[1], src[4]), DistYCbCr(src[7], src[2]), DistYCbCr(src[5], src[8]), DistYCbCr(src[3], src[6]) );
		const float4 dist_03_08 = float4( DistYCbCr(src[3], src[8]), DistYCbCr(src[1], src[6]), DistYCbCr(src[7], src[4]), DistYCbCr(src[5], src[2]) );
		const bool4 haveShallowLine = (STEEP_DIRECTION_THRESHOLD * dist_01_04 <= dist_03_08);
		const bool4 haveSteepLine = (STEEP_DIRECTION_THRESHOLD * dist_03_08 <= dist_01_04);
		const bool4 needBlend = (blendResult.zyxw != int4(BLEND_NONE));
		const bool4 doLineBlend = (blendResult.zyxw >= int4(BLEND_DOMINANT));
		float3 blendPix[4];
		
		haveShallowLine[0] = haveShallowLine[0] && (v[0] != v[4]) && (v[5] != v[4]);
		haveSteepLine[0]   = haveSteepLine[0] && (v[0] != v[8]) && (v[7] != v[8]);
		doLineBlend[0] = (  doLineBlend[0] ||
						   !((blendResult[1] != BLEND_NONE && !IsPixEqual(src[0], src[4])) ||
							 (blendResult[3] != BLEND_NONE && !IsPixEqual(src[0], src[8])) ||
							 (IsPixEqual(src[4], src[3]) && IsPixEqual(src[3], src[2]) && IsPixEqual(src[2], src[1]) && IsPixEqual(src[1], src[8]) && !IsPixEqual(src[0], src[2])) ) );
		blendPix[0] = ( DistYCbCr(src[0], src[1]) <= DistYCbCr(src[0], src[3]) ) ? src[1] : src[3];
		
		haveShallowLine[1] = haveShallowLine[1] && (v[0] != v[2]) && (v[3] != v[2]);
		haveSteepLine[1]   = haveSteepLine[1] && (v[0] != v[6]) && (v[5] != v[6]);
		doLineBlend[1] = (  doLineBlend[1] ||
					  !((blendResult[0] != BLEND_NONE && !IsPixEqual(src[0], src[2])) ||
						(blendResult[2] != BLEND_NONE && !IsPixEqual(src[0], src[6])) ||
						(IsPixEqual(src[2], src[1]) && IsPixEqual(src[1], src[8]) && IsPixEqual(src[8], src[7]) && IsPixEqual(src[7], src[6]) && !IsPixEqual(src[0], src[8])) ) );
		blendPix[1] = ( DistYCbCr(src[0], src[7]) <= DistYCbCr(src[0], src[1]) ) ? src[7] : src[1];
		
		haveShallowLine[2] = haveShallowLine[2] && (v[0] != v[8]) && (v[1] != v[8]);
		haveSteepLine[2]   = haveSteepLine[2] && (v[0] != v[4]) && (v[3] != v[4]);
		doLineBlend[2] = (  doLineBlend[2] ||
					  !((blendResult[3] != BLEND_NONE && !IsPixEqual(src[0], src[8])) ||
						(blendResult[1] != BLEND_NONE && !IsPixEqual(src[0], src[4])) ||
						(IsPixEqual(src[8], src[7]) && IsPixEqual(src[7], src[6]) && IsPixEqual(src[6], src[5]) && IsPixEqual(src[5], src[4]) && !IsPixEqual(src[0], src[6])) ) );
		blendPix[2] = ( DistYCbCr(src[0], src[5]) <= DistYCbCr(src[0], src[7]) ) ? src[5] : src[7];
		
		haveShallowLine[3] = haveShallowLine[3] && (v[0] != v[6]) && (v[7] != v[6]);
		haveSteepLine[3]   = haveSteepLine[3] && (v[0] != v[2]) && (v[1] != v[2]);
		doLineBlend[3] = (  doLineBlend[3] ||
					  !((blendResult[2] != BLEND_NONE && !IsPixEqual(src[0], src[6])) ||
						(blendResult[0] != BLEND_NONE && !IsPixEqual(src[0], src[2])) ||
						(IsPixEqual(src[6], src[5]) && IsPixEqual(src[5], src[4]) && IsPixEqual(src[4], src[3]) && IsPixEqual(src[3], src[2]) && !IsPixEqual(src[0], src[4])) ) );
		blendPix[3] = ( DistYCbCr(src[0], src[3]) <= DistYCbCr(src[0], src[5]) ) ? src[3] : src[5];
		
		dst[ 0] = mix(dst[ 0], blendPix[1], (needBlend[1] && doLineBlend[1] && haveSteepLine[1]) ? 0.250f : 0.000f);
		dst[ 0] = mix(dst[ 0], blendPix[2], (needBlend[2]) ? ((doLineBlend[2]) ? 1.000f : 0.9711013910f) : 0.000f);
		dst[ 0] = mix(dst[ 0], blendPix[3], (needBlend[3] && doLineBlend[3] && haveShallowLine[3]) ? 0.250f : 0.000f);

		dst[ 1] = mix(dst[ 1], blendPix[1], (needBlend[1] && doLineBlend[1] && haveSteepLine[1]) ? 0.750f : 0.000f);
		dst[ 1] = mix(dst[ 1], blendPix[2], (needBlend[2]) ? ((doLineBlend[2]) ? 1.000f : 0.4236372243f) : 0.000f);

		dst[ 2] = mix(dst[ 2], blendPix[1], (needBlend[1] && doLineBlend[1] && haveSteepLine[1]) ? 1.000f : 0.000f);
		dst[ 2] = mix(dst[ 2], blendPix[2], (needBlend[2]) ? ((doLineBlend[2]) ? ((haveShallowLine[2]) ? 1.000f : ((haveSteepLine[2]) ? 0.750f : 0.500f)) : 0.05652034508f) : 0.000f);

		dst[ 3] = mix(dst[ 3], blendPix[1], (needBlend[1]) ? ((doLineBlend[1]) ? ((haveSteepLine[1]) ? 1.000f : ((haveShallowLine[1]) ? 0.750f : 0.500f)) : 0.05652034508f) : 0.000f);
		dst[ 3] = mix(dst[ 3], blendPix[2], (needBlend[2] && doLineBlend[2] && haveShallowLine[2]) ? 1.000f : 0.000f);

		dst[ 4] = mix(dst[ 4], blendPix[1], (needBlend[1]) ? ((doLineBlend[1]) ? 1.000f : 0.4236372243f) : 0.000f);
		dst[ 4] = mix(dst[ 4], blendPix[2], (needBlend[2] && doLineBlend[2] && haveShallowLine[2]) ? 0.750f : 0.000f);

		dst[ 5] = mix(dst[ 5], blendPix[0], (needBlend[0] && doLineBlend[0] && haveSteepLine[0]) ? 0.250f : 0.000f);
		dst[ 5] = mix(dst[ 5], blendPix[1], (needBlend[1]) ? ((doLineBlend[1]) ? 1.000f : 0.9711013910f) : 0.000f);
		dst[ 5] = mix(dst[ 5], blendPix[2], (needBlend[2] && doLineBlend[2] && haveShallowLine[2]) ? 0.250f : 0.000f);

		dst[ 6] = mix(dst[ 6], blendPix[2], (needBlend[2]) ? ((doLineBlend[2]) ? 1.000f : 0.4236372243f) : 0.000f);
		dst[ 6] = mix(dst[ 6], blendPix[3], (needBlend[3] && doLineBlend[3] && haveShallowLine[3]) ? 0.750f : 0.000f);

		dst[ 7] = mix(dst[ 7], blendPix[2], (needBlend[2] && doLineBlend[2]) ? ((!haveShallowLine[2] && !haveSteepLine[2]) ? 0.500f : 1.000f) : 0.000f);

		dst[ 8] = mix(dst[ 8], blendPix[1], (needBlend[1] && doLineBlend[1] && haveSteepLine[1]) ? 0.250f : 0.000f);
		dst[ 8] = mix(dst[ 8], blendPix[2], (needBlend[2] && doLineBlend[2]) ? ((haveShallowLine[2]) ? 0.750f : ((haveSteepLine[2]) ? 0.250f : 0.000f)) : 0.000f);

		dst[ 9] = mix(dst[ 9], blendPix[1], (needBlend[1] && doLineBlend[1]) ? ((haveSteepLine[1]) ? 0.750f : ((haveShallowLine[1]) ? 0.250f : 0.000f)) : 0.000f);
		dst[ 9] = mix(dst[ 9], blendPix[2], (needBlend[2] && doLineBlend[2] && haveShallowLine[2]) ? 0.250f : 0.000f);

		dst[10] = mix(dst[10], blendPix[1], (needBlend[1] && doLineBlend[1]) ? ((!haveShallowLine[1] && !haveSteepLine[1]) ? 0.500f : 1.000f) : 0.000f);

		dst[11] = mix(dst[11], blendPix[0], (needBlend[0] && doLineBlend[0] && haveSteepLine[0]) ? 0.750f : 0.000f);
		dst[11] = mix(dst[11], blendPix[1], (needBlend[1]) ? ((doLineBlend[1]) ? 1.000f : 0.4236372243f) : 0.000);

		dst[12] = mix(dst[12], blendPix[2], (needBlend[2]) ? ((doLineBlend[2]) ? ((haveSteepLine[2]) ? 1.000f : ((haveShallowLine[2]) ? 0.750f : 0.500f)) : 0.05652034508f) : 0.000f);
		dst[12] = mix(dst[12], blendPix[3], (needBlend[3] && doLineBlend[3] && haveShallowLine[3]) ? 1.000f : 0.000f);

		dst[13] = mix(dst[13], blendPix[2], (needBlend[2] && doLineBlend[2]) ? ((haveSteepLine[2]) ? 0.750f : ((haveShallowLine[2]) ? 0.250f : 0.000f)) : 0.000f);
		dst[13] = mix(dst[13], blendPix[3], (needBlend[3] && doLineBlend[3] && haveShallowLine[3]) ? 0.250f : 0.000f);

		dst[16] = mix(dst[16], blendPix[0], (needBlend[0] && doLineBlend[0] && haveSteepLine[0]) ? 0.250f : 0.000f);
		dst[16] = mix(dst[16], blendPix[1], (needBlend[1] && doLineBlend[1]) ? ((haveShallowLine[1]) ? 0.750f : ((haveSteepLine[1]) ? 0.250f : 0.000f)) : 0.000f);

		dst[17] = mix(dst[17], blendPix[0], (needBlend[0] && doLineBlend[0] && haveSteepLine[0]) ? 1.000f : 0.000f);
		dst[17] = mix(dst[17], blendPix[1], (needBlend[1]) ? ((doLineBlend[1]) ? ((haveShallowLine[1]) ? 1.000f : ((haveSteepLine[1]) ? 0.750f : 0.500f)) : 0.05652034508f) : 0.000f);

		dst[18] = mix(dst[18], blendPix[2], (needBlend[2] && doLineBlend[2] && haveSteepLine[2]) ? 1.000f : 0.000f);
		dst[18] = mix(dst[18], blendPix[3], (needBlend[3]) ? ((doLineBlend[3]) ? ((haveShallowLine[3]) ? 1.000f : ((haveSteepLine[3]) ? 0.750f : 0.500f)) : 0.05652034508f) : 0.000f);

		dst[19] = mix(dst[19], blendPix[2], (needBlend[2] && doLineBlend[2] && haveSteepLine[2]) ? 0.250f : 0.000f);
		dst[19] = mix(dst[19], blendPix[3], (needBlend[3] && doLineBlend[3]) ? ((haveShallowLine[3]) ? 0.750f : ((haveSteepLine[3]) ? 0.250f : 0.000f)) : 0.000f);

		dst[22] = mix(dst[22], blendPix[0], (needBlend[0] && doLineBlend[0]) ? ((haveSteepLine[0]) ? 0.750f : ((haveShallowLine[0]) ? 0.250f : 0.000f)) : 0.000f);
		dst[22] = mix(dst[22], blendPix[1], (needBlend[1] && doLineBlend[1] && haveShallowLine[1]) ? 0.250f : 0.000f);

		dst[23] = mix(dst[23], blendPix[0], (needBlend[0]) ? ((doLineBlend[0]) ? ((haveSteepLine[0]) ? 1.000f : ((haveShallowLine[0]) ? 0.750f : 0.500f)) : 0.05652034508f) : 0.000f);
		dst[23] = mix(dst[23], blendPix[1], (needBlend[1] && doLineBlend[1] && haveShallowLine[1]) ? 1.000f : 0.000f);

		dst[24] = mix(dst[24], blendPix[2], (needBlend[2] && doLineBlend[2] && haveSteepLine[2]) ? 0.750f : 0.000f);
		dst[24] = mix(dst[24], blendPix[3], (needBlend[3]) ? ((doLineBlend[3]) ? 1.000f : 0.4236372243f) : 0.000f);

		dst[25] = mix(dst[25], blendPix[3], (needBlend[3] && doLineBlend[3]) ? ((!haveShallowLine[3] && !haveSteepLine[3]) ? 0.500f : 1.000f) : 0.000f);

		dst[26] = mix(dst[26], blendPix[0], (needBlend[0] && doLineBlend[0] && haveShallowLine[0]) ? 0.250f : 0.000f);
		dst[26] = mix(dst[26], blendPix[3], (needBlend[3] && doLineBlend[3]) ? ((haveSteepLine[3]) ? 0.750f : ((haveShallowLine[3]) ? 0.250f : 0.000f)) : 0.000f);

		dst[27] = mix(dst[27], blendPix[0], (needBlend[0] && doLineBlend[0]) ? ((haveShallowLine[0]) ? 0.750f : ((haveSteepLine[0]) ? 0.250f : 0.000f)) : 0.000f);
		dst[27] = mix(dst[27], blendPix[3], (needBlend[3] && doLineBlend[3] && haveSteepLine[3]) ? 0.250f : 0.000f);

		dst[28] = mix(dst[28], blendPix[0], (needBlend[0] && doLineBlend[0]) ? ((!haveShallowLine[0] && !haveSteepLine[0]) ? 0.500f : 1.000f) : 0.000f);

		dst[29] = mix(dst[29], blendPix[0], (needBlend[0]) ? ((doLineBlend[0]) ? 1.000f : 0.4236372243f) : 0.000f);
		dst[29] = mix(dst[29], blendPix[1], (needBlend[1] && doLineBlend[1] && haveShallowLine[1]) ? 0.750f : 0.000f);

		dst[30] = mix(dst[30], blendPix[0], (needBlend[0] && doLineBlend[0] && haveShallowLine[0]) ? 0.250f : 0.000f);
		dst[30] = mix(dst[30], blendPix[2], (needBlend[2] && doLineBlend[2] && haveSteepLine[2]) ? 0.250f : 0.000f);
		dst[30] = mix(dst[30], blendPix[3], (needBlend[3]) ? ((doLineBlend[3]) ? 1.000f : 0.9711013910f) : 0.000f);

		dst[31] = mix(dst[31], blendPix[0], (needBlend[0] && doLineBlend[0] && haveShallowLine[0]) ? 0.750f : 0.000f);
		dst[31] = mix(dst[31], blendPix[3], (needBlend[3]) ? ((doLineBlend[3]) ? 1.000f : 0.4236372243f) : 0.000f);

		dst[32] = mix(dst[32], blendPix[0], (needBlend[0] && doLineBlend[0] && haveShallowLine[0]) ? 1.000f : 0.000f);
		dst[32] = mix(dst[32], blendPix[3], (needBlend[3]) ? ((doLineBlend[3]) ? ((haveSteepLine[3]) ? 1.000f : ((haveShallowLine[3]) ? 0.750f : 0.500f)) : 0.05652034508f) : 0.000f);

		dst[33] = mix(dst[33], blendPix[0], (needBlend[0]) ? ((doLineBlend[0]) ? ((haveShallowLine[0]) ? 1.000f : ((haveSteepLine[0]) ? 0.750f : 0.500f)) : 0.05652034508f) : 0.000f);
		dst[33] = mix(dst[33], blendPix[3], (needBlend[3] && doLineBlend[3] && haveSteepLine[3]) ? 1.000f : 0.000f);

		dst[34] = mix(dst[34], blendPix[0], (needBlend[0]) ? ((doLineBlend[0]) ? 1.000f : 0.4236372243f) : 0.000f);
		dst[34] = mix(dst[34], blendPix[3], (needBlend[3] && doLineBlend[3] && haveSteepLine[3]) ? 0.750f : 0.000f);

		dst[35] = mix(dst[35], blendPix[0], (needBlend[0]) ? ((doLineBlend[0]) ? 1.000f : 0.9711013910f) : 0.000f);
		dst[35] = mix(dst[35], blendPix[1], (needBlend[1] && doLineBlend[1] && haveShallowLine[1]) ? 0.250f : 0.000f);
		dst[35] = mix(dst[35], blendPix[3], (needBlend[3] && doLineBlend[3] && haveSteepLine[3]) ? 0.250f : 0.000f);
	}
	
	const uint2 outPosition = inPosition * 6;
	outTexture.write( float4(dst[ 0], 1.0f), outPosition + uint2(0, 0) );
	outTexture.write( float4(dst[ 1], 1.0f), outPosition + uint2(1, 0) );
	outTexture.write( float4(dst[ 2], 1.0f), outPosition + uint2(2, 0) );
	outTexture.write( float4(dst[ 3], 1.0f), outPosition + uint2(3, 0) );
	outTexture.write( float4(dst[ 4], 1.0f), outPosition + uint2(4, 0) );
	outTexture.write( float4(dst[ 5], 1.0f), outPosition + uint2(5, 0) );
	outTexture.write( float4(dst[ 6], 1.0f), outPosition + uint2(0, 1) );
	outTexture.write( float4(dst[ 7], 1.0f), outPosition + uint2(1, 1) );
	outTexture.write( float4(dst[ 8], 1.0f), outPosition + uint2(2, 1) );
	outTexture.write( float4(dst[ 9], 1.0f), outPosition + uint2(3, 1) );
	outTexture.write( float4(dst[10], 1.0f), outPosition + uint2(4, 1) );
	outTexture.write( float4(dst[11], 1.0f), outPosition + uint2(5, 1) );
	outTexture.write( float4(dst[12], 1.0f), outPosition + uint2(0, 2) );
	outTexture.write( float4(dst[13], 1.0f), outPosition + uint2(1, 2) );
	outTexture.write( float4(dst[14], 1.0f), outPosition + uint2(2, 2) );
	outTexture.write( float4(dst[15], 1.0f), outPosition + uint2(3, 2) );
	outTexture.write( float4(dst[16], 1.0f), outPosition + uint2(4, 2) );
	outTexture.write( float4(dst[17], 1.0f), outPosition + uint2(5, 2) );
	outTexture.write( float4(dst[18], 1.0f), outPosition + uint2(0, 3) );
	outTexture.write( float4(dst[19], 1.0f), outPosition + uint2(1, 3) );
	outTexture.write( float4(dst[20], 1.0f), outPosition + uint2(2, 3) );
	outTexture.write( float4(dst[21], 1.0f), outPosition + uint2(3, 3) );
	outTexture.write( float4(dst[22], 1.0f), outPosition + uint2(4, 3) );
	outTexture.write( float4(dst[23], 1.0f), outPosition + uint2(5, 3) );
	outTexture.write( float4(dst[24], 1.0f), outPosition + uint2(0, 4) );
	outTexture.write( float4(dst[25], 1.0f), outPosition + uint2(1, 4) );
	outTexture.write( float4(dst[26], 1.0f), outPosition + uint2(2, 4) );
	outTexture.write( float4(dst[27], 1.0f), outPosition + uint2(3, 4) );
	outTexture.write( float4(dst[28], 1.0f), outPosition + uint2(4, 4) );
	outTexture.write( float4(dst[29], 1.0f), outPosition + uint2(5, 4) );
	outTexture.write( float4(dst[30], 1.0f), outPosition + uint2(0, 5) );
	outTexture.write( float4(dst[31], 1.0f), outPosition + uint2(1, 5) );
	outTexture.write( float4(dst[32], 1.0f), outPosition + uint2(2, 5) );
	outTexture.write( float4(dst[33], 1.0f), outPosition + uint2(3, 5) );
	outTexture.write( float4(dst[34], 1.0f), outPosition + uint2(4, 5) );
	outTexture.write( float4(dst[35], 1.0f), outPosition + uint2(5, 5) );
}
