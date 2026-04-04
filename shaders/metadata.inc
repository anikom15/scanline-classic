/* Filename: metadata.inc

   Copyright (C) 2026 W. M. Martinez

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 3 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <https://www.gnu.org/licenses/>. */

const int METADATA_FS_ORIGINAL = 0;
const int METADATA_DATA_LENGTH_LO = 1;
const int METADATA_DATA_LENGTH_HI = 2;
const int METADATA_INITIAL_FIELD_PHASE_FRAC = 3;
const int METADATA_FRAME_WIDTH = 4;
const int METADATA_FRAME_HEIGHT = 5;
const int METADATA_FS_CURRENT = 6;
const int METADATA_FULL_FRAME_HEIGHT = 7;
const int METADATA_IS_INTERLACED = 8;
const int METADATA_FIELD = 9;
const int METADATA_COUNT = 10;

const float METADATA_UINT32_SPAN = 4294967296.0;
const uint METADATA_BYTE_MASK = 0xffu;

struct MetadataLayout {
    float OriginX;
    float OriginY;
    float ColumnHeight;
};

struct MetadataState {
    float FS_ORIGINAL;
    float INITIAL_FIELD_PHASE_FRAC;
    float FrameWidth;
    float FrameHeight;
    float FullFrameHeight;
    float IsInterlaced;
    float Field;
    float PhaseRelSample;
    float FsCurrent;
    uvec2 DataLength;
};

MetadataState metadata_init(
    float FS_ORIGINAL,
    float INITIAL_FIELD_PHASE_FRAC,
    float FrameWidth,
    float FrameHeight,
    float FullFrameHeight,
    float IsInterlaced,
    float Field,
    float PhaseRelSample,
    float FsCurrent,
    uvec2 DataLength)
{
    MetadataState metadata;
    metadata.FS_ORIGINAL = FS_ORIGINAL;
    metadata.INITIAL_FIELD_PHASE_FRAC = INITIAL_FIELD_PHASE_FRAC;
    metadata.FrameWidth = FrameWidth;
    metadata.FrameHeight = FrameHeight;
    metadata.FullFrameHeight = FullFrameHeight;
    metadata.IsInterlaced = IsInterlaced;
    metadata.Field = Field;
    metadata.PhaseRelSample = PhaseRelSample;
    metadata.FsCurrent = FsCurrent;
    metadata.DataLength = DataLength;
    return metadata;
}

MetadataState metadata_init(
    float FS_ORIGINAL,
    float INITIAL_FIELD_PHASE_FRAC,
    float FrameWidth,
    float FrameHeight,
    float PhaseRelSample,
    float FsCurrent,
    uvec2 DataLength)
{
    return metadata_init(
        FS_ORIGINAL,
        INITIAL_FIELD_PHASE_FRAC,
        FrameWidth,
        FrameHeight,
        FrameHeight,
        0.0,
        0.0,
        PhaseRelSample,
        FsCurrent,
        DataLength
    );
}

uvec2 metadata_pack_count_u64(float value)
{
    float clamped_value = max(floor(value + 0.5), 0.0);
    uint low = uint(mod(clamped_value, METADATA_UINT32_SPAN));
    uint high = uint(floor(clamped_value / METADATA_UINT32_SPAN));
    return uvec2(low, high);
}

vec4 metadata_pack_u32_to_bytes(uint value)
{
    return vec4(
        float((value >> 0u) & METADATA_BYTE_MASK),
        float((value >> 8u) & METADATA_BYTE_MASK),
        float((value >> 16u) & METADATA_BYTE_MASK),
        float((value >> 24u) & METADATA_BYTE_MASK)
    );
}

vec4 metadata_pack_f32_to_bytes(float value)
{
    return metadata_pack_u32_to_bytes(floatBitsToUint(value));
}

uint metadata_unpack_u32_from_bytes(vec4 packed)
{
    uvec4 bytes = uvec4(round(clamp(packed, vec4(0.0), vec4(255.0))));
    return ((bytes.x & METADATA_BYTE_MASK) << 0u)
        | ((bytes.y & METADATA_BYTE_MASK) << 8u)
        | ((bytes.z & METADATA_BYTE_MASK) << 16u)
        | ((bytes.w & METADATA_BYTE_MASK) << 24u);
}

float metadata_unpack_f32_from_bytes(vec4 packed)
{
    return uintBitsToFloat(metadata_unpack_u32_from_bytes(packed));
}

