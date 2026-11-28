import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


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
        profiles = (ROOT / 'shaders' / 'timing-profiles.inc').read_text(encoding='utf-8')
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
vec2 vTexCoord; vec4 FragColor(0); int Source;
int mode; float field_odd, sync_type;
#define TIMING_PROFILE_MODE mode
#define FIELD_ODD field_odd
#define SYS_SYNC_TYPE sync_type
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
        profiles = (ROOT / 'shaders' / 'timing-profiles.inc').read_text(encoding='utf-8')
        state = re.search(r'struct SyncState\s*\{[^}]+\};', sync)
        if state is None:
            raise ValueError('Missing SyncState')
        shader_code = '\n'.join((
            state.group(),
            shader_function(profiles, 'float timing_profile_top_blank_lines('),
            shader_function(profiles, 'float timing_profile_left_blank_cycles('),
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

    def test_pipeline_levels_cover_full_allocation(self):
        root = ROOT / 'presetdata' / 'pipelines' / 'sys'
        pipelines = (
            'rgb.json', 'famicom-rgb.json', 'famicom-svideo.json',
            'rgb-yc.json', 'rgb-yc-composite.json',
            'rgb-component-yc.json', 'rgb-component-composite.json',
        )
        for name in pipelines:
            with self.subTest(pipeline=name):
                data = json.loads((root / name).read_text(encoding='utf-8'))
                pixel = data['shaders']['deltav'] == 'send-delta-pixel'
                width, height = (2048, 2048)
                self.assertEqual(
                    [key for key in data['shaders'] if key.startswith('mip')],
                    [f'mip{level}' for level in range(1, 9)],
                )
                self.assertEqual(
                    [key for key in data['options'] if key.startswith('mip')],
                    [f'mip{level}' for level in range(1, 9)],
                )
                for level in range(1, 9):
                    key = f'mip{level}'
                    self.assertEqual(data['shaders'][key], 'send-did-pixel' if pixel else 'send-did-dsp')
                    options = data['options'][key]
                    self.assertEqual(options['alias'], f'Mip{level}')
                    self.assertEqual(options['scale_type'], ['source', 'source'])
                    width = int(width * options['scale'][0])
                    height = int(height * options['scale'][1])
                    self.assertGreaterEqual(min(width, height), 1)
                    self.assertEqual(width * height, 4194304 >> level)
                self.assertEqual(width * height, 16384)
                noise = data['options']['noise-txrx']
                self.assertEqual(noise['scale_type'], ['absolute', 'absolute'])
                self.assertEqual(noise['scale'], [2048.0, 2048.0])

    def test_shader_against_domain_reference(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')

        dsp = (ROOT / 'shaders' / 'dsp.inc').read_text(encoding='utf-8')
        contract = (ROOT / 'shaders' / 'contract.inc').read_text(encoding='utf-8')
        profiles = (ROOT / 'shaders' / 'timing-profiles.inc').read_text(encoding='utf-8')
        producer = (ROOT / 'shaders' / 'send-did-common.slang').read_text(encoding='utf-8')
        consumer = (ROOT / 'shaders' / 'noise-txrx-common.slang').read_text(encoding='utf-8')
        fragment = producer.split('#pragma stage fragment', 1)[1]
        shader_code = '\n'.join((
            shader_function(profiles, 'float timing_profile_storage_length('),
            shader_function(profiles, 'vec2 timing_profile_raster_position('),
            shader_function(contract, 'float contract_pixel_packed_width('),
            shader_function(contract, 'bool contract_pixel_texture_fits('),
            shader_function(dsp, 'int pyramid_max_lod('),
            shader_function(dsp, 'vec4 sample_pyramid_signal('),
            shader_function(producer, 'SendDIDState compute_send_did_state()'),
            shader_function(fragment, 'void main()').replace('void main()', 'void render_sample()', 1),
            shader_function(consumer, 'vec4 sample_packed_delta_v('),
            shader_function(consumer, 'vec4 sample_delta_v_level('),
            shader_function(consumer, 'if (TXRX_NOISE_VIEW_MAG_DELTAV > 0.5)').replace(
                'if (TXRX_NOISE_VIEW_MAG_DELTAV > 0.5)',
                'void render_debug_view(int sample_index_i, float TXRX_NOISE_MAG_DELTAV_MIP_LOD, NoiseTxRxState vNoiseState)',
                1,
            ),
        ))
        harness = r'''
#include <algorithm>
#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <vector>
using std::ceil; using std::floor; using std::max; using std::min; using std::clamp; using std::round;
using std::sqrt; using std::log2; using std::exp2;
using uint = unsigned int;
float max(float x, double y) { return std::max(x,float(y)); }
float clamp(float x, double a, double b) { return std::clamp(x,float(a),float(b)); }
struct vec2 {
    float x, y;
    vec2(float a=0, float b=0): x(a), y(b) {}
};
vec2 operator*(vec2 a, vec2 b) { return {a.x*b.x, a.y*b.y}; }
struct vec4 {
    float x, y, z, w;
    vec4(float v=0) : x(v), y(v), z(v), w(v) {}
    vec4(float a, float b, float c, float d) : x(a), y(b), z(c), w(d) {}
};
vec4 operator+(vec4 a, vec4 b) { return {a.x+b.x,a.y+b.y,a.z+b.z,a.w+b.w}; }
vec4 operator-(vec4 a, vec4 b) { return {a.x-b.x,a.y-b.y,a.z-b.z,a.w-b.w}; }
vec4 operator*(float s, vec4 a) { return {s*a.x,s*a.y,s*a.z,s*a.w}; }
vec4 operator*(vec4 a, float s) { return s*a; }
vec4 mix(vec4 a, vec4 b, float f) { return (1-f)*a+f*b; }
struct ivec2 { int x,y; ivec2(int a,int b): x(a),y(b) {} };
struct Texture { int w, h; std::vector<vec4> pixels; };
using sampler2D = Texture*;
ivec2 textureSize(sampler2D t, int) { return {t->w,t->h}; }
vec4 texelFetch(sampler2D t, ivec2 p, int) {
    if (p.x < 0 || p.y < 0 || p.x >= t->w || p.y >= t->h)
        throw std::runtime_error("texture fetch out of bounds");
    return t->pixels[p.y*t->w+p.x];
}
struct Size { float x, y; vec2 xy; };
struct { Size OutputSize, OriginalSize, SendSourceSize, SourceSize; float OriginalFPS; } config;
struct { unsigned FrameCount; float FIELD_ODD; } global;
int profile_mode;
#define TIMING_PROFILE_MODE profile_mode
float uintBitsToFloat(uint) { return std::numeric_limits<float>::quiet_NaN(); }
struct SendDIDState { float frame_height, base_frame_width, input_span, output_frame_width, data_length, texture_fits; };
SendDIDState vSendDIDState;
struct NoiseTxRxState { float frame_width, frame_height, data_length, tau, storage_width, texture_fits, max_lod; };
sampler2D Source, DeltaV, Mip1, Mip2, Mip3, Mip4, Mip5, Mip6, Mip7;
vec2 vTexCoord; vec4 FragColor;
float mock_width, mock_height;
float TXRX_NOISE_INTERPOLATE_MIPS = 0;
template<typename... T> float contract_frame_height(T...) { return mock_height; }
template<typename... T> float contract_frame_width(T...) { return mock_width; }
template<typename... T> float contract_working_frame_width(T...) { return mock_width; }
float contract_data_length(float width, float height) { return width*height; }
#define V_FREQ_MODE 0
#define V_FREQ 0
#define SC_FREQ_MODE 0
#define SC_FREQ 0
#define PIXEL_CLOCK_MODE 0
#define PIXEL_CLOCK 0
#define H_FREQ_MODE 0
#define H_FREQ 0
#define DSP_WORKING_FS 0
#define OPTION_XTALK_SAMPLE_COUNT 9
'''
        checks = r'''
struct Point { int index; vec4 value; };
vec4 reference_sample(const std::vector<Point>& points, int index) {
    auto it = std::upper_bound(points.begin(), points.end(), index,
        [](int i, const Point& point) { return i < point.index; });
    if (it == points.begin()) return it->value;
    return (it - 1)->value;
}
vec4 reference_consumer_sample(const std::vector<Point>& points, int index,
                               int length, int raster_width, int span) {
    index = clamp(index, 0, length-1);
    int line_start = (index / raster_width) * raster_width;
    if (profile_mode==1 && index>=259*1364-4)
        line_start=((index+4)/raster_width)*raster_width-4;
    else if (profile_mode==2 && index>=18*1364)
        line_start=index<18*1364+4 ? 17*1364 :
            ((index-4)/raster_width)*raster_width+4;
    int aligned_index = line_start - line_start % span +
                        ((index - line_start) / span) * span;
    return reference_sample(points, aligned_index);
}
vec4 reference_interpolated_sample(const std::vector<Point>& points, int index) {
    auto next = std::upper_bound(points.begin(), points.end(), index,
        [](int i, const Point& point) { return i < point.index; });
    if (next == points.begin()) return next->value;
    if (next == points.end()) return points.back().value;
    auto previous = next - 1;
    float fraction = float(index - previous->index) / float(next->index - previous->index);
    return (1-fraction)*previous->value + fraction*next->value;
}
void check(vec4 actual, vec4 expected) {
    if (std::abs(actual.x-expected.x)>1e-5 || std::abs(actual.y-expected.y)>1e-5 ||
        std::abs(actual.z-expected.z)>1e-5 || std::abs(actual.w-expected.w)>1e-5)
        throw std::runtime_error("shader result differs from independent reference");
}
vec4 source_value(int index, int width) {
    int x = index % width;
    float value = float((x >= width/3) + (x >= 2*width/3));
    return vec4(value, -value, value*0.25f, value*0.5f);
}
void run_case(int length, int storage_width, int storage_height, int raster_width, int profile=0) {
    profile_mode=profile;
    config.OriginalSize.y=profile==2 ? 478 : 239;
    global.FrameCount=profile==2 ? 0 : 1;
    float height = float(length+(profile==1 ? 4 : profile==2 ? -4 : 0)) / raster_width;
    int data_width = int(contract_pixel_packed_width(float(length)));
    Texture level{storage_width, storage_height, std::vector<vec4>(storage_width*storage_height)};
    std::vector<Point> reference;
    for (int i=0; i<length; ++i) {
        vec4 value = source_value(i, raster_width);
        vec4 v = value - source_value(max(i-1,0), raster_width);
        reference.push_back({i,v});
        level.pixels[(i/data_width)*storage_width+i%data_width] = v;
    }
    mock_width = float(raster_width);
    mock_height = height;
    config.SendSourceSize.x = float(storage_width);
    config.SendSourceSize.y = float(storage_height);
    config.SendSourceSize.xy = {float(storage_width),float(storage_height)};
    int max_lod = pyramid_max_lod(length,9);
    NoiseTxRxState state{float(raster_width),height,float(length),0,float(data_width),1,float(max_lod)};
    std::vector<Texture> levels_data{level};
    std::vector<std::vector<Point>> references{reference};
    for (int k=1; k<=8; ++k) {
        int span = 1 << k;
        int out_width = level.w, out_height = level.h;
        if (out_width > out_height) out_width = max(out_width / 2,1);
        else out_height = max(out_height / 2,1);
        config.SourceSize.x = float(level.w);
        config.SourceSize.y = float(level.h);
        config.SourceSize.xy = {float(level.w),float(level.h)};
        config.OutputSize.x = float(out_width);
        config.OutputSize.y = float(out_height);
        config.OutputSize.xy = {float(out_width),float(out_height)};
        vSendDIDState = compute_send_did_state();
        if ((k <= max_lod && vSendDIDState.input_span != span/2) ||
            vSendDIDState.output_frame_width != out_width || vSendDIDState.texture_fits != 1)
            throw std::runtime_error("incorrect pyramid geometry");
        Source = &level;
        Texture output{out_width,out_height,std::vector<vec4>(out_width*out_height)};
        std::vector<Point> expected;
        for (int y=0; y<out_height; ++y) {
            for (int x=0; x<out_width; ++x) {
                vTexCoord = {(x+0.5f)/out_width,(y+0.5f)/out_height};
                render_sample();
                int index = (y*out_width+x)*span;
                vec4 result(0);
                if (k<=max_lod && index<length) {
                    result = 0.5f*(reference_sample(reference,index) +
                                   reference_sample(reference,index-span/2));
                    expected.push_back({index,result});
                }
                check(FragColor,result);
                output.pixels[y*out_width+x] = FragColor;
            }
        }
        level = std::move(output);
        if (k<=max_lod) reference = std::move(expected);
        levels_data.push_back(level);
        references.push_back(reference);
    }
    sampler2D* samplers[] = {&DeltaV,&Mip1,&Mip2,&Mip3,&Mip4,&Mip5,&Mip6,
        &Mip7,&Source};
    for (int k=0; k<=8; ++k) *samplers[k] = &levels_data[k];
    for (int k=0; k<=max_lod; ++k)
        for (int index=0; index<length; index+=max(length/113,1)) {
            check(sample_delta_v_level(index,k,state),
                reference_consumer_sample(references[k], index, length, raster_width, 1 << k));
        }
    for (int index : {0, raster_width/3-1, raster_width/3,
                      raster_width-1, raster_width, raster_width+1,
                      raster_width+raster_width/3-1, raster_width+raster_width/3,
                      2*raster_width+raster_width/3, 259*1364-5, 259*1364-4,
                      259*1364-3, 18*1364-1, 18*1364,
                      18*1364+3, 18*1364+4, length-1}) {
        if (index < 0 || index >= length) continue;
        for (float lod : {-1.0f, 0.0f, 0.5f, 1.0f, 3.5f, 8.0f, 10.0f}) {
            int effective_lod = int(floor(std::clamp(lod, 0.0f, float(max_lod))));
            vec4 expected = reference_consumer_sample(
                references[effective_lod], index, length, raster_width, 1 << effective_lod);
            render_debug_view(index, lod, state);
            check(FragColor, expected * float(exp2(effective_lod)));
        }
    }
#ifdef OPTION_DEBUG
    TXRX_NOISE_INTERPOLATE_MIPS = 1;
    for (int k=0; k<=max_lod; ++k)
        for (int index=0; index<length; index+=max(length/113,1))
            check(sample_delta_v_level(index,k,state),
                reference_interpolated_sample(references[k], index));
    for (int index : {0, raster_width-1, raster_width, raster_width+1, length-1}) {
        if (index < 0 || index >= length) continue;
        for (float lod : {0.0f, 1.0f, 3.5f, 8.0f}) {
            int effective_lod = int(floor(std::clamp(lod, 0.0f, float(max_lod))));
            render_debug_view(index, lod, state);
            check(FragColor, reference_interpolated_sample(references[effective_lod], index) *
                float(exp2(effective_lod)));
        }
    }
    TXRX_NOISE_INTERPOLATE_MIPS = 0;
#endif
}
int main() {
    Texture triangle{2,2,{vec4(0),vec4(4),vec4(0),vec4(4)}};
    NoiseTxRxState triangle_state{5,3,13,0,5,1,2};
    Mip2 = &triangle;
    check(sample_delta_v_level(-1,2,triangle_state),vec4(0));
    check(sample_delta_v_level(3,2,triangle_state),vec4(0));
    check(sample_delta_v_level(4,2,triangle_state),vec4(4));
    check(sample_delta_v_level(5,2,triangle_state),vec4(4));
    check(sample_delta_v_level(7,2,triangle_state),vec4(4));
    check(sample_delta_v_level(8,2,triangle_state),vec4(4));
    check(sample_delta_v_level(9,2,triangle_state),vec4(0));
    check(sample_delta_v_level(10,2,triangle_state),vec4(0));
    check(sample_delta_v_level(12,2,triangle_state),vec4(0));
    check(sample_delta_v_level(20,2,triangle_state),vec4(0));
#ifdef OPTION_DEBUG
    TXRX_NOISE_INTERPOLATE_MIPS = 1;
    check(sample_delta_v_level(-1,2,triangle_state),vec4(0));
    check(sample_delta_v_level(3,2,triangle_state),vec4(3));
    check(sample_delta_v_level(4,2,triangle_state),vec4(4));
    check(sample_delta_v_level(5,2,triangle_state),vec4(3));
    check(sample_delta_v_level(7,2,triangle_state),vec4(1));
    check(sample_delta_v_level(8,2,triangle_state),vec4(0));
    check(sample_delta_v_level(10,2,triangle_state),vec4(2));
    check(sample_delta_v_level(12,2,triangle_state),vec4(4));
    check(sample_delta_v_level(20,2,triangle_state),vec4(4));
    triangle_state.data_length = 12;
    check(sample_delta_v_level(11,2,triangle_state),vec4(0));
    Texture line_mip1{2048,1,std::vector<vec4>(2048)};
    Texture line_mip2{1024,1,std::vector<vec4>(1024)};
    Texture line_mip3{1024,1,std::vector<vec4>(1024)};
    line_mip1.pixels[682] = vec4(11);
    line_mip2.pixels[341] = vec4(22);
    line_mip3.pixels[170] = vec4(10);
    line_mip3.pixels[171] = vec4(30);
    Mip1 = &line_mip1; Mip2 = &line_mip2; Mip3 = &line_mip3;
    NoiseTxRxState line_state{1364,262,357386,0,1024,1,8};
    check(sample_delta_v_level(1364,1,line_state),vec4(11));
    check(sample_delta_v_level(1364,2,line_state),vec4(22));
    check(sample_delta_v_level(1364,3,line_state),vec4(20));
    TXRX_NOISE_INTERPOLATE_MIPS = 0;
#endif
    if (pyramid_max_lod(1,9)!=0 || pyramid_max_lod(2,9)!=1 ||
        pyramid_max_lod(3,9)!=2 || pyramid_max_lod(8,9)!=3 ||
        pyramid_max_lod(9,9)!=4 || pyramid_max_lod(127,9)!=7 ||
        pyramid_max_lod(128,9)!=7 || pyramid_max_lod(129,9)!=8 ||
        pyramid_max_lod(255,9)!=8 ||
        pyramid_max_lod(256,9)!=8 || pyramid_max_lod(257,9)!=8 ||
        pyramid_max_lod(4194304,9)!=8 || pyramid_max_lod(4194304,5)!=4 ||
        pyramid_max_lod(4194304,1)!=0)
        throw std::runtime_error("incorrect terminal level");
    for (int length=1; length<=513; ++length) {
        int span=1, terminal_lod=0;
        while (span<length && terminal_lod<8) {
            span *= 2;
            ++terminal_lod;
        }
        for (int count=1; count<=9; ++count)
            if (pyramid_max_lod(length,count)!=min(terminal_lod,count-1))
                throw std::runtime_error("incorrect LOD at length or quality boundary");
    }
    for (int length : {1,2,3,7,8,9,13,16,17})
        run_case(length,16,8,5);
    run_case(357386,2048,2048,1364);
    run_case(357364,2048,2048,1364,1);
    run_case(425572,2048,2048,1364,2);
    run_case(2097153,2048,2048,2048);
    std::cout << "pyramid and sampling checks passed\n";
}
'''
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'test.cpp'
            executable = Path(temp) / 'test'
            source.write_text(harness + shader_code + checks, encoding='utf-8')
            for domain in ('pixel', 'dsp'):
                for debug in (False, True):
                    flags = ['-DSEND_PIXEL_DOMAIN'] if domain == 'pixel' else []
                    if debug:
                        flags.append('-DOPTION_DEBUG')
                    with self.subTest(domain=domain, debug=debug):
                        subprocess.run([compiler, '-std=c++17', '-O2', *flags, str(source),
                                        '-o', str(executable)], check=True)
                        subprocess.run([str(executable)], check=True)

    def test_frame_shader_packed_raster_and_overflow(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')

        source = (ROOT / 'shaders' / 'frameh.slang').read_text(encoding='utf-8')
        profiles = (ROOT / 'shaders' / 'timing-profiles.inc').read_text(encoding='utf-8')
        fragment = source.split('#pragma stage fragment', 1)[1]
        shader_code = '\n'.join((
            shader_function(profiles, 'float timing_profile_top_blank_lines('),
            shader_function(profiles, 'float timing_profile_left_blank_cycles('),
            shader_function(profiles, 'vec2 timing_profile_raster_position('),
            shader_function(fragment, 'float current_field_parity()'),
            shader_function(fragment, 'bool sample_maps_to_active_time(').replace('out vec2', 'vec2&'),
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
vec4 FragColor;
float FrameWidth, FrameHeight, IsInterlaced, Field, ClocksPerLine, ClockFactor;
float PackedWidth, DataLength, TextureFits, field_odd;
int profile_mode;
#define TIMING_PROFILE_MODE profile_mode
#define FIELD_ODD field_odd
#define BLANKING_COLOR vec3(-1,-1,-1)
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
    config.FrameCount=profile == 2 ? uint(1-parity) : uint(parity);
    int delta=profile && parity && ((!interlaced && (profile==1 || profile==3)) ||
                                      (interlaced && profile==2)) ? (profile==2 ? 4 : -4) : 0;
    int special_line=profile==2 ? 18 : 259;
    PackedWidth=1024; DataLength=ceil(FrameWidth*height)+delta; TextureFits=1;
    config.SourceSize={float(source_width),float(source_height),vec2(1.0f/source_width,1.0f/source_height)};
    config.OutputSize={float(output_width),float(output_height),vec2()};
    int active_height=interlaced ? int(floor((source_height-parity+1)*0.5f)) : source_height;
    int top=profile ? 18 : int(floor((ceil(height)-active_height)*0.5f));
    float left=profile ? 252 : (width-source_width*factor)*0.5f;
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
        if (delta && index>=start && index<end) { line=special_line-1; clock=index-start; }
        else { int normal=index-(delta && index>=end ? delta : 0); line=normal/width; clock=normal%width; }
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
