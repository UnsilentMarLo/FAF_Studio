// FAF Studio: post-process anti-aliasing (FXAA 3.11, "quality" algorithm, after Timothy Lottes / NVIDIA), one full-screen pass.
// Drawn by src/moho/editor/EdFxaa.cpp after the 3D scene was rendered into an off-screen target and before the Maui UI is drawn, so text and controls stay unfiltered.
// Own file (not part of FAF's effects): editor/runtime/override/effects/ is mounted first on the VFS root by init_editor.lua.
//
// Shader model 3.0 (dynamic branching; the search loops are unrolled). The whole file must compile: a failed effect file is fatal at start (CD3DDeviceResources::InitResources).
// Check it with fxc after every edit:  fxc /T fx_2_0 /nologo editor\runtime\override\effects\fxaa.fx

texture FxaaTexture;                 // the scene (gamma encoded colour)
float4  fxaaFrame;                   // (width, height, 1 / width, 1 / height) of the target in pixels
float4  fxaaRect;                    // taps stay inside this rectangle: (u0, v0, u1, v1) in 0..1, the world view
float4  fxaaParams;                  // (subpixel quality 0..1, edge threshold, edge threshold min, 0)

sampler2D FxaaSampler = sampler_state
{
    Texture = (FxaaTexture);
    MipFilter = NONE;
    MinFilter = LINEAR;
    MagFilter = LINEAR;
    AddressU  = CLAMP;
    AddressV  = CLAMP;
};

struct VS_IN
{
    float4 Pos  : POSITION;
    float2 Tex1 : TEXCOORD0;
};

struct VS_OUT
{
    float4 Pos : POSITION;
    float2 Tex : TEXCOORD0;
};

// The quad is the frame sheet of CRenFrame: pixel coordinates from -0.5 to size - 0.5 (see CRenFrame::InitTransformedVerts), the same mapping frame.fx's FixedFuncVS uses.
VS_OUT FxaaVS( VS_IN In )
{
    VS_OUT Out = (VS_OUT)0;
    float2 uv = ( In.Pos.xy + float2( 0.5, 0.5 ) ) * fxaaFrame.zw;
    Out.Pos = float4( 2.0 * uv.x - 1.0, 1.0 - 2.0 * uv.y, In.Pos.z, 1.0 );
    Out.Tex = uv;
    return Out;
}

float4 Fetch( float2 uv )
{
    return tex2Dlod( FxaaSampler, float4( clamp( uv, fxaaRect.xy, fxaaRect.zw ), 0.0, 0.0 ) );
}

float Luma( float3 rgb )
{
    return dot( rgb, float3( 0.299, 0.587, 0.114 ) );
}

float LumaAt( float2 uv )
{
    return Luma( Fetch( uv ).rgb );
}

