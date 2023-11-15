#define PI 3.1415926538


//--------------------------------------------------------------------------------------
// Constant Buffer Variables
//--------------------------------------------------------------------------------------
struct OpaqueCBType
{
    float4x4 worldMatrix;
    float4x4 viewProjMatrix;
    float4 cameraPosition;
    float4 lightDirection;
    float4 lightColor;
    float4x4 shadowTransform;
    float shadowBias;
};

ConstantBuffer<OpaqueCBType> cb : register(b0);


//--------------------------------------------------------------------------------------
// I/O Structures
//--------------------------------------------------------------------------------------
struct VS_INPUT
{
    float4 position : POSITION;
};

struct VS_OUTPUT
{
    float4 position : SV_Position;
};

struct PS_OUTPUT
{
    float4 color : SV_Target;
};

struct PatchTess
{
    float edgeTess[4] : SV_TessFactor;
    float insideTess[2] : SV_InsideTessFactor;
};

struct HS_OUT
{
    float3 position : POSITION;
};

struct DS_OUT
{
    float4 position : SV_Position;
    float3 catPos : POSITION;
};


//--------------------------------------------------------------------------------------
// Texture & Sampler Variables
//--------------------------------------------------------------------------------------
Texture2D texMap[5] : register(t0);
SamplerState samAnisotropic : register(s0);
SamplerComparisonState samShadow : register(s1);

//--------------------------------------------------------------------------------------
// Vertex Shader
//--------------------------------------------------------------------------------------
VS_OUTPUT VS(VS_INPUT input)
{
    VS_OUTPUT output;
    output.position = input.position;

    return output;
}


//--------------------------------------------------------------------------------------
// Constant Hull Shader
//--------------------------------------------------------------------------------------

static const float near = 20.0f;
static const float far = 150.0f;

float CalcTessFactor(float3 p)
{
    float d = distance(p, cb.cameraPosition.xyz);
    float s = saturate((d - near) / (far - near));
    return pow(2.0f, -8 * pow(s, 0.5f) + 8);
}

PatchTess ConstantHS(InputPatch<VS_OUTPUT, 4> patch, int patchID : SV_PrimitiveID)
{
    PatchTess output;

    float3 localPos = 0.25f * (patch[0].position + patch[1].position + patch[2].position + patch[3].position);
    float3 worldPos = mul(float4(localPos, 1.0f), cb.worldMatrix).xyz;

    float3 p0 = normalize(patch[0].position) * 150.0f;
    float3 p1 = normalize(patch[1].position) * 150.0f;
    float3 p2 = normalize(patch[2].position) * 150.0f;
    float3 p3 = normalize(patch[3].position) * 150.0f;

    float3 e0 = 0.5f * (p0 + p2);
    float3 e1 = 0.5f * (p0 + p1);
    float3 e2 = 0.5f * (p1 + p3);
    float3 e3 = 0.5f * (p2 + p3);
    float3 c = normalize(worldPos) * 150.0f;

    output.edgeTess[0] = CalcTessFactor(e0);
    output.edgeTess[1] = CalcTessFactor(e1);
    output.edgeTess[2] = CalcTessFactor(e2);
    output.edgeTess[3] = CalcTessFactor(e3);

    output.insideTess[0] = CalcTessFactor(c);
    output.insideTess[1] = output.insideTess[0];

    return output;
}


//--------------------------------------------------------------------------------------
// Control Point Hull Shader
//--------------------------------------------------------------------------------------
[domain("quad")]
[partitioning("integer")]
[outputtopology("triangle_cw")]
[outputcontrolpoints(4)]
[patchconstantfunc("ConstantHS")]
HS_OUT HS(InputPatch<VS_OUTPUT, 4> input, int vertexIdx : SV_OutputControlPointID, int patchID : SV_PrimitiveID)
{
    HS_OUT output;
    output.position = input[vertexIdx].position;

    return output;
}


