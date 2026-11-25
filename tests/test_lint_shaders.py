import tempfile
import unittest
from pathlib import Path

from scripts.lint_shaders import LintIssue, check_unused_includes


class UnusedIncludeTests(unittest.TestCase):
    def lint_include(self, include_source):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            host_path = root / 'host.slang'
            include_path = root / 'unused.inc'
            include_path.write_text(include_source, encoding='utf-8')

            issues: list[LintIssue] = []
            check_unused_includes(host_path, ['#include "unused.inc"'], issues)
            return issues

    def test_unused_include_with_main_function_is_allowed(self):
        issues = self.lint_include(
            '#pragma parameter Unused "Unused" 0.0 0.0 1.0 0.1\n'
            'void main()\n'
            '{\n'
            '}\n'
        )

        self.assertEqual(issues, [])

    def test_unused_include_without_main_function_is_reported(self):
        issues = self.lint_include(
            '#pragma parameter Unused "Unused" 0.0 0.0 1.0 0.1\n'
            'void helper()\n'
            '{\n'
            '}\n'
        )

        self.assertEqual(len(issues), 1)
        self.assertIn('Unused include', issues[0].message)


if __name__ == '__main__':
    unittest.main()