float4 FxaaPS( VS_OUT In ) : COLOR0
{
    float2 rcp = fxaaFrame.zw;
    float2 posM = In.Tex;
    float subpix = fxaaParams.x;
    float edgeThreshold = fxaaParams.y;
    float edgeThresholdMin = fxaaParams.z;

    float4 rgbyM = Fetch( posM );
    float lumaM = Luma( rgbyM.rgb );
    float lumaS = LumaAt( posM + float2( 0.0, rcp.y ) );
    float lumaE = LumaAt( posM + float2( rcp.x, 0.0 ) );
    float lumaN = LumaAt( posM + float2( 0.0, -rcp.y ) );
    float lumaW = LumaAt( posM + float2( -rcp.x, 0.0 ) );

    float maxSM = max( lumaS, lumaM );
    float minSM = min( lumaS, lumaM );
    float maxESM = max( lumaE, maxSM );
    float minESM = min( lumaE, minSM );
    float maxWN = max( lumaN, lumaW );
    float minWN = min( lumaN, lumaW );
    float rangeMax = max( maxWN, maxESM );
    float rangeMin = min( minWN, minESM );
    float range = rangeMax - rangeMin;
    float rangeMaxClamped = max( edgeThresholdMin, rangeMax * edgeThreshold );

    // flat area: nothing to smooth (five taps). One return at the end: the engine's D3DX compiler rejects returns inside an if.
    float4 result = rgbyM;
    if ( range >= rangeMaxClamped )
    {

    float lumaNW = LumaAt( posM + float2( -rcp.x, -rcp.y ) );
    float lumaSE = LumaAt( posM + float2( rcp.x, rcp.y ) );
    float lumaNE = LumaAt( posM + float2( rcp.x, -rcp.y ) );
    float lumaSW = LumaAt( posM + float2( -rcp.x, rcp.y ) );

    float lumaNS = lumaN + lumaS;
    float lumaWE = lumaW + lumaE;
    float subpixRcpRange = 1.0 / range;
    float subpixNSWE = lumaNS + lumaWE;
    float edgeHorz1 = -2.0 * lumaM + lumaNS;
    float edgeVert1 = -2.0 * lumaM + lumaWE;
    float lumaNESE = lumaNE + lumaSE;
    float lumaNWNE = lumaNW + lumaNE;
    float edgeHorz2 = -2.0 * lumaE + lumaNESE;
    float edgeVert2 = -2.0 * lumaN + lumaNWNE;
    float lumaNWSW = lumaNW + lumaSW;
    float lumaSWSE = lumaSW + lumaSE;
    float edgeHorz4 = abs( edgeHorz1 ) * 2.0 + abs( edgeHorz2 );
    float edgeVert4 = abs( edgeVert1 ) * 2.0 + abs( edgeVert2 );
    float edgeHorz3 = -2.0 * lumaW + lumaNWSW;
    float edgeVert3 = -2.0 * lumaS + lumaSWSE;
    float edgeHorz = abs( edgeHorz3 ) + edgeHorz4;
    float edgeVert = abs( edgeVert3 ) + edgeVert4;
    float subpixNWSWNESE = lumaNWSW + lumaNESE;

    bool horzSpan = edgeHorz >= edgeVert;
    float lengthSign = horzSpan ? rcp.y : rcp.x;
    float subpixA = subpixNSWE * 2.0 + subpixNWSWNESE;
    if ( !horzSpan ) lumaN = lumaW;
    if ( !horzSpan ) lumaS = lumaE;
    float subpixB = subpixA * ( 1.0 / 12.0 ) - lumaM;
    float gradientN = lumaN - lumaM;
    float gradientS = lumaS - lumaM;
    float lumaNN = lumaN + lumaM;
    float lumaSS = lumaS + lumaM;
    bool pairN = abs( gradientN ) >= abs( gradientS );
    float gradient = max( abs( gradientN ), abs( gradientS ) );
    if ( pairN ) lengthSign = -lengthSign;
    float subpixC = saturate( abs( subpixB ) * subpixRcpRange );

    float2 posB = posM;
    float2 offNP;
    offNP.x = horzSpan ? rcp.x : 0.0;
    offNP.y = horzSpan ? 0.0 : rcp.y;
    if ( !horzSpan ) posB.x += lengthSign * 0.5;
    if ( horzSpan ) posB.y += lengthSign * 0.5;

    // search along the edge in both directions (quality preset 39: steps 1 1 1 1 1 1.5 2 2 2 2 4 8)
    float2 posN = posB - offNP;
    float2 posP = posB + offNP;
    float subpixD = -2.0 * subpixC + 3.0;
    float lumaEndN = LumaAt( posN );
    float subpixE = subpixC * subpixC;
    float lumaEndP = LumaAt( posP );
    if ( !pairN ) lumaNN = lumaSS;
    float gradientScaled = gradient * ( 1.0 / 4.0 );
    float lumaMM = lumaM - lumaNN * 0.5;
    float subpixF = subpixD * subpixE;
    bool lumaMLTZero = lumaMM < 0.0;
    lumaEndN -= lumaNN * 0.5;
    lumaEndP -= lumaNN * 0.5;
    bool doneN = abs( lumaEndN ) >= gradientScaled;
    bool doneP = abs( lumaEndP ) >= gradientScaled;

    // steps 1..11 (the first step, 1.0, was taken above). Written out with a macro: the engine's D3DX compiler has no [unroll].
#define FXAA_STEP( S )     if ( !( doneN && doneP ) )     {         if ( !doneN ) posN -= offNP * S;         if ( !doneP ) posP += offNP * S;         if ( !doneN ) lumaEndN = LumaAt( posN ) - lumaNN * 0.5;         if ( !doneP ) lumaEndP = LumaAt( posP ) - lumaNN * 0.5;         doneN = abs( lumaEndN ) >= gradientScaled;         doneP = abs( lumaEndP ) >= gradientScaled;     }
    FXAA_STEP( 1.0 )
    FXAA_STEP( 1.0 )
    FXAA_STEP( 1.0 )
    FXAA_STEP( 1.0 )
    FXAA_STEP( 1.5 )
    FXAA_STEP( 2.0 )
    FXAA_STEP( 2.0 )
    FXAA_STEP( 2.0 )
    FXAA_STEP( 2.0 )
    FXAA_STEP( 4.0 )
    FXAA_STEP( 8.0 )

    float dstN = horzSpan ? ( posM.x - posN.x ) : ( posM.y - posN.y );
    float dstP = horzSpan ? ( posP.x - posM.x ) : ( posP.y - posM.y );
    bool goodSpanN = ( lumaEndN < 0.0 ) != lumaMLTZero;
    float spanLength = dstP + dstN;
    bool goodSpanP = ( lumaEndP < 0.0 ) != lumaMLTZero;
    float spanLengthRcp = 1.0 / spanLength;
    bool directionN = dstN < dstP;
    float dst = min( dstN, dstP );
    bool goodSpan = directionN ? goodSpanN : goodSpanP;
    float subpixG = subpixF * subpixF;
    float pixelOffset = dst * -spanLengthRcp + 0.5;
    float subpixH = subpixG * subpix;
    float pixelOffsetGood = goodSpan ? pixelOffset : 0.0;
    float pixelOffsetSubpix = max( pixelOffsetGood, subpixH );
    if ( !horzSpan ) posM.x += pixelOffsetSubpix * lengthSign;
    if ( horzSpan ) posM.y += pixelOffsetSubpix * lengthSign;
    result = float4( Fetch( posM ).rgb, rgbyM.a );
    }
    return result;
}

technique TFxaa
{
    pass P0
    {
        AlphaBlendEnable = false;
        AlphaTestEnable = false;
        ZEnable = false;
        ZWriteEnable = false;
        StencilEnable = false;
        ScissorTestEnable = false;
        CullMode = NONE;
        FillMode = SOLID;

        VertexShader = compile vs_3_0 FxaaVS();
        PixelShader = compile ps_3_0 FxaaPS();
    }
}
