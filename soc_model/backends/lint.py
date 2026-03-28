"""Lint backend — runs slang (sv-lang) on all generated RTL files.

Collects all .sv and .v files produced by the generation backends
and invokes slang to lint them, reporting any errors or warnings.
"""

import shutil
import subprocess
from pathlib import Path
from typing import List, Optional, Tuple


class SoCLintBackend:
    """Lints generated RTL using slang (sv-lang)."""

    def __init__(self, slang_bin: Optional[str] = None):
        self.slang_bin = slang_bin or shutil.which('slang') or 'slang'

    def collect_rtl_files(self, build_dir: Path) -> List[Path]:
        """Collect all generated .sv and .v files under the build directory."""
        build_dir = Path(build_dir)
        files = []
        for ext in ('*.sv', '*.v'):
            files.extend(sorted(build_dir.rglob(ext)))
        return files

    def lint(self, build_dir: Path, extra_args: Optional[List[str]] = None) -> Tuple[int, str, str]:
        """Run slang on all generated RTL files in build_dir.

        Returns (returncode, stdout, stderr).
        """
        build_dir = Path(build_dir)
        rtl_files = self.collect_rtl_files(build_dir)

        if not rtl_files:
            return (0, '', 'No RTL files found to lint.')

        cmd = [self.slang_bin]

        # Add any extra arguments (e.g. --top, -Wextra, include paths)
        if extra_args:
            cmd.extend(extra_args)

        # Add all RTL files
        cmd.extend(str(f) for f in rtl_files)

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=300,
            )
            return (result.returncode, result.stdout, result.stderr)
        except FileNotFoundError:
            return (-1, '', f"slang not found at '{self.slang_bin}'. Install from https://github.com/MikePopoloski/slang")
        except subprocess.TimeoutExpired:
            return (-1, '', 'slang timed out after 300 seconds.')

    def lint_and_report(self, build_dir: Path, extra_args: Optional[List[str]] = None) -> bool:
        """Run lint and print results. Returns True if lint passed (no errors)."""
        build_dir = Path(build_dir)
        rtl_files = self.collect_rtl_files(build_dir)

        print(f"  Found {len(rtl_files)} RTL file(s) to lint")
        for f in rtl_files:
            print(f"    {f.relative_to(build_dir)}")

        returncode, stdout, stderr = self.lint(build_dir, extra_args)

        if returncode == -1:
            # slang not found or timed out
            print(f"  WARNING: {stderr}")
            return False

        if stdout.strip():
            print(stdout)
        if stderr.strip():
            print(stderr)

        if returncode == 0:
            print("  Lint PASSED — no errors found.")
            return True
        else:
            print(f"  Lint FAILED — slang exited with code {returncode}.")
            return False
