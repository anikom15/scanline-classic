import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.generate_timing_profiles import generate_source


ROOT = Path(__file__).resolve().parent.parent


def timing_profile_source():
    data = json.loads((ROOT / 'presetdata' / 'timing-profiles.json').read_text(encoding='utf-8'))
    return generate_source(data)


def shader_function(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


class DyadicPyramidTests(unittest.TestCase):
    def test_sync_tracks_exceptional_physical_line_boundaries(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        sync = (ROOT / 'shaders' / 'sys-sync.slang').read_text(encoding='utf-8')
        profiles = timing_profile_source()
        state = re.search(r'struct SyncState\s*\{[^}]+\};', sync)
        if state is None:
            raise ValueError('Missing SyncState')
        fragment = sync.split('#pragma stage fragment', 1)[1]
        shader_code = '\n'.join((
            state.group(),
            shader_function(profiles, 'vec2 timing_profile_raster_position('),
            shader_function(profiles, 'float timing_profile_horizontal_sync_cycles('),
            shader_function(profiles, 'float timing_profile_vertical_sync_lines('),
            shader_function(fragment, 'vec4 fetch_source_texel('),
            shader_function(fragment, 'void main()').replace('void main()', 'void render_sample()', 1),
        ))
        harness = r'''
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
using std::ceil; using std::floor; using std::max;
using uint = unsigned int;
float max(float x, double y) { return std::max(x,float(y)); }
struct vec2 {
    float x,y;
    vec2(float a=0,float b=0): x(a),y(b) {}
};
vec2 operator*(vec2 a,vec2 b) { return {a.x*b.x,a.y*b.y}; }
struct vec3 { float r,g,b; vec3(float a,float c,float d): r(a),g(c),b(d) {} };
struct vec4 {
    vec3 rgb; float a;
    vec4(float v): rgb(v,v,v),a(v) {}
    vec4(float a,float b,float c,float d): rgb(a,b,c),a(d) {}
    vec4(vec3 c,float d): rgb(c),a(d) {}
};
struct ivec2 { int x,y; ivec2(int a,int b): x(a),y(b) {} };
struct Size { float x,y; vec2 xy; };
struct { Size OriginalSize, OutputSize, SourceSize; uint FrameCount; } config;
vec2 vTexCoord, SyncDimensions; vec4 FragColor(0); int Source;
int mode; float field_odd, sync_type;
#define TIMING_PROFILE_MODE mode
#define FIELD_ODD field_odd
#define SYS_SYNC_TYPE sync_type
#define raster_position(pattern, span, index, width) timing_profile_raster_position(mode, config.OriginalSize.y, config.FrameCount, field_odd, index, width)
const float BLANKING_APPROX_FRACTION=0.07f;
float uintBitsToFloat(uint) { return std::numeric_limits<float>::quiet_NaN(); }
vec4 texelFetch(int, ivec2, int) { return vec4(0.1f,0.2f,0.3f,1); }
'''
        checks = r'''
int main() {
    config.OutputSize={1024,512,{1024,512}};
    config.SourceSize=config.OutputSize;
    vSyncState.base_frame_width=1364; vSyncState.frame_height=262;
    vSyncState.active_left_base=252; vSyncState.active_top=18;
    vSyncState.active_source_height=239; vSyncState.clock_factor=4;
    vSyncState.clocks_per_line=1364; vSyncState.packed_width=1024;
    vSyncState.texture_fits=1; mode=1; field_odd=0; config.FrameCount=1;
    config.OriginalSize={256,239,{256,239}};
    vSyncState.data_length=357364;
    auto sample = [](int index, float expected) {
        int x=index%1024, y=index/1024;
        SyncDimensions=vec2(timing_profile_horizontal_sync_cycles(mode, 0),
                            timing_profile_vertical_sync_lines(mode, 0));
        vTexCoord=vec2((x+0.5f)/1024,(y+0.5f)/512);
        render_sample();
        if (std::abs(FragColor.a-expected)>1e-5f)
            throw std::runtime_error("sync differs at physical line boundary");
    };
    for (int profile : {1,3}) {
        mode=profile;
        for (int line : {3,17,18,240,241,256,257,258,259,260,261}) {
            int start=line*1364-(line>258 ? 4 : 0);
            sample(start, -0.4f);
            sample(start+99, -0.4f);
            sample(start+100, 0.0f);
            sample(start+251, 0.0f);
            sample(start+252, 0.0f);
        }
        sample(2*1364+1363, -0.4f);
        sample(3*1364+100, 0.0f);
        sample(258*1364+1359, 0.0f);
        sample(259*1364-4, -0.4f);
    }
    sample(357364, 0.0f);
    sync_type=1;
    sample(18*1364+99, -1.4f);
    sample(18*1364+100, 0.0f);
    sync_type=2;
    int index=18*1364+99;
    vTexCoord=vec2((index%1024+0.5f)/1024,(index/1024+0.5f)/512);
    render_sample();
    if (std::abs(FragColor.rgb.g+0.2f)>1e-5f || FragColor.a!=0)
        throw std::runtime_error("sync on green mismatch");
    sync_type=0;
    mode=2; config.FrameCount=0; config.OriginalSize={256,478,{256,478}};
    vSyncState.frame_height=312; vSyncState.active_source_height=239;
    vSyncState.data_length=425572;
    sample(18*1364+3, 0.0f);
    sample(18*1364+4, -0.4f);
    sample(311*1364+4, -0.4f);
    sample(425571, 0.0f);
    sample(425572, 0.0f);
    for (int profile : {1,2,3}) {
        mode=profile;
        bool pal=profile==2;
        for (int parity : {0,1}) {
            config.FrameCount=pal ? 1-parity : parity;
            config.OriginalSize={256,478,{256,478}};
            vSyncState.frame_height=pal ? 313-parity : 263-parity;
            vSyncState.data_length=vSyncState.frame_height*1364+(pal && parity ? 4 : 0);
            sample(2*1364+1363, -0.4f);
            sample(3*1364+99, -0.4f);
            sample(3*1364+100, 0.0f);
            sample(18*1364+252, 0.0f);
        }
    }
    mode=0; config.OriginalSize={256,224,{256,224}};
    vSyncState.frame_height=262; vSyncState.active_top=19;
    vSyncState.active_left_base=170; vSyncState.active_source_height=224;
    vSyncState.data_length=262*1364;
    sample(3*1364+200, -0.4f);
    sample(19*1364+100, 0.0f);
    mode=4; config.FrameCount=0; config.OriginalSize={320,240,{320,240}};
    config.OutputSize={1024,1024,{1024,1024}}; config.SourceSize=config.OutputSize;
    vSyncState.base_frame_width=3413; vSyncState.frame_height=263;
    vSyncState.data_length=897487;
    auto psx_sample = [](int index, float expected) {
        int x=index%1024, y=index/1024;
        SyncDimensions=vec2(timing_profile_horizontal_sync_cycles(mode, 0),
                            timing_profile_vertical_sync_lines(mode, 0));
        vTexCoord=vec2((x+0.5f)/1024,(y+0.5f)/1024);
        render_sample();
        if (std::abs(FragColor.a-expected)>1e-5f)
            throw std::runtime_error("PSX sync mismatch");
    };
    psx_sample(3411, -0.4f);
    psx_sample(3412, -0.4f);
    psx_sample(3412+99, -0.4f);
    psx_sample(3412+100, 0.0f);
    psx_sample(6825, -0.4f);
    psx_sample(6825+100, 0.0f);
    psx_sample(897486, 0.0f);
    psx_sample(897487, 0.0f);
    mode=5; config.OriginalSize.y=576; config.FrameCount=0;
    config.OutputSize={1024,2048,{1024,2048}}; config.SourceSize=config.OutputSize;
    vSyncState.base_frame_width=3405; vSyncState.frame_height=312;
    vSyncState.data_length=1062360;
    auto pal_sample = [](int index, float expected) {
        int x=index%1024, y=index/1024;
        SyncDimensions=vec2(timing_profile_horizontal_sync_cycles(mode, 0),
                            timing_profile_vertical_sync_lines(mode, 0));
        vTexCoord=vec2((x+0.5f)/1024,(y+0.5f)/2048);
        render_sample();
        if (std::abs(FragColor.a-expected)>1e-5f)
            throw std::runtime_error("PSX PAL sync mismatch");
    };
    pal_sample(3404, -0.4f);
    pal_sample(3405+99, -0.4f);
    pal_sample(3405+100, 0.0f);
    pal_sample(1062360, 0.0f);
}
'''
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'sync-raster.cpp'
            executable = Path(temp) / 'sync-raster'
            path.write_text(harness + state.group() + '\nSyncState vSyncState;\n'
                            + shader_code[len(state.group()):] + checks, encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(path), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_sync_uses_profile_blanking_and_rejects_overflow(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')
        sync = (ROOT / 'shaders' / 'sys-sync.slang').read_text(encoding='utf-8')
        profiles = timing_profile_source()
        state = re.search(r'struct SyncState\s*\{[^}]+\};', sync)
        if state is None:
            raise ValueError('Missing SyncState')
        shader_code = '\n'.join((
            state.group(),
            shader_function(profiles, 'float timing_profile_top_blank_lines('),
            shader_function(profiles, 'float timing_profile_left_blank_cycles('),
            shader_function(profiles, 'float timing_profile_centered_overscan('),
            shader_function(profiles, 'float timing_profile_nominal_width('),
            shader_function(profiles, 'float timing_profile_clock_factor('),
            shader_function(profiles, 'float timing_profile_active_top('),
            shader_function(profiles, 'float timing_profile_active_left('),
            shader_function(profiles, 'float timing_profile_storage_length('),
            shader_function(sync, 'SyncState compute_sync_state()'),
        ))
        harness = r'''
#include <algorithm>
#include <cmath>
#include <limits>
using std::ceil; using std::floor; using std::max;
using uint = unsigned int;
float max(float x, double y) { return std::max(x,float(y)); }
struct vec2 { float x, y; };
struct Size { float x, y; vec2 xy; };
struct { Size OriginalSize, OutputSize, SourceSize; float OriginalFPS; unsigned FrameCount; } config;
int mode; float height, factor, parity; bool interlaced;
float uintBitsToFloat(unsigned int) { return std::numeric_limits<float>::quiet_NaN(); }
template<typename... T> float contract_frame_width(T...) { return 1364; }
template<typename... T> float contract_frame_height(T...) { return height; }
float contract_data_length(float width, float lines) { return width * lines; }
float contract_pixel_packed_width(float) { return 1024; }
bool contract_pixel_texture_fits(vec2, float, float) { return true; }
template<typename... T> float contract_clocks_per_line(T...) { return 1364; }
template<typename... T> float contract_clock_factor(T...) { return factor; }
template<typename... T> float contract_is_interlaced(T...) { return interlaced ? 1 : 0; }
template<typename... T> float contract_field_parity(T...) { return parity; }
float timing_profile_first_field_odd(int, float) { return 0; }
#define TIMING_PROFILE_MODE mode
#define V_FREQ_MODE 0
#define V_FREQ 0
#define SC_FREQ_MODE 0
#define SC_FREQ 0
#define PIXEL_CLOCK_MODE 0
#define PIXEL_CLOCK 0
#define H_FREQ_MODE 0
#define H_FREQ 0
#define H_BLANK_FUZZ 0
#define FIELD_ODD 0
'''
        checks = r'''
#include <stdexcept>
int main() {
    config.OriginalSize={256,224,{256,224}};
    height=262; factor=4; interlaced=false; parity=0; mode=1;
    SyncState s=compute_sync_state();
    if (s.active_top!=18 || s.active_left_base!=252 || s.texture_fits!=1)
        throw std::runtime_error("profile blanking mismatch");
    config.OriginalSize={512,478,{512,478}};
    height=262; factor=2; interlaced=true; parity=1;
    s=compute_sync_state();
    if (s.active_top!=18 || s.active_left_base!=252 || s.active_source_height!=239)
        throw std::runtime_error("interlaced profile blanking mismatch");
    config.OriginalSize={400,224,{400,224}};
    factor=4; interlaced=false;
    if (compute_sync_state().texture_fits!=0)
        throw std::runtime_error("oversized picture was not rejected");
    config.OriginalSize={256,224,{256,224}};
    height=224;
    if (compute_sync_state().texture_fits!=0)
        throw std::runtime_error("oversized field picture was not rejected");
    height=262;
    mode=0;
    s=compute_sync_state();
    if (s.active_top!=19 || s.active_left_base!=170)
        throw std::runtime_error("legacy centering changed");
}
'''
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'sync.cpp'
            executable = Path(temp) / 'sync-test'
            path.write_text(harness + shader_code + checks, encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(path), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)

    def test_noise_pipelines_read_the_send_source_directly(self):
        root = ROOT / 'presetdata' / 'pipelines' / 'sys'
        pipelines = (
            'rgb.json', 'rgb-vga.json', 'famicom-rgb.json', 'famicom-svideo.json',
            'rgb-yc.json', 'rgb-yc-composite.json',
            'rgb-component-yc.json', 'rgb-component-composite.json',
        )
        for name in pipelines:
            with self.subTest(pipeline=name):
                data = json.loads((root / name).read_text(encoding='utf-8'))
                pixel = name in ('rgb.json', 'rgb-vga.json', 'famicom-rgb.json')
                self.assertEqual(data['shaders']['noise-txrx'], 'noise-txrx-pixel' if pixel else 'noise-txrx-dsp')
                keys = list(data['shaders'])
                self.assertEqual(keys[keys.index('noise-txrx') - 1], 'amp')
                self.assertNotIn('amp', data['options'])
                self.assertNotIn('deltav', keys)
                self.assertFalse(any(key.startswith('mip') for key in keys))
                noise = data['options']['noise-txrx']
                self.assertEqual(noise['scale_type'], ['absolute', 'absolute'])
                self.assertEqual(noise['scale'], [2048.0, 2048.0] if pixel else [1024.0, 1024.0])

    def test_direct_causal_noise_stages(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')

        dsp = (ROOT / 'shaders' / 'dsp.inc').read_text(encoding='utf-8')
        consumer = (ROOT / 'shaders' / 'noise-txrx-common.slang').read_text(encoding='utf-8')
        fragment = consumer.split('#pragma stage fragment', 1)[1]
        main = shader_function(fragment, 'void main()').replace('void main()', 'void render_sample()', 1)
        main = main.split('    float feedback_gain =', 1)[0] + '    FragColor = mag_delta;\n}\n'
        fetch = shader_function(dsp, 'vec4 fetch_input_sample(').replace(
            '{', '{\n    if (sample_index > current_test_index) throw std::runtime_error("future sample read");', 1)
        harness = r'''
#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>
using std::ceil; using std::floor; using std::max; using std::min;
using std::exp2; using std::isnan; using std::isinf;
float clamp(float x, float a, float b) { return std::clamp(x,a,b); }
struct vec2 { float x,y; vec2(float a=0,float b=0): x(a),y(b) {} };
vec2 operator*(vec2 a,vec2 b) { return {a.x*b.x,a.y*b.y}; }
struct ivec2 { int x,y; ivec2(int a,int b): x(a),y(b) {} };
struct vec4 {
    float x,y,z,w;
    vec4(float a=0): x(a),y(a),z(a),w(a) {}
    vec4(float a,float b,float c,float d): x(a),y(b),z(c),w(d) {}
    vec4& operator+=(vec4 v) { x+=v.x; y+=v.y; z+=v.z; w+=v.w; return *this; }
};
vec4 operator-(vec4 a,vec4 b) { return {a.x-b.x,a.y-b.y,a.z-b.z,a.w-b.w}; }
vec4 operator+(vec4 a,vec4 b) { return {a.x+b.x,a.y+b.y,a.z+b.z,a.w+b.w}; }
vec4 operator/(vec4 a,float s) { return {a.x/s,a.y/s,a.z/s,a.w/s}; }
vec4 operator*(vec4 a,float s) { return {a.x*s,a.y*s,a.z*s,a.w*s}; }
vec4 mix(vec4 a,vec4 b,float f) { return a*(1-f)+b*f; }
vec4 abs(vec4 a) { return {std::abs(a.x),std::abs(a.y),std::abs(a.z),std::abs(a.w)}; }
struct Texture { int w,h; std::vector<vec4> pixels; };
using sampler2D = Texture*;
vec4 texelFetch(sampler2D t,ivec2 p,int) {
    if (p.x<0 || p.y<0 || p.x>=t->w || p.y>=t->h)
        throw std::runtime_error("texture fetch out of bounds");
    return t->pixels[p.y*t->w+p.x];
}
struct Size { float x,y; vec2 xy; };
struct { Size OutputSize,SourceSize; } config;
struct NoiseTxRxState { double frame_width; float data_length,storage_width,texture_fits,max_lod; } vNoiseState;
sampler2D Source;
vec2 vTexCoord; vec4 FragColor;
int current_test_index;
float debug_bypass,debug_view,debug_lod_value;
bool invalid_raster;
#define TXRX_NOISE_BYPASS debug_bypass
#define TXRX_NOISE_VIEW_MAG_DELTAV debug_view
#define TXRX_NOISE_MAG_DELTAV_MIP_LOD debug_lod_value
vec2 fake_raster_position(float index) {
    if (invalid_raster) return {std::numeric_limits<float>::quiet_NaN(),0};
    float start = index < 1364 ? 0 : index < 2727 ? 1364 : 2727;
    return {index-start,0};
}
#define raster_position(pattern, exceptions, index, width) fake_raster_position(index)
const int XTALK_SAMPLE_COUNT = OPTION_XTALK_SAMPLE_COUNT;
'''
        checks = r'''
void check(vec4 a,vec4 b) {
    if (std::abs(a.x-b.x)>1e-5 || std::abs(a.y-b.y)>1e-5 ||
        std::abs(a.z-b.z)>1e-5 || std::abs(a.w-b.w)>1e-5) {
        std::cerr << "at " << current_test_index << " debug " << debug_view << " lod " << debug_lod_value
                  << " got " << a.x << " expected " << b.x << '\n';
        throw std::runtime_error("causal stage result differs");
    }
}
vec4 value(int i) {
    return {float(i%23)*0.125f,-float(i%11)*0.25f,float(i%5)*0.5f,float(i%7)*0.125f};
}
vec4 stage(int i,int span) {
    i=max(i,0);
    return value(i)-value(max(i-span,0));
}
vec4 expected_stage(int i,int span) {
    int start=i<1364 ? 0 : i<2727 ? 1364 : 2727;
    int offset=(i-start)%span;
    int anchor=i-offset;
    return mix(stage(anchor-span,span),stage(anchor,span),float(offset)/span);
}
void sample(int i) {
    current_test_index = i;
    int x=i%8,y=i/8;
    vTexCoord=vec2((x+0.5f)/16,(y+0.5f)/512);
    render_sample();
}
int main() {
    Texture source{16,512,std::vector<vec4>(16*512)};
    Source=&source;
    config.OutputSize={16,512,{16,512}};
    config.SourceSize=config.OutputSize;
    if (dyadic_max_lod(4194304,21)!=20 || dyadic_max_lod(1048576,21)!=20 ||
        dyadic_max_lod(1025,21)!=11 || dyadic_max_lod(4194304,11)!=10 ||
        dyadic_max_lod(4194304,1)!=0)
        throw std::runtime_error("incorrect maximum quality limit");
    for (int length=1;length<=513;++length) {
        int span=1,lod=0;
        while (span<length && lod<20) { span*=2; ++lod; }
        for (int count=1;count<=21;++count)
            if (dyadic_max_lod(length,count)!=min(lod,count-1))
                throw std::runtime_error("incorrect quality limit");
    }
    for (int length : {1,13,2801}) {
        for (int i=0;i<length;++i) source.pixels[(i/8)*16+i%8]=value(i);
        vNoiseState={1364,float(length),8,1,float(dyadic_max_lod(length,XTALK_SAMPLE_COUNT))};
        for (int i=0;i<length;++i) {
            vec4 expected(0);
            for (int k=0;k<=int(vNoiseState.max_lod);++k)
                expected += abs(expected_stage(i,1<<k)) / float(k+1);
            sample(i);
            check(FragColor,expected);
        }
#ifdef OPTION_DEBUG
        debug_view=1;
        for (float lod : {-1.0f,0.0f,1.9f,3.0f,8.0f,20.0f}) {
            debug_lod_value=lod;
            int lod_i=int(floor(clamp(lod,0.0f,vNoiseState.max_lod)));
            int i=length-1, span=1<<lod_i;
            sample(i);
            check(FragColor,expected_stage(i,span));
        }
        debug_view=0; debug_bypass=1;
        sample(length-1);
        check(FragColor,value(length-1));
        debug_bypass=0;
#endif
    }
    vNoiseState.texture_fits=0;
    sample(0);
    check(FragColor,vec4(1,0,1,1));
    vNoiseState.texture_fits=1;
    current_test_index=0; vTexCoord=vec2(8.5f/16,0.5f/512);
    render_sample();
    check(FragColor,vec4(0));
    invalid_raster=true;
    sample(0);
    check(FragColor,vec4(1,0,1,1));
    Texture large{1024,1537,std::vector<vec4>(1024*1537)};
    large.pixels[0]=vec4(2);
    large.pixels[1048576]=vec4(18);
    Source=&large;
    config.SourceSize={1024,1537,{1024,1537}};
    vNoiseState={1024,1572865,1024,1,20};
    current_test_index=1572864;
    check(sample_delta_v_level(1572864,20,0,vNoiseState),vec4(8));
}
'''
        code = '\n'.join((shader_function(dsp, 'int dyadic_max_lod('), fetch,
                          shader_function(consumer, 'vec4 sample_noise_signal('),
                          shader_function(consumer, 'vec4 sample_delta_v_level('), main))
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'causal-noise.cpp'
            executable = Path(temp) / 'causal-noise'
            source.write_text(harness + code + checks, encoding='utf-8')
            for count in (1, 11, 21):
                for debug in (False, True):
                    flags = [f'-DOPTION_XTALK_SAMPLE_COUNT={count}']
                    if debug:
                        flags.append('-DOPTION_DEBUG')
                    with self.subTest(count=count, debug=debug):
                        subprocess.run([compiler, '-std=c++17', '-O2', *flags, str(source),
                                        '-o', str(executable)], check=True)
                        subprocess.run([str(executable)], check=True)

    def test_frame_shader_packed_raster_and_overflow(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')

        source = (ROOT / 'shaders' / 'frameh.slang').read_text(encoding='utf-8')
        data = json.loads((ROOT / 'presetdata' / 'timing-profiles.json').read_text(encoding='utf-8'))
        future_mode = data['profiles'][1]['modes'][1]
        future_mode['line_overrides'] = [
            {'scan': 'interlaced', 'field': 'odd', 'line': 18, 'clocks': 3409}
        ]
        future_mode['field_clocks']['interlaced']['odd'] += 4
        profiles = generate_source(data)
        fragment = source.split('#pragma stage fragment', 1)[1]
        shader_code = '\n'.join((
            shader_function(profiles, 'float timing_profile_top_blank_lines('),
            shader_function(profiles, 'float timing_profile_left_blank_cycles('),
            shader_function(profiles, 'float timing_profile_centered_overscan('),
            shader_function(profiles, 'float timing_profile_nominal_width('),
            shader_function(profiles, 'float timing_profile_active_top('),
            shader_function(profiles, 'float timing_profile_active_left('),
            shader_function(profiles, 'float timing_profile_active_left_tracks_line('),
            shader_function(profiles, 'vec2 timing_profile_line_range('),
            shader_function(profiles, 'vec2 timing_profile_raster_position('),
            shader_function(source, 'vec4 compute_active_placement()'),
            shader_function(fragment, 'float current_field_parity()'),
            shader_function(fragment, 'bool sample_maps_to_active_time(').replace('out vec2', 'vec2&')
                .replace('ActivePlacement.x', 'ActivePlacement.rgb.x')
                .replace('ActivePlacement.y', 'ActivePlacement.rgb.y')
                .replace('ActivePlacement.z', 'ActivePlacement.rgb.z')
                .replace('ActivePlacement.w', 'ActivePlacement.a'),
            shader_function(fragment, 'vec3 fetch_source_sample('),
            shader_function(fragment, 'vec3 sample_active_content('),
            shader_function(fragment, 'void main()').replace('void main()', 'void render_sample()', 1),
        ))
        harness = r'''
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
using std::ceil; using std::floor; using std::max;
using uint = unsigned int;
float max(float x, double y) { return std::max(x,float(y)); }
float mod(float a, float b) { return a-b*floor(a/b); }
struct vec2 {
    float x,y;
    vec2() : x(0),y(0) {}
    vec2(float v) : x(v),y(v) {}
    vec2(float a,float b) : x(a),y(b) {}
};
vec2 operator*(vec2 a,vec2 b) { return {a.x*b.x,a.y*b.y}; }
struct vec3 {
    float x,y,z;
    vec3(float a=0,float b=0,float c=0) : x(a),y(b),z(c) {}
};
struct vec4 {
    vec3 rgb;
    float a;
    vec4(float v=0) : rgb(v,v,v),a(v) {}
    vec4(float x,float y,float z,float w) : rgb(x,y,z),a(w) {}
    vec4(vec3 c,float w) : rgb(c),a(w) {}
};
struct Size { float x,y; vec2 zw; };
struct { Size SourceSize, OutputSize, OriginalSize; uint FrameCount; } config;
vec2 vTexCoord;
vec4 FragColor, ActivePlacement;
float FrameWidth, FrameHeight, IsInterlaced, Field, ClocksPerLine, ClockFactor;
float PackedWidth, DataLength, TextureFits, field_odd;
int profile_mode;
#define TIMING_PROFILE_MODE profile_mode
#define FIELD_ODD field_odd
#define BLANKING_COLOR vec3(-1,-1,-1)
#define raster_position(pattern, span, index, width) timing_profile_raster_position(profile_mode, config.OriginalSize.y, config.FrameCount, field_odd, index, width)
#define raster_line_range(pattern, span, line, width) timing_profile_line_range(profile_mode, config.OriginalSize.y, config.FrameCount, field_odd, line, width)
float uintBitsToFloat(unsigned int) { return std::numeric_limits<float>::quiet_NaN(); }
int Source;
vec4 texture(int,vec2 uv) {
    return vec4(floor(uv.x*config.SourceSize.x),floor(uv.y*config.SourceSize.y),1,1);
}
'''
        checks = r'''
void run_case(float height, bool interlaced, float parity, int output_width, int output_height,
              int profile, int width, int source_width, int source_height, int factor) {
    profile_mode=profile;
    FrameWidth=float(width); FrameHeight=height; ClocksPerLine=float(width); ClockFactor=float(factor);
    IsInterlaced=interlaced ? 1 : 0; Field=parity; field_odd=0;
    config.OriginalSize.y=float(source_height);
    config.FrameCount=(profile == 2 || profile == 5) ? uint(1-parity) : uint(parity);
    int delta=profile && parity && ((profile<=3 && ((!interlaced && (profile==1 || profile==3)) ||
                                      (interlaced && profile==2))) || (profile==5 && interlaced))
        ? (profile==2 || profile==5 ? 4 : -4) : 0;
    int special_line=profile==2 || profile==5 ? 18 : 259;
    PackedWidth=1024;
    DataLength=profile==4 ? int(height)/2*6825+(int(height)%2)*3412 : ceil(FrameWidth*height)+delta;
    TextureFits=1;
    config.SourceSize={float(source_width),float(source_height),vec2(1.0f/source_width,1.0f/source_height)};
    config.OutputSize={float(output_width),float(output_height),vec2()};
    int active_height=interlaced ? int(floor((source_height-parity+1)*0.5f)) : source_height;
    int top=profile>=4 ? 12+int(floor(((profile==4 ? 240 : 288)-active_height)*0.5f))
                       : profile ? 18 : int(floor((ceil(height)-active_height)*0.5f));
    int nominal=source_width>=640 ? 640 : source_width>=512 ? 512 : source_width>=368 ? 368
                                 : source_width>=320 ? 320 : 256;
    ActivePlacement=compute_active_placement();
    if (ActivePlacement.rgb.y!=top || ActivePlacement.rgb.z!=active_height ||
        ActivePlacement.a!=(profile==5 ? 1 : 0))
        throw std::runtime_error("vertex active placement differs from reference");
    for (int y=0;y<output_height;++y) for (int x=0;x<output_width;++x) {
        vTexCoord=vec2((x+0.5f)/output_width,(y+0.5f)/output_height);
        render_sample();
        int index=y*1024+x;
        if (x>=1024 || index>=int(DataLength)) {
            if (FragColor.a != 0) throw std::runtime_error("padding not cleared");
            continue;
        }
        int line, clock;
        int start=(special_line-1)*width, end=special_line*width+delta;
        if (profile==4) {
            int pair=index/6825, within=index%6825;
            line=pair*2+(within>=3412);
            clock=within-(within>=3412 ? 3412 : 0);
        }
        else if (delta && index>=start && index<end) { line=special_line-1; clock=index-start; }
        else { int normal=index-(delta && index>=end ? delta : 0); line=normal/width; clock=normal%width; }
        float left=profile>=4 ? (profile==4 ? 3412 : width+(delta && line==special_line-1 ? delta : 0))-100
                                    -(nominal+(source_width-nominal)*0.5f)*factor
                              : profile ? 252 : (width-source_width*factor)*0.5f;
        float sx=(clock-left-(profile ? 0 : (line*(width%factor))%factor))/factor;
        bool active=line>=top && line<top+active_height && sx>=0 && sx<source_width;
        float expected_x=active ? floor(sx) : -1;
        float expected_y=active ? (interlaced ? (line-top)*2+parity : line-top) : -1;
        if (FragColor.rgb.x!=expected_x || FragColor.rgb.y!=expected_y || FragColor.a!=1)
            throw std::runtime_error("packed raster differs from reference");
    }
    TextureFits=0;
    vTexCoord=vec2(0.5f/output_width,0.5f/output_height);
    render_sample();
    if (FragColor.rgb.x!=1 || FragColor.rgb.y!=0 || FragColor.rgb.z!=1 || FragColor.a!=1)
        throw std::runtime_error("missing overflow color");
}
int main() {
    run_case(262,false,0,2048,512,0,1365,256,200,4);
    run_case(262.5f,true,1,1024,512,0,1365,256,200,4);
    run_case(263,true,0,1024,512,1,1364,256,448,4);
    run_case(262,true,1,1024,512,1,1364,512,478,2);
    run_case(312,false,0,1024,512,2,1364,256,239,4);
    run_case(262,false,0,1024,512,3,1364,256,224,4);
    run_case(262,false,1,1024,512,1,1364,256,239,4);
    run_case(262,false,1,1024,512,3,1364,512,239,2);
    run_case(312,true,1,1024,512,2,1364,256,478,4);
    run_case(263,false,0,1024,1024,4,3413,256,240,10);
    run_case(263,false,1,1024,1024,4,3413,352,256,8);
    run_case(262,true,1,1024,1024,4,3413,368,480,7);
    run_case(263,true,0,1024,1024,4,3413,512,480,5);
    run_case(263,true,0,1024,1024,4,3413,640,480,4);
    run_case(262,true,1,1024,1024,4,3413,640,480,4);
    run_case(314,false,1,1024,2048,5,3405,640,320,4);
    run_case(312,true,1,1024,2048,5,3405,320,576,8);
    run_case(313,true,0,1024,2048,5,3405,368,576,7);
}
'''
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'frame.cpp'
            executable = Path(temp) / 'frame-test'
            path.write_text(harness + shader_code + checks, encoding='utf-8')
            subprocess.run([compiler, '-std=c++17', '-O2', str(path), '-o', str(executable)], check=True)
            subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    unittest.main()
