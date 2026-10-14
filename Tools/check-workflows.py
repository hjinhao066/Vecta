#!/usr/bin/env python3
"""Local YAML/CI contract checks. Not a substitute for running on GitHub."""
from pathlib import Path
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    files = sorted((ROOT/'.github/workflows').glob('*.yml'))
    if {p.name for p in files} != {'macos.yml', 'release.yml'}:
        raise ValueError('Unexpected workflow closure')
    for path in files:
        # System Ruby/Psych is present on supported Mac / Actions images. Parse
        # YAML as data, never execute or interpolate it. YAML1.1 spells on=true.
        output = subprocess.check_output(['ruby', '-rjson', '-ryaml', '-e',
            'x=YAML.safe_load(File.read(ARGV[0]), permitted_classes: [], permitted_symbols: [], aliases: false); puts JSON.generate(x)', str(path)], text=True)
        spec = json.loads(output)
        triggers = spec.get('on', spec.get('true'))
        if not isinstance(triggers, dict) or not {'push', 'workflow_dispatch'}.issubset(triggers):
            raise ValueError('Missing release/manual trigger: '+path.name)
        if spec.get('permissions') != {'contents': 'read'}:
            raise ValueError('Workflow must not have publication permissions')
        for job in spec['jobs'].values():
            if job['runs-on'] not in {'macos-15', 'macos-26', 'ubuntu-24.04'}:
                raise ValueError('Unexpected/unpinned runner')
            for step in job['steps']:
                if 'uses' in step and not re.fullmatch(r'[\w.-]+/[\w./-]+@[0-9a-f]{40}', step['uses']):
                    raise ValueError('Action is not immutable-SHA pinned')
                text = step.get('run', '')
                if re.search(r'gh\s+release|git\s+push|curl.*--upload|spctl.*disable|xattr.*-d', text):
                    raise ValueError('Forbidden publication/security disabling command')
        if path.name == 'macos.yml':
            if triggers['push']['branches'] != ['main', 'develop'] or 'pull_request' not in triggers:
                raise ValueError('Missing required branch/PR triggers')
            if set(spec['jobs']) != {'source-security', 'model-free', 'full-build'}:
                raise ValueError('Fast/heavy/security gates must be separate')
            text = path.read_text()
            for required in ('actionlint', 'gitleaks', 'release.py check', 'swift test', 'release.py build', 'actions/cache@'):
                if required not in text:
                    raise ValueError('Missing mandatory CI gate: '+required)
        else:
            dispatch = triggers['workflow_dispatch']['inputs']
            if dispatch['upload_artifacts']['default'] is not False:
                raise ValueError('Artifact source upload must default OFF')
            job = spec['jobs']['prepare']
            if job['environment'] != 'release-preparation':
                raise ValueError('Owner approval environment missing')
            upload = next(s for s in job['steps'] if s.get('uses', '').startswith('actions/upload-artifact@'))
            if upload['if'] != "github.event_name == 'workflow_dispatch' && inputs.upload_artifacts":
                raise ValueError('Source upload is not explicitly opt-in')
    print('PASS two parsed workflows: PR/main/develop/tags/manual, immutable actions, fast/heavy/security gates, opt-in upload and no public publication. GitHub execution/environment settings are NOT TESTED.')


if __name__ == '__main__':
    main()