MetadataLayout metadata_get_layout(vec2 texture_size)
{
    MetadataLayout metadata_layout;
    metadata_layout.OriginX = texture_size.x - 1.0;
    metadata_layout.OriginY = texture_size.y - 1.0;
    metadata_layout.ColumnHeight = texture_size.y;
    return metadata_layout;
}

ivec2 metadata_texel_coord(int metadata_index, vec2 texture_size)
{
    int width = max(int(floor(texture_size.x + 0.5)), 1);
    int height = max(int(floor(texture_size.y + 0.5)), 1);
    int col_offset = metadata_index / height;
    int row_offset = metadata_index - col_offset * height;
    return ivec2(width - 1 - col_offset, height - 1 - row_offset);
}

vec2 metadata_texel_center_uv(int metadata_index, vec2 texture_size)
{
    return (vec2(metadata_texel_coord(metadata_index, texture_size)) + 0.5) / texture_size;
}

int metadata_index_for_pixel(
    float output_x,
    float output_y,
    float metadata_origin_x,
    float metadata_origin_y,
    float metadata_column_height)
{
    if (output_x > metadata_origin_x || output_y > metadata_origin_y)
        return -1;

    float col_offset = metadata_origin_x - output_x;
    float row_offset = metadata_origin_y - output_y;
    return int(col_offset * metadata_column_height + row_offset);
}

bool metadata_fragment_is_item(
    MetadataLayout metadata_layout,
    float output_x,
    float output_y,
    out int metadata_index)
{
    metadata_index = metadata_index_for_pixel(
        output_x,
        output_y,
        metadata_layout.OriginX,
        metadata_layout.OriginY,
        metadata_layout.ColumnHeight
    );
    return metadata_index >= 0 && metadata_index < METADATA_COUNT;
}

vec4 metadata_fetch_raw(sampler2D source, vec2 texture_size, int metadata_index)
{
    return texelFetch(source, metadata_texel_coord(metadata_index, texture_size), 0);
}

MetadataState metadata_read(sampler2D source, vec2 texture_size, float PhaseRelSample)
{
    MetadataState metadata;
    metadata.FS_ORIGINAL = metadata_unpack_f32_from_bytes(
        metadata_fetch_raw(source, texture_size, METADATA_FS_ORIGINAL)
    );
    metadata.DataLength = uvec2(
        metadata_unpack_u32_from_bytes(metadata_fetch_raw(source, texture_size, METADATA_DATA_LENGTH_LO)),
        metadata_unpack_u32_from_bytes(metadata_fetch_raw(source, texture_size, METADATA_DATA_LENGTH_HI))
    );
    metadata.INITIAL_FIELD_PHASE_FRAC = metadata_unpack_f32_from_bytes(
        metadata_fetch_raw(source, texture_size, METADATA_INITIAL_FIELD_PHASE_FRAC)
    );
    metadata.FrameWidth = metadata_unpack_f32_from_bytes(
        metadata_fetch_raw(source, texture_size, METADATA_FRAME_WIDTH)
    );
    metadata.FrameHeight = metadata_unpack_f32_from_bytes(
        metadata_fetch_raw(source, texture_size, METADATA_FRAME_HEIGHT)
    );
    metadata.FullFrameHeight = metadata_unpack_f32_from_bytes(
        metadata_fetch_raw(source, texture_size, METADATA_FULL_FRAME_HEIGHT)
    );
    metadata.IsInterlaced = metadata_unpack_f32_from_bytes(
        metadata_fetch_raw(source, texture_size, METADATA_IS_INTERLACED)
    );
    metadata.Field = metadata_unpack_f32_from_bytes(
        metadata_fetch_raw(source, texture_size, METADATA_FIELD)
    );
    metadata.PhaseRelSample = PhaseRelSample;
    metadata.FsCurrent = metadata_unpack_f32_from_bytes(
        metadata_fetch_raw(source, texture_size, METADATA_FS_CURRENT)
    );
    if (metadata.FullFrameHeight <= 0.0)
        metadata.FullFrameHeight = metadata.FrameHeight;
    return metadata;
}

MetadataState metadata_setFrameWidth(MetadataState metadata, float FrameWidth)
{
    metadata.FrameWidth = FrameWidth;
    return metadata;
}

MetadataState metadata_setFrameHeight(MetadataState metadata, float FrameHeight)
{
    metadata.FrameHeight = FrameHeight;
    return metadata;
}

MetadataState metadata_setFullFrameHeight(MetadataState metadata, float FullFrameHeight)
{
    metadata.FullFrameHeight = FullFrameHeight;
    return metadata;
}

