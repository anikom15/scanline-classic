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
    def test_shader_against_row_aligned_reference(self):
        compiler = shutil.which('g++')
        if compiler is None:
            self.skipTest('g++ is required to exercise shader functions')

        dsp = (ROOT / 'shaders' / 'dsp.inc').read_text(encoding='utf-8')
        producer = (ROOT / 'shaders' / 'send-did-common.slang').read_text(encoding='utf-8')
        consumer = (ROOT / 'shaders' / 'noise-txrx-common.slang').read_text(encoding='utf-8')
        fragment = producer.split('#pragma stage fragment', 1)[1]
        shader_code = '\n'.join((
            shader_function(dsp, 'vec4 sample_row_aligned_signal('),
            shader_function(producer, 'SendDIDState compute_send_did_state()'),
            shader_function(fragment, 'void main()').replace('void main()', 'void render_sample()', 1),
            shader_function(consumer, 'vec4 sample_packed_delta_v('),
            shader_function(consumer, 'vec4 sample_delta_v_level('),
            shader_function(consumer, 'vec4 sample_delta_v_lod('),
        ))
        harness = r'''
#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <vector>
using std::ceil; using std::floor; using std::max; using std::min; using std::clamp; using std::round;
float max(float x, double y) { return std::max(x,float(y)); }
float clamp(float x, double a, double b) { return std::clamp(x,float(a),float(b)); }
struct vec2 { float x, y; };
vec2 operator*(vec2 a, vec2 b) { return {a.x*b.x, a.y*b.y}; }
struct vec4 {
    float x, y, z, w;
    vec4(float v=0) : x(v), y(v), z(v), w(v) {}
    vec4(float a, float b, float c, float d) : x(a), y(b), z(c), w(d) {}
};
vec4 operator+(vec4 a, vec4 b) { return {a.x+b.x,a.y+b.y,a.z+b.z,a.w+b.w}; }
vec4 operator*(float s, vec4 a) { return {s*a.x,s*a.y,s*a.z,s*a.w}; }
vec4 mix(vec4 a, vec4 b, float f) { return (1-f)*a+f*b; }
struct ivec2 { int x,y; ivec2(int a,int b): x(a),y(b) {} };
struct Texture { int w, h; std::vector<vec4> pixels; };
using sampler2D = Texture*;
vec4 texelFetch(sampler2D t, ivec2 p, int) {
    if (p.x < 0 || p.y < 0 || p.x >= t->w || p.y >= t->h)
        throw std::runtime_error("texture fetch out of bounds");
    return t->pixels[p.y*t->w+p.x];
}
struct Size { float x; vec2 xy; };
struct { Size OutputSize, OriginalSize, SendSourceSize, SourceSize; float OriginalFPS; } config;
struct SendDIDState { float frame_height, base_frame_width, input_span, output_frame_width, data_length; };
SendDIDState vSendDIDState;
struct NoiseTxRxState { float frame_width, frame_height, data_length, tau; };
sampler2D Source, DeltaV, Mip1, Mip2, Mip3, Mip4, Mip5, Mip6, Mip7, Mip8, Mip9, Mip10, Mip11;
vec2 vTexCoord; vec4 FragColor;
float mock_width, mock_height;
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
'''
        checks = r'''
struct Point { int index; vec4 value; };
vec4 reference_sample(const std::vector<Point>& points, int index) {
    auto it = std::lower_bound(points.begin(), points.end(), index,
        [](const Point& point, int i) { return point.index < i; });
    if (it == points.begin()) return it->value;
    if (it == points.end()) return points.back().value;
    if (it->index == index) return it->value;
    auto left = it - 1;
    return mix(left->value, it->value, float(index-left->index)/float(it->index-left->index));
}
void check(vec4 actual, vec4 expected) {
    if (std::abs(actual.x-expected.x)>1e-5 || std::abs(actual.y-expected.y)>1e-5 ||
        std::abs(actual.z-expected.z)>1e-5 || std::abs(actual.w-expected.w)>1e-5)
        throw std::runtime_error("shader result differs from independent reference");
}
void run_case(int width, int length, int storage, int levels, bool impulse) {
    int rows = (length+width-1)/width;
    float height = float(length)/width;
    Texture level{storage, rows, std::vector<vec4>(storage*rows)};
    std::vector<Point> reference;
    for (int i=0; i<length; ++i) {
        float value = impulse ? float(i%width == 400) : float((i*37)%29-14);
        vec4 v(value, -value, value*0.25f, 1.0f);
        reference.push_back({i,v});
        level.pixels[(i/width)*storage+i%width] = v;
    }
    NoiseTxRxState state{float(width),height,float(length),0};
    mock_width = float(width);
    mock_height = height;
    config.SendSourceSize.x = float(storage);
    std::vector<Texture> levels_data{level};
    std::vector<std::vector<Point>> references{reference};
    for (int k=1; k<=levels; ++k) {
        int span = 1 << k;
        int out_width = max(storage >> k, 1);
        int active_width = (width+span-1)/span;
        config.SourceSize.x = float(level.w);
        vSendDIDState = compute_send_did_state();
        if (vSendDIDState.input_span != span/2 || vSendDIDState.output_frame_width != active_width)
            throw std::runtime_error("incorrect pyramid stage geometry");
        config.OutputSize.xy = {float(out_width),float(rows)};
        Source = &level;
        Texture output{out_width,rows,std::vector<vec4>(out_width*rows)};
        std::vector<Point> expected;
        for (int y=0; y<rows; ++y) {
            for (int x=0; x<out_width; ++x) {
                vTexCoord = {(x+0.5f)/out_width,(y+0.5f)/rows};
                render_sample();
                int index = y*width+x*span;
                vec4 result(0);
                if (x<active_width && index<length) {
                    result = 0.5f*(reference_sample(reference,index) +
                                   reference_sample(reference,index-span/2));
                    expected.push_back({index,result});
                }
                check(FragColor,result);
                output.pixels[y*out_width+x] = FragColor;
            }
        }
        level = std::move(output);
        reference = std::move(expected);
        levels_data.push_back(level);
        references.push_back(reference);
        for (int index=-1; index<=length; ++index)
            check(sample_packed_delta_v(&level,index,k,state),reference_sample(reference,index));
        if (impulse && k>=3 && k<=5)
            for (int y=1; y<rows; ++y)
                for (int x=400; x<=400+span; ++x)
                    check(sample_packed_delta_v(&level,y*width+x,k,state),
                          sample_packed_delta_v(&level,x,k,state));
    }
    sampler2D* samplers[] = {&DeltaV,&Mip1,&Mip2,&Mip3,&Mip4,&Mip5,&Mip6,
                             &Mip7,&Mip8,&Mip9,&Mip10,&Mip11,&Source};
    int last_lod = min(levels,12);
    for (int k=0; k<=last_lod; ++k) *samplers[k] = &levels_data[k];
    for (int k=0; k<=last_lod; ++k) {
        for (int index=-1; index<=length; ++index) {
            check(sample_delta_v_lod(index,float(k),state),reference_sample(references[k],index));
            if (k<last_lod)
                check(sample_delta_v_lod(index,k+0.5f,state),
                      mix(reference_sample(references[k],index),
                          reference_sample(references[k+1],index),0.5f));
        }
    }
}
int main() {
    run_case(1364,1364*8,4096,12,true);
    run_case(5,13,16,5,false);
    run_case(6,16,16,5,false);
    run_case(1,4,16,5,false);
    std::cout << "row-aligned pyramid and sampling checks passed\n";
}
'''
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'test.cpp'
            executable = Path(temp) / 'test'
            source.write_text(harness + shader_code + checks, encoding='utf-8')
            for domain in ('pixel', 'dsp'):
                flags = ['-DSEND_PIXEL_DOMAIN'] if domain == 'pixel' else []
                with self.subTest(domain=domain):
                    subprocess.run([compiler, '-std=c++17', '-O2', *flags, str(source),
                                    '-o', str(executable)], check=True)
                    subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    unittest.main()
