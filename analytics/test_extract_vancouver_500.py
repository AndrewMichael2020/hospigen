import os
import subprocess
from pathlib import Path

import pytest


@pytest.mark.skipif(os.environ.get('RUN_SYNTHETHEA') != '1', reason='Long-running Synthea generation skipped (set RUN_SYNTHETHEA=1 to enable)')
def test_generate_500_vancouver():
    root = Path(__file__).resolve().parents[1]
    script = root / 'analytics' / 'extract_vancouver_500.py'
    assert script.exists(), f"Generator script missing: {script}"

    # Build jar if needed
    cmd = [str(script), '--total', '500', '--batch-size', '250', '--seed', '42', '--build-if-missing']
    subprocess.check_call(cmd, cwd=str(root))

    out_dir = root / 'analytics' / 'test_output'
    assert out_dir.exists(), "Output directory not found"
    files = list(out_dir.glob('patient_*.json'))
    assert len(files) >= 500, f"Expected >=500 patient files, found {len(files)}"

    summary = out_dir / 'vancouver_generation_summary.json'
    assert summary.exists()
