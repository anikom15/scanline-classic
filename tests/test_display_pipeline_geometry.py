import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_dyadic_pyramid import shader_function, timing_profile_source


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
    def test_working_resampler_packs_independently_of_raster_width(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        shader = (ROOT / 'shaders' / 'sys-bandlimit.inc').read_text(encoding='utf-8')
        fragment = shader.split('#pragma stage fragment', 1)[1]
        main = shader_function(fragment, 'void main()').replace('void main()', 'void render_sample()', 1)
        main = main.replace('    float input_data_limit =',
                            '    captured_floor = input_index_int; captured_fraction = frac_offset;\n'
                            '    float input_data_limit =')
        harness = r'''
#include <algorithm>
#include <cmath>
#include <stdexcept>
using std::ceil; using std::floor; using std::max; using std::pow; using std::clamp;
float max(float x,double y) { return std::max(x,float(y)); }
float clamp(float x,double a,double b) { return std::clamp(x,float(a),float(b)); }
struct vec2 { float x,y; vec2(float a=0,float b=0): x(a),y(b) {} };
vec2 operator*(vec2 a,vec2 b) { return {a.x*b.x,a.y*b.y}; }
struct ivec2 { int x,y; ivec2(int a,int b): x(a),y(b) {} };
struct vec4 {
    float r,g,b,a;
    vec4(float v=0): r(v),g(v),b(v),a(v) {}
    vec4(float x,float y,float z,float w): r(x),g(y),b(z),a(w) {}
    vec4& operator+=(vec4 v) { r+=v.r; g+=v.g; b+=v.b; a+=v.a; return *this; }
    vec4& operator/=(float v) { r/=v; g/=v; b/=v; a/=v; return *this; }
};
vec4 operator*(float s,vec4 v) { return vec4(s*v.r,s*v.g,s*v.b,s*v.a); }
struct Size { float x,y; vec2 xy; };
struct { Size OutputSize,SourceSize; } config;
struct { float Delta,taps; } pfilt;
struct { float sigma,t_limit,gain; } gfilt;
float InputPackedWidth,OutputPackedWidth,InputDataLength,OutputDataLength,InputTextureFits;
float OutputFrameWidth,OutputFrameHeight,InputFrameWidth,captured_floor,captured_fraction;
int profile_mode;
int Source; vec2 vTexCoord; vec4 FragColor;
#define OPTION_CRISPY
#define SYS_FILTER_TYPE 0.0
#define TIMING_PROFILE_MODE profile_mode
#define EPS 1.0e-6f
float gaussian(float,float) { return 1; }
vec4 texelFetch(int,ivec2 p,int) { return vec4(float(p.y*1024+p.x)); }
'''
        checks = r'''
void sample(int index,float expected) {
    int x=index%int(OutputPackedWidth), y=index/int(OutputPackedWidth);
    vTexCoord=vec2((x+0.5f)/2048,(y+0.5f)/2048);
    render_sample();
    if (FragColor.r!=expected) throw std::runtime_error("incorrect packed resampling");
}
int main() {
    config.OutputSize={2048,2048,{2048,2048}};
    config.SourceSize=config.OutputSize;
    InputPackedWidth=1024; InputDataLength=357364; InputTextureFits=1;
    InputFrameWidth=1364; OutputFrameWidth=1364; OutputDataLength=357364; OutputPackedWidth=1024;
    pfilt.Delta=1; pfilt.taps=1; gfilt.gain=1;
    sample(1023,1023); sample(1024,1024); sample(1364,1364);
    sample(357363,357363); sample(357364,0);
    vTexCoord=vec2((1024.5f)/2048,0.5f/2048);
    render_sample();
    if (FragColor.r!=0) throw std::runtime_error("storage padding is not blank");
    OutputFrameWidth=4092; OutputDataLength=1072092; OutputPackedWidth=2048; pfilt.Delta=3;
    sample(2047,682); sample(2048,683); sample(4092,1364);
    sample(1072091,357363); sample(1072092,0);
    profile_mode=4; InputFrameWidth=3413; OutputFrameWidth=2034; OutputDataLength=600000;
    InputDataLength=897487;
    double expected=260000.0*3413/2034;
    sample(260000,float(std::floor(expected+0.5)));
    if (captured_floor!=std::floor(expected) ||
        std::abs(captured_fraction-(expected-std::floor(expected)))>0.0001)
        throw std::runtime_error("working resampler lost the physical sample phase");
    InputTextureFits=0; render_sample();
    if (FragColor.r!=1 || FragColor.g!=0 || FragColor.b!=1)
        throw std::runtime_error("insufficient storage was not reported");
}
'''
        code = '\n'.join((
            shader_function(fragment, 'vec4 fetch_input_sample('),
            main,
        ))
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'working-resampler.cpp'
            executable = Path(temp) / 'working-resampler'
            source.write_text(harness + code + checks, encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_composite_modulator_uses_physical_line_not_storage_row(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        shader = (ROOT / 'shaders' / 'sys-component-yc-common.slang').read_text(encoding='utf-8')
        profiles = timing_profile_source()
        fragment = shader.split('#pragma stage fragment', 1)[1]
        harness = r'''
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
using std::ceil; using std::floor; using std::isnan; using std::isinf;
using uint = unsigned int;
struct vec2 { union { struct { float x,y; }; struct { float r,g; }; }; vec2(float a=0,float b=0): x(a),y(b) {} };
vec2 operator*(vec2 a,vec2 b) { return {a.x*b.x,a.y*b.y}; }
vec2 mix(vec2 a,vec2 b,float v) { return {(1-v)*a.x+v*b.x,(1-v)*a.y+v*b.y}; }
struct vec3 { float r,g,b; vec3(float a=0,float c=0,float d=0): r(a),g(c),b(d) {} };
struct vec4 {
    vec3 rgb; float a;
    vec4(float v=0): rgb(v,v,v),a(v) {}
    vec4(float r,float g,float b,float a): rgb(r,g,b),a(a) {}
    vec4(vec2 v,float b,float a): rgb(v.x,v.y,b),a(a) {}
};
struct Size { float x,y; vec2 xy; };
struct { Size OutputSize,OriginalSize; uint FrameCount; } config;
float FrameWidth,DataLength,StorageWidth,TextureFits,InitialSubcarrierPhaseFrac;
float Fs,Fsc,c_leakage,g_iq,p_iq,field_odd; int Source,profile_mode;
vec2 vTexCoord; vec4 FragColor;
#define SYS_COMPONENT_YC_MODE
#define SVIDEO 1.0
#define TIMING_PROFILE_MODE profile_mode
#define FIELD_ODD field_odd
float uintBitsToFloat(uint) { return std::numeric_limits<float>::quiet_NaN(); }
vec4 fetch_input_sample(int,vec2,float index,float width,float) {
    if (width!=1024) throw std::runtime_error("incorrect modulator input stride");
    return vec4(index,0,0,1);
}
vec2 modulate_sys_component_yc(vec3 component,float index,float line,float,float,float,float,float,float) {
    if (component.r!=index) throw std::runtime_error("incorrect modulator input index");
    return {index,line};
}
'''
        checks = r'''
void sample(int index,float line) {
    int x=index%1024,y=index/1024;
    vTexCoord=vec2((x+0.5f)/2048,(y+0.5f)/512);
    render_sample();
    if (FragColor.rgb.r!=index || FragColor.rgb.g!=line)
        throw std::runtime_error("modulator raster mapping differs");
}
int main() {
    config.OutputSize={2048,512,{2048,512}};
    config.OriginalSize={256,239,{256,239}};
    config.FrameCount=1; profile_mode=1; field_odd=0;
    FrameWidth=1364; DataLength=357364; StorageWidth=1024; TextureFits=1;
    sample(1023,0); sample(1024,0); sample(1363,0); sample(1364,1);
    sample(259*1364-5,258); sample(259*1364-4,259);
    sample(357363,261);
}
'''
        code = '\n'.join((
            shader_function(profiles, 'vec2 timing_profile_raster_position('),
            shader_function(fragment, 'void main()').replace('void main()', 'void render_sample()', 1),
        ))
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'composite-modulator.cpp'
            executable = Path(temp) / 'composite-modulator'
            source.write_text(harness + code + checks, encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_display_resampler_restores_physical_line_positions(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        profiles = timing_profile_source()
        contract = (ROOT / 'shaders' / 'contract.inc').read_text(encoding='utf-8')
        harness = r'''
#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
using std::ceil; using std::floor; using std::min; using std::max;
using std::sqrt; using std::log2; using std::exp2;
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
    vec4(float r,float g,float b,float d): rgb(r,g,b),a(d) {}
};
struct Size { float x,y; vec2 xy; };
struct { Size OutputSize, OriginalSize, SourceSize; } config;
struct { uint FrameCount; float FIELD_ODD; } global;
struct { float Delta, taps; } pfilt;
float OutputFrameHeight, InputDataLength, OutputDataLength, InputFrameWidth, OutputFrameWidth;
float InputPackedWidth, InputTextureFits;
float DeskewSampleRatio, LineCarryClocksOut, ClockFactorOut, BaseFrameWidthOut;
float captured_floor, captured_fraction;
vec2 vTexCoord; vec4 FragColor; int Source, profile_mode;
#define TIMING_PROFILE_MODE profile_mode
#define OPTION_DEBUG
#define OPTION_CRISPY
#define DISPLAY_RGB_FILTER_BYPASS 1.0
#define DESKEW_BYPASS 0.0
#define EPS 1.0e-6f
float uintBitsToFloat(uint) { return std::numeric_limits<float>::quiet_NaN(); }
float zoh_area(float,float,float) { return 1; }
vec4 fetch_input_sample(int,vec2,float index,float width,float) {
    if (width != 1024) throw std::runtime_error("incorrect packed input stride");
    return vec4(vec3(index),1);
}
'''
        checks = r'''
void sample(int x,int y,float expected,bool padding=false) {
    vTexCoord=vec2((x+0.5f)/2048,(y+0.5f)/512);
    render_sample();
    if (padding ? FragColor.a!=0 : (FragColor.a!=1 || FragColor.rgb.r!=expected)) {
        std::cerr << "at " << x << "," << y << " got " << FragColor.rgb.r << " expected " << expected << '\n';
        throw std::runtime_error("display row does not map to the physical stream");
    }
}
int main() {
    config.OutputSize={2048,512,{2048,512}};
    config.SourceSize={2048,512,{2048,512}};
    config.OriginalSize={256,239,{256,239}};
    profile_mode=1; global.FrameCount=1; global.FIELD_ODD=0;
    OutputFrameHeight=262; InputFrameWidth=1364; OutputFrameWidth=1364;
    BaseFrameWidthOut=1364;
    InputDataLength=OutputDataLength=357364; pfilt.Delta=1; pfilt.taps=1;
    InputPackedWidth=1024; InputTextureFits=1;
    ClockFactorOut=4; LineCarryClocksOut=0; DeskewSampleRatio=1;
    sample(1359,258,258*1364+1359);
    sample(1360,258,0,true);
    sample(0,259,259*1364-4);
    LineCarryClocksOut=3; DeskewSampleRatio=2;
    sample(0,259,259*1364-2);
    LineCarryClocksOut=0; DeskewSampleRatio=1;
    sample(1363,261,357363);
    OutputFrameWidth=2047; OutputDataLength=262*2047-6; pfilt.Delta=2047.0f/1364.0f;
    sample(0,259,float(std::floor(double(259*2047-6)*1364/2047+0.5)));
    sample(2041,258,0,true);
    profile_mode=2; global.FrameCount=0; config.OriginalSize.y=478;
    OutputFrameHeight=312; OutputFrameWidth=1364; InputFrameWidth=1364;
    InputDataLength=OutputDataLength=425572; pfilt.Delta=1;
    sample(1363,17,18*1364-1);
    sample(0,18,18*1364+4);
    sample(0,311,311*1364+4);
    sample(1363,311,312*1364+3);
    profile_mode=4; global.FrameCount=0; config.OriginalSize.y=240;
    BaseFrameWidthOut=3413;
    OutputFrameHeight=263; OutputFrameWidth=InputFrameWidth=2047;
    InputDataLength=OutputDataLength=std::ceil(897487.0*2047/3413);
    pfilt.Delta=1; LineCarryClocksOut=0;
    sample(2045,2,6138);
    sample(2046,2,6139);
    sample(0,3,6140);
    config.OriginalSize.y=480; InputFrameWidth=2047; OutputFrameWidth=1017;
    for (int frame : {0,1}) for (int line=0;line<(frame ? 262 : 263);++line) {
        global.FrameCount=frame;
        int clock_start=(line/2)*6825+(line%2)*3412;
        double expected=double(clock_start)*2047/3413;
        sample(0,line,float(std::floor(expected+0.5)));
        if (captured_floor!=std::floor(expected) ||
            std::abs(captured_fraction-(expected-std::floor(expected)))>0.0001)
            throw std::runtime_error("RGB horizontal sync phase mismatch");
    }
}
'''
        with tempfile.TemporaryDirectory() as temp:
            for name in ('display-rgb-filter', 'hd-rgb-filter'):
                with self.subTest(shader=name):
                    extension = 'inc' if name == 'display-rgb-filter' else 'slang'
                    source = (ROOT / 'shaders' / f'{name}.{extension}').read_text(encoding='utf-8')
                    fragment = source.split('#pragma stage fragment', 1)[1]
                    main = shader_function(fragment, 'void main()').replace('void main()', 'void render_sample()', 1)
                    main = main.split('    if (BW_MODE < 0.5)', 1)[0] + '    FragColor = vec4(color, 1.0);\n}\n'
                    main = main.replace('    vec3 color =',
                                        '    captured_floor = input_index_int; captured_fraction = frac_offset;\n'
                                        '    vec3 color =')
                    path = Path(temp) / 'display-raster.cpp'
                    executable = Path(temp) / 'display-raster'
                    code = '\n'.join((shader_function(contract, 'float contract_pixel_packed_width('),
                                      shader_function(contract, 'bool contract_pixel_texture_fits('),
                                      shader_function(contract, 'float contract_hsync_sample_offset('),
                                      shader_function(profiles, 'vec2 timing_profile_line_range('),
                                      shader_function(fragment, 'float compute_row_shift_output_samples('), main))
                    path.write_text(harness + code + checks, encoding='utf-8')
                    subprocess.run([compiler, '-std=c++17', '-O2', str(path), '-o', str(executable)], check=True)
                    subprocess.run([str(executable)], check=True)

    def test_svideo_filter_deskews_packed_input_in_presentation_rows(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        shader = (ROOT / 'shaders' / 'display-component-filter.inc').read_text(encoding='utf-8')
        profiles = timing_profile_source()
        contract = (ROOT / 'shaders' / 'contract.inc').read_text(encoding='utf-8')
        fragment = shader.split('#pragma stage fragment', 1)[1]
        main = shader_function(fragment, 'void main()').replace('void main()', 'void render_sample()', 1)
        main = main.split('    if (DISPLAY_COMPONENT_FILTER_BYPASS > 0.5)', 1)[0] + '#endif\n}\n'
        main = main.replace('    vec4 center_sample =',
                            '    captured_fraction = frac_offset; captured_floor = input_index_int;\n'
                            '    vec4 center_sample =')
        harness = r'''
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
using std::ceil; using std::floor; using std::min; using std::max;
using std::sqrt; using std::log2; using std::exp2;
using uint = unsigned int;
float max(float x,double y) { return std::max(x,float(y)); }
float clamp(float x,double a,float b) { return std::clamp(x,float(a),b); }
float mix(float a,float b,float v) { return a*(1-v)+b*v; }
struct vec2 { float x,y; vec2(float a=0,float b=0): x(a),y(b) {} };
vec2 operator*(vec2 a,vec2 b) { return {a.x*b.x,a.y*b.y}; }
struct vec4 {
    float r,g,b,a;
    vec4(float v=0): r(v),g(v),b(v),a(v) {}
    vec4(float x,float y,float z,float w): r(x),g(y),b(z),a(w) {}
};
struct Size { float x,y; vec2 xy; };
struct { Size OutputSize,SourceSize,OriginalSize; uint FrameCount; } config;
struct { float FIELD_ODD; } global;
struct { float Delta; } pfilt;
float OutputFrameHeight,InputDataLength,OutputDataLength,InputFrameWidth,OutputFrameWidth;
float InputPackedWidth,InputTextureFits;
float DeskewSampleRatio,LineCarryClocksOut,ClockFactorOut,BaseFrameWidthOut;
float deskew_bypass,captured_fraction,captured_floor; int profile_mode,Source; vec2 vTexCoord; vec4 FragColor;
#define TIMING_PROFILE_MODE profile_mode
#define OPTION_DEBUG
#define DISPLAY_COMPONENT_BYPASS 1.0
#define DESKEW_BYPASS deskew_bypass
#define EPS 1.0e-6f
float uintBitsToFloat(uint) { return std::numeric_limits<float>::quiet_NaN(); }
vec4 fetch_input_sample(int,vec2,float index,float width,float) {
    if (width!=1024) throw std::runtime_error("incorrect S-video input stride");
    return vec4(index,0,0,1);
}
'''
        checks = r'''
void sample(int x,int y,float expected,bool padding=false) {
    vTexCoord=vec2((x+0.5f)/2048,(y+0.5f)/512);
    render_sample();
    if (padding ? FragColor.a!=0 : (FragColor.a!=1 || FragColor.r!=expected))
        throw std::runtime_error("S-video presentation mapping differs");
}
int main() {
    config.OutputSize={2048,512,{2048,512}};
    config.SourceSize={2048,512,{2048,512}};
    config.OriginalSize={256,239,{256,239}};
    config.FrameCount=1; global.FIELD_ODD=0; profile_mode=1;
    InputFrameWidth=OutputFrameWidth=1364; OutputFrameHeight=262;
    BaseFrameWidthOut=1364;
    InputDataLength=OutputDataLength=357364; pfilt.Delta=1;
    InputPackedWidth=1024; InputTextureFits=1;
    ClockFactorOut=4; LineCarryClocksOut=3; DeskewSampleRatio=1.5f;
    sample(0,259,259*1364-2);
    if (captured_fraction!=0.5f) throw std::runtime_error("fractional deskew was lost");
    sample(1360,258,0,true);
    deskew_bypass=1;
    sample(0,259,259*1364-4);
    profile_mode=4; config.OriginalSize={640,480,{640,480}};
    InputFrameWidth=2047; OutputFrameWidth=1017; BaseFrameWidthOut=3413;
    OutputFrameHeight=263; InputDataLength=538239; OutputDataLength=267455;
    LineCarryClocksOut=0; deskew_bypass=0;
    for (int frame : {0,1}) for (int line=0;line<(frame ? 262 : 263);++line) {
        config.FrameCount=frame;
        int clock_start=(line/2)*6825+(line%2)*3412;
        double expected=double(clock_start)*2047/3413;
        sample(0,line,float(std::floor(expected+0.5)));
        if (captured_floor!=std::floor(expected) ||
            std::abs(captured_fraction-(expected-std::floor(expected)))>0.0001)
            throw std::runtime_error("PSX horizontal sync phase mismatch");
    }
    deskew_bypass=1;
    sample(0,1,2047);
    if (captured_fraction!=0) throw std::runtime_error("deskew bypass did not preserve stored boundary");
    deskew_bypass=0;
    for (int mode : {1,2,3,5}) for (int frame : {0,1}) {
        profile_mode=mode; config.FrameCount=frame; config.OriginalSize.y=mode==5 ? 576 : 478;
        BaseFrameWidthOut=mode==5 ? 3405 : 1364;
        OutputFrameHeight=mode==5 ? (frame==0 ? 312 : 313) : (mode==2 ? (frame==0 ? 312 : 313) : (frame==0 ? 263 : 262));
        InputDataLength=OutputDataLength=1000000;
        for (int line=0;line<int(OutputFrameHeight);++line) {
            int clock_start=line*int(BaseFrameWidthOut);
            if (mode==2 && frame==0 && line>=18) clock_start+=4;
            double expected=double(clock_start)*2047/BaseFrameWidthOut;
            sample(0,line,float(std::floor(expected+0.5)));
            if (captured_floor!=std::floor(expected) ||
                std::abs(captured_fraction-(expected-std::floor(expected)))>0.0001)
                throw std::runtime_error("profile horizontal sync phase mismatch");
        }
    }
    for (int mode : {1,3}) {
        profile_mode=mode; config.FrameCount=1; config.OriginalSize.y=239;
        BaseFrameWidthOut=1364;
        for (int line=258;line<262;++line) {
            int clock_start=line*1364-(line>=259 ? 4 : 0);
            double expected=double(clock_start)*2047/1364;
            sample(0,line,float(std::floor(expected+0.5)));
            if (captured_floor!=std::floor(expected) ||
                std::abs(captured_fraction-(expected-std::floor(expected)))>0.0001)
                throw std::runtime_error("shortened SFC line sync phase mismatch");
        }
    }
}
'''
        code = '\n'.join((
            shader_function(contract, 'float contract_pixel_packed_width('),
            shader_function(contract, 'bool contract_pixel_texture_fits('),
            shader_function(contract, 'float contract_hsync_sample_offset('),
            shader_function(profiles, 'vec2 timing_profile_line_range('),
            shader_function(fragment, 'float compute_row_shift_output_samples('),
            main,
        ))
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'svideo-deskew.cpp'
            executable = Path(temp) / 'svideo-deskew'
            source.write_text(harness + code + checks, encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_standalone_deskew_tracks_physical_hsync(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        shader = (ROOT / 'shaders' / 'deskew.slang').read_text(encoding='utf-8')
        profiles = timing_profile_source()
        contract = (ROOT / 'shaders' / 'contract.inc').read_text(encoding='utf-8')
        fragment = shader.split('#pragma stage fragment', 1)[1]
        harness = r'''
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
using std::ceil; using std::floor;
using uint = unsigned int;
struct vec2 {
    float x,y;
    vec2(float v=0): x(v),y(v) {}
    vec2(float x,float y): x(x),y(y) {}
};
vec2 operator+(vec2 a,vec2 b) { return {a.x+b.x,a.y+b.y}; }
vec2 operator*(vec2 a,vec2 b) { return {a.x*b.x,a.y*b.y}; }
struct vec3 { float x,y,z; vec3(float v=0):x(v),y(v),z(v) {} };
struct vec4 { vec3 rgb; };
struct Size { float x,y; vec2 zw; };
struct { Size OriginalSize,SourceSize; } config;
struct { uint FrameCount; float FIELD_ODD; } global;
float LineCarryClocksOut,ClockFactorOut,SampleRatio,BaseFrameWidthOut,deskew_bypass;
int profile_mode,Source;
#define TIMING_PROFILE_MODE profile_mode
#define DESKEW_BYPASS deskew_bypass
float mix(float a,float b,float t) { return a*(1-t)+b*t; }
float uintBitsToFloat(uint) { return std::numeric_limits<float>::quiet_NaN(); }
vec4 texture(int,vec2 uv) { return {vec3(uv.x*config.SourceSize.x-0.5f)}; }
'''
        checks = r'''
int main() {
    config.OriginalSize.y=480; config.SourceSize={2048,512,{1.0f/2048,1.0f/512}};
    profile_mode=4; BaseFrameWidthOut=3413; ClockFactorOut=4; SampleRatio=1;
    for (int line=0;line<263;++line) {
        int clocks=(line/2)*6825+(line%2)*3412;
        double exact=double(clocks)*1017/3413;
        double shift=exact-std::ceil(exact);
        float actual=sample_deskewed(100,line,1017).x;
        if (std::abs(actual-(100+shift))>0.0001)
            throw std::runtime_error("standalone physical sync shift mismatch");
    }
    deskew_bypass=1;
    if (sample_deskewed(100,1,1017).x!=100)
        throw std::runtime_error("standalone deskew bypass mismatch");
    deskew_bypass=0; profile_mode=0; LineCarryClocksOut=3;
    if (sample_deskewed(100,3,1017).x!=101)
        throw std::runtime_error("legacy deskew changed");
}
'''
        code = '\n'.join((
            shader_function(contract, 'float contract_hsync_sample_offset('),
            shader_function(profiles, 'vec2 timing_profile_line_range('),
            shader_function(fragment, 'vec3 sample_deskewed('),
        ))
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'standalone-deskew.cpp'
            executable = Path(temp) / 'standalone-deskew'
            source.write_text(harness + code + checks, encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(source), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_profile_blanking_is_centered_in_presentation(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        beam = (ROOT / 'shaders' / 'beam.inc').read_text(encoding='utf-8')
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
    vec2 result = active_center_offset(1364, height, width, source_height, factor, 18, 252, interlaced);
    if (std::abs(result.x - expected_x) > 1e-6f || std::abs(result.y - expected_y) > 1e-6f)
        throw std::runtime_error("physical active area is not centered");
}
int main() {
    check(262, 256, 224, 4, false, 764.0f / 1364 - 0.5f, 130.0f / 262 - 0.5f);
    check(312, 512, 239, 2, false, 764.0f / 1364 - 0.5f, 137.5f / 312 - 0.5f);
    check(262.5f, 256, 448, 4, true, 764.0f / 1364 - 0.5f, 260.0f / 525 - 0.5f);
    check(312.5f, 512, 478, 2, true, 764.0f / 1364 - 0.5f, 275.0f / 625 - 0.5f);
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
        beam = (ROOT / 'shaders' / 'beam.inc').read_text(encoding='utf-8')
        profiles = timing_profile_source()
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
double timing_profile_rate_width(int, double width, float) { return width; }
float contract_frame_height(vec2,float,float,float v,float,float,float,float,float,float) { return v; }
float contract_full_frame_height(vec2,float,float mode,float v,float,float,float,float,float,float) {
    return mode > 5.5f ? 2*v : v;
}
float contract_is_interlaced(vec2,float,float mode,float,float,float,float,float,float,float) {
    return mode > 5.5f;
}
float contract_clocks_per_line(float,float,float,float,float,float,float) { return 1364; }
float contract_clock_factor(float,float,float,float,float,float,float,float,float) { return 4; }
float timing_profile_top_blank_lines(int, float) { return 18; }
float timing_profile_left_blank_cycles(int, float) { return 252; }
float timing_profile_clock_factor(int, float, float legacy) { return legacy; }
float timing_profile_active_top(int, float, float legacy) { return legacy; }
float timing_profile_active_left(int, float, float, float, float legacy) { return legacy; }
float timing_profile_centered_overscan(int, float) { return 0; }
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
                self.assertEqual(settings['scale_type'], ['absolute', 'absolute'])
                self.assertEqual(settings['scale'][1], 512)
                self.assertGreaterEqual(settings['scale'][0], width)

    def test_rgb_working_output_fits_pal_mega_drive_at_32_mhz(self):
        settings = load_json('presetdata', 'pipelines', 'sys', 'rgb.json')['options']['bandlimit']
        samples = pal_mega_drive_width(32.0e6) * 313
        stride = 2 ** ((samples - 1).bit_length() // 2 + (samples - 1).bit_length() % 2)
        self.assertEqual(settings['scale_type'], ['absolute', 'absolute'])
        self.assertGreaterEqual(settings['scale'][0], stride)
        self.assertGreaterEqual(settings['scale'][1], (samples + stride - 1) // stride)


if __name__ == '__main__':
    unittest.main()
