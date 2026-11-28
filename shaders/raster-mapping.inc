// Selected line pattern: odd clocks, even clocks, nominal clocks, field lines.
// The exception span indexes one-based line numbers and clock deltas.

float raster_clock_start(float line, vec4 pattern, ivec2 exception_span)
{
    float pairs = floor(line * 0.5);
    float clocks = pattern.x == pattern.y ? line * pattern.x
        : pairs * (pattern.x + pattern.y) + (line - pairs * 2.0) * pattern.x;
    for (int i = 0; i < exception_span.y; ++i) {
        ivec2 exception = TIMING_RASTER_EXCEPTIONS[exception_span.x + i];
        if (line >= float(exception.x))
            clocks += float(exception.y);
    }
    return clocks;
}

vec2 raster_line_range(vec4 pattern, ivec2 exception_span, float line, double width)
{
    if (exception_span.x == -1) {
        float start = float(ceil(double(line) * width));
        float end = float(ceil(double(line + 1.0) * width));
        return vec2(start, end - start);
    }
    if (exception_span.x < 0)
        return vec2(uintBitsToFloat(0x7fc00000u));
    float clock_start = raster_clock_start(line, pattern, exception_span);
    float clock_end = raster_clock_start(line + 1.0, pattern, exception_span);
    float start = float(ceil(double(clock_start) * width / double(pattern.z)));
    float end = float(ceil(double(clock_end) * width / double(pattern.z)));
    return vec2(start, end - start);
}

vec2 raster_position(vec4 pattern, ivec2 exception_span, float sample_index, double width)
{
    if (exception_span.x == -1) {
        float line = float(floor(double(sample_index) / width));
        float start = float(ceil(double(line) * width));
        return vec2(sample_index - start, line);
    }
    if (exception_span.x < 0)
        return vec2(uintBitsToFloat(0x7fc00000u));

    if (exception_span.y == 0 && pattern.x == pattern.z && pattern.y == pattern.z) {
        float line = float(floor(double(sample_index) / width));
        float start = float(ceil(double(raster_clock_start(line, pattern, exception_span)) * width / double(pattern.z)));
        return vec2(sample_index - start, line);
    }

    if (exception_span.y <= 1) {
        double clock = floor(double(sample_index) * double(pattern.z) / width);
        float line;
        if (exception_span.y == 1) {
            ivec2 exception = TIMING_RASTER_EXCEPTIONS[exception_span.x];
            float exception_line = float(exception.x - 1);
            float start_clock = raster_clock_start(exception_line, pattern, exception_span);
            float end_clock = raster_clock_start(exception_line + 1.0, pattern, exception_span);
            double start = ceil(double(start_clock) * width / double(pattern.z));
            double end = ceil(double(end_clock) * width / double(pattern.z));
            if (double(sample_index) >= start && double(sample_index) < end)
                return vec2(sample_index - float(start), exception_line);
            if (double(sample_index) >= end)
                clock -= double(exception.y);
        }
        double pair_clocks = double(pattern.x + pattern.y);
        double pair = floor(clock / pair_clocks);
        line = float(pair * 2.0lf + (clock - pair * pair_clocks >= double(pattern.x) ? 1.0lf : 0.0lf));
        if (line >= 0.0 && line < ceil(pattern.w)) {
            double start = ceil(double(raster_clock_start(line, pattern, exception_span)) * width / double(pattern.z));
            double end = ceil(double(raster_clock_start(line + 1.0, pattern, exception_span)) * width / double(pattern.z));
            if (start <= double(sample_index) && double(sample_index) < end)
                return vec2(sample_index - float(start), line);
        }
        if (exception_span.y == 0 && line >= ceil(pattern.w)) {
            float start = float(ceil(double(raster_clock_start(line, pattern, exception_span)) * width / double(pattern.z)));
            return vec2(sample_index - start, line);
        }
    }

    float low = 0.0;
    float high = floor(pattern.w);
    while (low < high) {
        float middle = floor((low + high + 1.0) * 0.5);
        double start = ceil(double(raster_clock_start(middle, pattern, exception_span)) * width / double(pattern.z));
        if (start <= double(sample_index))
            low = middle;
        else
            high = middle - 1.0;
    }
    float start = float(ceil(double(raster_clock_start(low, pattern, exception_span)) * width / double(pattern.z)));
    return vec2(sample_index - start, low);
}
