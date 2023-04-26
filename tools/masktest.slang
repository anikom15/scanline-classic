#version 450

layout(push_constant) uniform Push
{
	vec4 SourceSize;
	vec4 OriginalSize;
	vec4 OutputSize;
	uint FrameCount;
	float picker, toggle;
} params;

#pragma parameter picker "Mask Picker" 0.0 0.0 24.0 1.0
int mask_picker = int(params.picker);
#pragma parameter toggle "Mask Toggle" 1.0 0.0 1.0 1.0
bool mask_toggle = bool(params.toggle);

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

#include "subpixel_masks.h"

void main()
{
   vec3 img = texture(Source, vTexCoord).rgb;
   img *= (mask_toggle) ? mask_weights(vTexCoord.xy * params.OutputSize.xy, 1.0, mask_picker) : vec3(1.0);
   FragColor = vec4(img, 1.0);
}
