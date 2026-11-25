import json
import unittest
from pathlib import Path


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