MetadataState metadata_setIsInterlaced(MetadataState metadata, float IsInterlaced)
{
    metadata.IsInterlaced = IsInterlaced;
    return metadata;
}

MetadataState metadata_setField(MetadataState metadata, float Field)
{
    metadata.Field = Field;
    return metadata;
}

MetadataState metadata_setPhaseRelSample(MetadataState metadata, float PhaseRelSample)
{
    metadata.PhaseRelSample = PhaseRelSample;
    return metadata;
}

MetadataState metadata_setFsCurrent(MetadataState metadata, float FsCurrent)
{
    metadata.FsCurrent = FsCurrent;
    return metadata;
}

MetadataState metadata_setDataLength(MetadataState metadata, uvec2 DataLength)
{
    metadata.DataLength = DataLength;
    return metadata;
}

float metadata_data_length_to_float(uvec2 DataLength)
{
    return float(DataLength.y) * METADATA_UINT32_SPAN + float(DataLength.x);
}

MetadataState metadata_repack(
    MetadataState metadata,
    float FrameWidth,
    float FrameHeight,
    float PhaseRelSample,
    float FsCurrent,
    uvec2 DataLength)
{
    metadata = metadata_setFrameWidth(metadata, FrameWidth);
    metadata = metadata_setFrameHeight(metadata, FrameHeight);
    metadata = metadata_setPhaseRelSample(metadata, PhaseRelSample);
    metadata = metadata_setFsCurrent(metadata, FsCurrent);
    metadata = metadata_setDataLength(metadata, DataLength);
    return metadata;
}

MetadataState metadata_repack_from_source(
    sampler2D source,
    vec2 texture_size,
    float FrameWidth,
    float FrameHeight,
    float PhaseRelSample,
    float FsCurrent,
    uvec2 DataLength)
{
    MetadataState metadata = metadata_read(source, texture_size, PhaseRelSample);
    return metadata_repack(
        metadata,
        FrameWidth,
        FrameHeight,
        PhaseRelSample,
        FsCurrent,
        DataLength
    );
}

MetadataState metadata_repack_from_source_length(
    sampler2D source,
    vec2 texture_size,
    float FrameWidth,
    float FrameHeight,
    float PhaseRelSample,
    float FsCurrent,
    float DataLengthValue)
{
    return metadata_repack_from_source(
        source,
        texture_size,
        FrameWidth,
        FrameHeight,
        PhaseRelSample,
        FsCurrent,
        metadata_pack_count_u64(DataLengthValue)
    );
}

float metadata_compute_phase_rel_sample(float sample_x, float sample_y, float FrameWidth)
{
    float output_index = sample_x;
    float field_output_index = sample_y * FrameWidth + output_index;
    float resample_phase = field_output_index;  // Delta = 1.0, no resampling
    return fract(resample_phase);
}

vec4 metadata_encode_item(MetadataState metadata, int metadata_index)
{
    if (metadata_index == METADATA_FS_ORIGINAL)
        return metadata_pack_f32_to_bytes(metadata.FS_ORIGINAL);

    if (metadata_index == METADATA_DATA_LENGTH_LO)
        return metadata_pack_u32_to_bytes(metadata.DataLength.x);

    if (metadata_index == METADATA_DATA_LENGTH_HI)
        return metadata_pack_u32_to_bytes(metadata.DataLength.y);

    if (metadata_index == METADATA_INITIAL_FIELD_PHASE_FRAC)
        return metadata_pack_f32_to_bytes(metadata.INITIAL_FIELD_PHASE_FRAC);

    if (metadata_index == METADATA_FRAME_WIDTH)
        return metadata_pack_f32_to_bytes(metadata.FrameWidth);

    if (metadata_index == METADATA_FRAME_HEIGHT)
        return metadata_pack_f32_to_bytes(metadata.FrameHeight);

    if (metadata_index == METADATA_FS_CURRENT)
        return metadata_pack_f32_to_bytes(metadata.FsCurrent);

    if (metadata_index == METADATA_FULL_FRAME_HEIGHT)
        return metadata_pack_f32_to_bytes(metadata.FullFrameHeight);

    if (metadata_index == METADATA_IS_INTERLACED)
        return metadata_pack_f32_to_bytes(metadata.IsInterlaced);

    if (metadata_index == METADATA_FIELD)
        return metadata_pack_f32_to_bytes(metadata.Field);

    return vec4(0.0);
}

vec4 metadata_apply_to_data(vec3 color, MetadataState metadata)
{
    return vec4(color, metadata.PhaseRelSample);
}
