#!/usr/bin/env python3
"""Exercise actual compiled native-app policies on isolated synthetic data only."""
from pathlib import Path
import argparse
import json
import os
import signal
import subprocess
import uuid

FLAGS = ('application-lifecycle', 'summary-options', 'reset-policy', 'export-eligibility', 'library-ownership',
         'performance-refresh', 'saved-detail-preparation', 'performance-state',
         'ai-result-events', 'confirmed-learning', 'language-restart-policy',
         'fast-transfer-availability', 'speaker-merge', 'sync-state', 'conference-policy', 'playback-keyboard', 'library-search', 'model-download-host', 'highlights', 'visual-composition')


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('app', type=Path)
    args = parser.parse_args()
    app = args.app.resolve(); binary = app/'Contents/MacOS/Vecta'
    if not (app/'Contents/Resources/DEVELOPMENT-ONLY.txt').is_file() or b'--verify-speaker-merge' not in binary.read_bytes():
        raise ValueError('Requires a development frontend fixture, never an installed/release app')
    if app.is_relative_to(Path('/Applications')):
        raise ValueError('Never launch an installed application for synthetic checks')
    results = []
    for flag in FLAGS:
        env = dict(os.environ, VECTA_TEST_LANGUAGE='ru', VECTA_VERIFICATION_PREFERENCES='Vecta.Verification.NativeChecks.'+uuid.uuid4().hex)
        process = subprocess.Popen([str(binary), '--verify-'+flag], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        try:
            output, _ = process.communicate(timeout=45)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                output, _ = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL); output, _ = process.communicate()
            raise RuntimeError('Native check timed out: '+flag)
        print(output.strip())
        if process.returncode != 0 or 'PASS' not in output:
            raise RuntimeError('Native executable regression: '+flag)
        results.append({'check': flag, 'status': 'PASS'})
    (app.parent/'native-checks.json').write_text(json.dumps({'syntheticOnly': True, 'ownerAudioRead': False, 'inference': False, 'physicalHardware': 'NOT TESTED', 'productionAppLaunched': False, 'checks': results}, indent=2)+'\n')
    print(f'PASS{len(FLAGS)} actual compiled native-app regressions; no models, owner library or device actions')


if __name__ == '__main__':
    main()