//--------------------------------------------------------------------------------------
// Domain Shader
//--------------------------------------------------------------------------------------

static const float2 size = { 2.0, 0.0 };
static const float3 off = { -1.0, 0.0, 1.0 };
static const float2 nTex = { 11520, 11520 };

[domain("quad")]
DS_OUT DS(const OutputPatch<HS_OUT, 4> input, float2 uv : SV_DomainLocation, PatchTess patch)
{
    DS_OUT output;
	
	// Bilinear interpolation (position).
    float3 v1 = lerp(input[0].position, input[1].position, uv.x);
    float3 v2 = lerp(input[2].position, input[3].position, uv.x);
    float3 position = lerp(v1, v2, uv.y);

    // Get tessellation level.
    float tess = patch.edgeTess[0];

    // Calculate LOD level for height map.
    // range is 0 ~ 5 (mipmap has 10 levels but use only 6).
    float level = max(0, 8 - sqrt(tess) - 3);

    // Get normalized cartesian position.
    float3 normCatPos = normalize(position);

	// Convert cartesian to polar.
    float theta = atan2(normCatPos.z, normCatPos.x);
    theta = sign(theta) == -1 ? 2 * PI + theta : theta;
    float phi = acos(normCatPos.y);

    // Convert polar coordinates to texture coordinates for height map.
    float2 gTexCoord = float2(theta / (2 * PI), phi / PI);

    // Divide texture coordinates into two parts and re-mapping.
    int texIndex = round(gTexCoord.x) + 2;
    float2 sTexCoord = float2(texIndex == 0 ? gTexCoord.x * 2 : (gTexCoord.x - 0.5f) * 2.0f, gTexCoord.y);

    // Get height from texture.
    float height = texMap[texIndex].SampleLevel(samAnisotropic, sTexCoord, level).r;
    float3 catPos = normCatPos * (150.0f + height * 0.5f);

    // Multiply MVP matrices.
    output.position = mul(float4(catPos, 1.0f), cb.worldMatrix);
    output.position = mul(output.position, cb.viewProjMatrix);

    // Set cartesian position for calc texture coordinates in pixel shader.
    output.catPos = catPos;

    return output;
}


//--------------------------------------------------------------------------------------
// Pixel Shader
//--------------------------------------------------------------------------------------

float3 GetNormalFromHeight(Texture2D tex, float2 sTexCoord, float multiplier)
{
    float2 offxy = { off.x / nTex.x, off.y / nTex.y };
    float2 offzy = { off.z / nTex.x, off.y / nTex.y };
    float2 offyx = { off.y / nTex.x, off.x / nTex.y };
    float2 offyz = { off.y / nTex.x, off.z / nTex.y };

    float a = tex.Sample(samAnisotropic, sTexCoord + offxy * multiplier).r;
    float b = tex.Sample(samAnisotropic, sTexCoord + offzy * multiplier).r;
    float c = tex.Sample(samAnisotropic, sTexCoord + offyx * multiplier).r;
    float d = tex.Sample(samAnisotropic, sTexCoord + offyz * multiplier).r;

    float3 va = normalize(float3(size.xy, (b - a) * 0.5f));
    float3 vb = normalize(float3(size.yx, (d - c) * 0.5f));

    return normalize(cross(va, vb));
}

float CalcShadowFactor(float4 shadowPosH)
{
    // Complete projection by doing division by w.
    shadowPosH.xyz /= shadowPosH.w;

    // Depth in NDC space.
    float depth = shadowPosH.z - cb.shadowBias;

    uint width, height, numMips;
    texMap[4].GetDimensions(0, width, height, numMips);

    // Texel size.
    float dx = 1.0f / (float) width;

    float percentLit = 0.0f;
    const float2 offsets[9] =
    {
        float2(-dx, -dx), float2(0.0f, -dx), float2(dx, -dx),
        float2(-dx, 0.0f), float2(0.0f, 0.0f), float2(dx, 0.0f),
        float2(-dx, +dx), float2(0.0f, +dx), float2(dx, +dx)
    };

    [unroll]
    for (int i = 0; i < 9; ++i)
    {
        percentLit += texMap[4].SampleCmpLevelZero(samShadow, saturate(shadowPosH.xy + offsets[i]), depth).r;
    }
    
    return percentLit / 9.0f;
}

