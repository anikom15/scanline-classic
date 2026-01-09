#version 450

#pragma parameter INTERPOLATION_3DO_HEADER " —— 3DO Interpolation —— " 0.0 0.0 0.0 0.0
#pragma parameter INTERPOLATION_MODE "Interpolation mode (nearest, bilinear, original)" 2.0 0.0 2.0 1.0

layout(push_constant) uniform Push
{
	vec4 SourceSize;
	vec4 OriginalSize;
	vec4 OutputSize;
	uint FrameCount;
    float INTERPOLATION_MODE;
} params;

#define INTERPOLATION_MODE params.INTERPOLATION_MODE

layout(std140, set = 0, binding = 0) uniform UBO
{
	mat4 MVP;
} global;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main()
{
   gl_Position = global.MVP * Position;
   vTexCoord = TexCoord;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

vec4 nearest_neighbor(vec2 tc)
{
    return texture(Source, tc);
}

vec4 bilinear_interpolation(vec2 tc)
{
    vec2 sourceSize = params.SourceSize.xy;
    vec2 texelSize = 1.0 / sourceSize;
    
    // Get fractional part of texture coordinate
    vec2 f = fract(tc * sourceSize - 0.5);
    vec2 texCoord = (floor(tc * sourceSize - 0.5) + 0.5) / sourceSize;
    
    // Sample four corners
    vec4 p0q0 = texture(Source, texCoord);
    vec4 p1q0 = texture(Source, texCoord + vec2(texelSize.x, 0.0));
    vec4 p0q1 = texture(Source, texCoord + vec2(0.0, texelSize.y));
    vec4 p1q1 = texture(Source, texCoord + vec2(texelSize.x, texelSize.y));
    
    // Blend
    vec4 pq0 = mix(p0q0, p1q0, f.x);
    vec4 pq1 = mix(p0q1, p1q1, f.x);
    
    return mix(pq0, pq1, f.y);
}

vec4 special_interpolation(vec2 tc)
{
    // TODO: Implement special interpolation mode
    return texture(Source, tc);
}

void main()
{
    vec4 color;
    
    if (INTERPOLATION_MODE < 0.5)
        color = nearest_neighbor(vTexCoord);
    else if (INTERPOLATION_MODE < 1.5)
        color = bilinear_interpolation(vTexCoord);
    else if (INTERPOLATION_MODE < 2.5)
        color = special_interpolation(vTexCoord);
    
    FragColor = vec4(color.rgb, 1.0);
}
