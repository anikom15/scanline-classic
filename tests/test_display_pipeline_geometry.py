import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_dyadic_pyramid import shader_function


ROOT = Path(__file__).resolve().parent.parent


def load_json(*parts):
    return json.loads(ROOT.joinpath(*parts).read_text(encoding='utf-8'))


def pal_mega_drive_width(sample_rate_hz):
    base = load_json('presetdata', 'params', 'sys', 'md', 'base.json')['parameters']
    pal = load_json('presetdata', 'params', 'sys', 'md', 'pal.json')['parameters']
    clock_mhz = (pal['PIXEL_CLOCK_WHOLE'] + pal['PIXEL_CLOCK_FRAC6'] * 1.0e-6
                 + pal['PIXEL_CLOCK_FRAC11'] * 1.0e-11)
    return round(base['H_FREQ'] * sample_rate_hz / (clock_mhz * 1.0e6))


class DisplayPipelineGeometryTests(unittest.TestCase):
    def test_display_resampler_restores_physical_line_positions(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        source = (ROOT / 'shaders' / 'display-rgb-filter.slang').read_text(encoding='utf-8')
        profiles = (ROOT / 'shaders' / 'timing-profiles.inc').read_text(encoding='utf-8')
        fragment = source.split('#pragma stage fragment', 1)[1]
        main = shader_function(fragment, 'void main()').replace('void main()', 'void render_sample()', 1)
        main = main.split('    if (BW_MODE < 0.5)', 1)[0] + '    FragColor = vec4(color, 1.0);\n}\n'
        harness = r'''
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
using std::ceil; using std::floor; using std::min; using std::max;
using uint = unsigned int;
float max(float x, double y) { return std::max(x,float(y)); }
float clamp(float v, float a, float b) { return std::clamp(v,a,b); }
float mix(float a,float b,float f) { return a*(1-f)+b*f; }
struct vec2 {
    float x,y;
    vec2(float a=0,float b=0): x(a),y(b) {}
};
vec2 operator*(vec2 a,vec2 b) { return {a.x*b.x,a.y*b.y}; }
struct vec3 {
    float r,g,b;
    vec3(float a=0): r(a),g(a),b(a) {}
    vec3(float a,float c,float d): r(a),g(c),b(d) {}
    vec3& operator+=(vec3 v) { r+=v.r; g+=v.g; b+=v.b; return *this; }
    vec3& operator/=(float v) { r/=v; g/=v; b/=v; return *this; }
};
vec3 operator*(float s,vec3 v) { return {s*v.r,s*v.g,s*v.b}; }
struct vec4 {
    vec3 rgb; float a;
    vec4(float x=0): rgb(x),a(x) {}
    vec4(vec3 c,float d): rgb(c),a(d) {}
};
struct Size { float x,y; vec2 xy; };
struct { Size OutputSize, OriginalSize, SourceSize; } config;
struct { uint FrameCount; float FIELD_ODD; } global;
struct { float Delta, taps; } pfilt;
float OutputFrameHeight, InputDataLength, OutputDataLength, InputFrameWidth, OutputFrameWidth;
float DeskewSampleRatio, LineCarryClocksOut, ClockFactorOut;
vec2 vTexCoord; vec4 FragColor; int Source, profile_mode;
#define TIMING_PROFILE_MODE profile_mode
#define OPTION_DEBUG
#define OPTION_CRISPY
#define DISPLAY_RGB_FILTER_BYPASS 1.0
#define DESKEW_BYPASS 0.0
#define EPS 1.0e-6f
float uintBitsToFloat(uint) { return std::numeric_limits<float>::quiet_NaN(); }
float zoh_area(float,float,float) { return 1; }
vec4 fetch_input_sample(int,vec2,float index,float,float) { return vec4(vec3(index),1); }
'''
        checks = r'''
void sample(int x,int y,float expected,bool padding=false) {
    vTexCoord=vec2((x+0.5f)/2048,(y+0.5f)/512);
    render_sample();
    if (padding ? FragColor.a!=0 : (FragColor.a!=1 || FragColor.rgb.r!=expected))
        throw std::runtime_error("display row does not map to the physical stream");
}
int main() {
    config.OutputSize={2048,512,{2048,512}};
    config.SourceSize={2048,512,{2048,512}};
    config.OriginalSize={256,239,{256,239}};
    profile_mode=1; global.FrameCount=1; global.FIELD_ODD=0;
    OutputFrameHeight=262; InputFrameWidth=1364; OutputFrameWidth=1364;
    InputDataLength=OutputDataLength=357364; pfilt.Delta=1; pfilt.taps=1;
    ClockFactorOut=4; LineCarryClocksOut=0; DeskewSampleRatio=1;
    sample(1359,240,240*1364+1359);
    sample(1360,240,0,true);
    sample(0,241,241*1364-4);
    sample(1363,261,357363);
    OutputFrameWidth=2047; OutputDataLength=262*2047-6; pfilt.Delta=2047.0f/1364.0f;
    sample(0,241,float(std::floor(double(241*2047-6)*1364/2047+0.5)));
    sample(2041,240,0,true);
    profile_mode=2; global.FrameCount=0; config.OriginalSize.y=478;
    OutputFrameHeight=312; OutputFrameWidth=1364; InputFrameWidth=1364;
    InputDataLength=OutputDataLength=425572; pfilt.Delta=1;
    sample(0,311,311*1364);
    sample(1363,311,312*1364-1);
}
'''
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'display-raster.cpp'
            executable = Path(temp) / 'display-raster'
            code = '\n'.join((shader_function(profiles, 'vec2 timing_profile_line_range('),
                              shader_function(fragment, 'float compute_row_shift_output_samples('), main))
            path.write_text(harness + code + checks, encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(path), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_profile_blanking_is_centered_in_presentation(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        beam = (ROOT / 'shaders' / 'beam.slang').read_text(encoding='utf-8')
        function = shader_function(beam, 'vec2 active_center_offset(')
        harness = r'''
#include <cmath>
#include <stdexcept>
struct vec2 {
    float x, y;
    vec2(float x, float y) : x(x), y(y) {}
};
''' + function + r'''
void check(float height, float width, float source_height, float factor, bool interlaced,
           float expected_x, float expected_y) {
    vec2 result = active_center_offset(1364, height, width, source_height, factor, 1, 88, interlaced);
    if (std::abs(result.x - expected_x) > 1e-6f || std::abs(result.y - expected_y) > 1e-6f)
        throw std::runtime_error("physical active area is not centered");
}
int main() {
    check(262, 256, 224, 4, false, 600.0f / 1364 - 0.5f, 113.0f / 262 - 0.5f);
    check(312, 512, 239, 2, false, 600.0f / 1364 - 0.5f, 120.5f / 312 - 0.5f);
    check(262.5f, 256, 448, 4, true, 600.0f / 1364 - 0.5f, 226.0f / 525 - 0.5f);
    check(312.5f, 512, 478, 2, true, 600.0f / 1364 - 0.5f, 241.0f / 625 - 0.5f);
}
'''
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'center.cpp'
            executable = Path(temp) / 'center-test'
            source.write_text(harness, encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_beam_uses_stable_interlaced_presentation_height(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        beam = (ROOT / 'shaders' / 'beam.slang').read_text(encoding='utf-8')
        profiles = (ROOT / 'shaders' / 'timing-profiles.inc').read_text(encoding='utf-8')
        vertex = beam.split('#pragma stage vertex', 1)[1].split('#pragma stage fragment', 1)[0]
        main = shader_function(vertex, 'void main()').replace('void main()', 'void render_vertex()', 1)
        harness = r'''
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
using std::floor; using std::max;
using uint = unsigned int;
float max(float x, double y) { return std::max(x,float(y)); }
struct vec2 {
    float x,y;
    vec2(float a=0,float b=0): x(a),y(b) {}
};
struct Size { float x,y; vec2 xy; };
struct { Size OriginalSize,SourceSize; float H_FREQ_MODE; } config;
struct { float OriginalFPS,FIELD_ODD; uint FrameCount; int MVP; } global;
int Position,gl_Position,profile_mode;
vec2 TexCoord,vTexCoord,ActiveCenterOffset;
float maskAR,OriginalFrameWidth,OriginalFrameHeight,OriginalFullFrameHeight;
float IsInterlaced,OutputFrameWidth,OutputFrameHeight;
#define TIMING_PROFILE_MODE profile_mode
#define V_FREQ_MODE timing_profile_v_mode(profile_mode, config.OriginalSize.y, 6)
#define V_FREQ timing_profile_v_freq(profile_mode, config.OriginalSize.y, global.FrameCount, global.FIELD_ODD, 262.5)
#define ASPECT 0.0
#define SC_FREQ_MODE 0.0
#define SC_FREQ 0.0
#define PIXEL_CLOCK_MODE 0.0
#define PIXEL_CLOCK 0.0
#define H_FREQ_MODE 0.0
#define H_FREQ 0.0
#define DSP_WORKING_FS 0.0
#define DSP_OUTPUT_FS 0.0
#define H_BLANK_FUZZ 0.0
float uintBitsToFloat(uint) { return std::numeric_limits<float>::quiet_NaN(); }
float contract_output_sample_rate(float,float,float,float,float,float,float,float,float) { return 1; }
float contract_display_frame_width(vec2,float,float,float,float,float,float,float,float) { return 341; }
float contract_output_frame_width(float,float,float,float,float,float,float,float,float) { return 1364; }
float contract_frame_height(vec2,float,float,float v,float,float,float,float,float,float) { return v; }
float contract_full_frame_height(vec2,float,float mode,float v,float,float,float,float,float,float) {
    return mode > 5.5f ? 2*v : v;
}
float contract_is_interlaced(vec2,float,float mode,float,float,float,float,float,float,float) {
    return mode > 5.5f;
}
float contract_clocks_per_line(float,float,float,float,float,float,float) { return 1364; }
float contract_clock_factor(float,float,float,float,float,float,float,float,float) { return 4; }
float timing_profile_top_blank_lines(int, float) { return 1; }
float timing_profile_left_blank_cycles(int, float) { return 88; }
'''
        checks = r'''
void check(int mode, float source_height, float field_height, float expected_full, float expected_output) {
    profile_mode=mode;
    config.OriginalSize={256,field_height,{256,field_height}};
    config.SourceSize={2048,source_height,{2048,source_height}};
    float first_offset=0;
    for (int reversed=0; reversed<2; ++reversed) {
        global.FIELD_ODD=float(reversed);
        for (uint frame=0; frame<2; ++frame) {
            global.FrameCount=frame;
            render_vertex();
            if (OriginalFullFrameHeight != expected_full || OutputFrameHeight != expected_output
                || OriginalFrameHeight != expected_full/2)
                throw std::runtime_error("interlaced presentation height changed");
            if (frame==0 && reversed==0) first_offset=ActiveCenterOffset.y;
            if (std::abs(ActiveCenterOffset.y-first_offset)>1e-6f)
                throw std::runtime_error("interlaced active center changed");
        }
    }
}
int main() {
    check(1,626,448,525,525);
    check(1,1049,478,525,525);
    check(3,1080,448,525,1050);
    check(2,626,478,625,625);
    check(2,1250,448,625,1250);
    check(0,626,448,525,525);
    profile_mode=1;
    config.OriginalSize={256,224,{256,224}};
    config.SourceSize={2048,626,{2048,626}};
    render_vertex();
    if (OriginalFrameHeight!=262 || OutputFrameHeight!=524 || IsInterlaced!=0)
        throw std::runtime_error("progressive presentation changed");
}
'''
        functions = '\n'.join((
            shader_function(profiles, 'float timing_profile_v_mode('),
            shader_function(profiles, 'float timing_profile_v_freq('),
            shader_function(profiles, 'float timing_profile_full_frame_height('),
            shader_function(vertex, 'vec2 active_center_offset('),
            main,
        ))
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'beam.cpp'
            executable = Path(temp) / 'beam-test'
            source.write_text(harness + functions + checks, encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_sd_outputs_fit_pal_mega_drive_at_16_mhz(self):
        width = pal_mega_drive_width(16.0e6)
        for pipeline, stage in (
                ('crt-rgb-sd.json', 'input'),
                ('crt-svideo-sd.json', 'filter'),
                ('crt-composite-sd.json', 'filter')):
            with self.subTest(pipeline=pipeline):
                settings = load_json('presetdata', 'pipelines', 'disp', pipeline)['options'][stage]
                self.assertEqual(settings['scale_type'][0], 'absolute')
                self.assertGreaterEqual(settings['scale'][0], width)

    def test_rgb_working_output_fits_pal_mega_drive_at_32_mhz(self):
        settings = load_json('presetdata', 'pipelines', 'sys', 'rgb.json')['options']['bandlimit']
        self.assertEqual(settings['scale_type'][0], 'absolute')
        self.assertGreaterEqual(settings['scale'][0], pal_mega_drive_width(32.0e6))


if __name__ == '__main__':
    unittest.main()