float hash(float2 p)
{
    return frac(1e4 * sin(17.0 * p.x + p.y * 0.1) * (0.1 + abs(sin(p.y * 13.0 + p.x))));
}

float noise(float2 x)
{
    float2 i = floor(x);
    float2 f = frac(x);

	// Four corners in 2D of a tile
    float a = hash(i);
    float b = hash(i + float2(1.0, 0.0));
    float c = hash(i + float2(0.0, 1.0));
    float d = hash(i + float2(1.0, 1.0));

    float2 u = f * f * (3.0 - 2.0 * f);
    return lerp(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

PS_OUTPUT PS(DS_OUT input)
{
    PS_OUTPUT output;

    // Convert cartesian to polar.
    float3 normCatPos = normalize(input.catPos);

    float theta = atan2(normCatPos.z, normCatPos.x);
    theta = sign(theta) == -1 ? 2 * PI + theta : theta;
    float phi = acos(normCatPos.y);

    // Convert polar coordinates to texture coordinates.
    float2 gTexCoord = float2(theta / (2 * PI), phi / PI);

    // Divide texture coordinates into two parts and re-mapping.
	int texIndex = round(gTexCoord.x);
    float2 sTexCoord = float2(texIndex == 0 ? gTexCoord.x * 2 : (gTexCoord.x - 0.5f) * 2.0f, gTexCoord.y);

    // Calculate local normal from height map.
    float3 n1 = GetNormalFromHeight(texMap[texIndex + 2], sTexCoord, 1.0f);
    float3 n2 = GetNormalFromHeight(texMap[texIndex + 2], sTexCoord, 2.0f);
	float3 n3 = GetNormalFromHeight(texMap[texIndex + 2], sTexCoord, 3.0f);

    float3 localNormal = (n1 * 3.0f + n2 * 2.0f + n3 * 1.0f) / 6.0f;
    localNormal = normalize(localNormal);

    // Calculate TBN Matrix.
    float3 N = normCatPos;
    float3 T = float3(-sin(theta), 0, cos(theta));
    float3 B = cross(N, T);

    // Calculate Normal.
    float3x3 TBN = float3x3(normalize(T), normalize(B), normalize(N));
    float3 normal = normalize(mul(localNormal, TBN));

    // Merge Results.
    float4 texColor = texMap[texIndex].Sample(samAnisotropic, sTexCoord);
    float3 diffuse = saturate(dot(normal, -cb.lightDirection.xyz)) * cb.lightColor.xyz;
    float3 ambient = float3(0.008f, 0.008f, 0.008f) * cb.lightColor.xyz;

    float shadowFactor = CalcShadowFactor(mul(float4(input.catPos, 1.0f), cb.shadowTransform));
    float shadowCorrector = lerp(0.75f, 1.0f, max(dot(normCatPos, -cb.lightDirection.xyz), 0.0f));

    float noise1 = noise(sTexCoord * 10000.0f);
    float noise2 = noise(sTexCoord * 20000.0f);

    float h = distance(input.catPos, float3(0, 0, 0));
    h -= 150.0f;

    float4 final = float4(saturate((diffuse * saturate(shadowFactor + shadowCorrector) + ambient) * texColor.rgb * lerp(0.95f, 1.0f, noise1) * lerp(0.92f, 1.0f, noise2) * lerp(0.98f, 1.0f, h)), texColor.a);
	final.a = 1;
    output.color = final;

    return output;
}