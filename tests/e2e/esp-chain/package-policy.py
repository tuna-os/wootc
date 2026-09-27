"""Render the reviewed Debian package dependency plan into an offline QA policy."""
import copy
from pathlib import Path

PLAN = Path(__file__).resolve().parents[3]/'docs/experiments/evidence/2026-09-27-esp-orchestrator/authenticated-dependencies/authenticated-dependency-plan.json'


def build_policy(source, scratch_id):
    if not source.get('sourceDependencySetsResolved') or source.get('newPackagesAcquired') or not source.get('authenticatedMetadata'):
        raise ValueError('reviewed authenticated package dependency plan required')
    baseline = {row['Package']: {'version': row['Version'], 'architecture': row['Architecture']}
                for row in source['cloudInventoryPackages']}
    phases = {}; current = baseline
    for phase, generation in (('old', 'old9'), ('new', 'new')):
        selected = source['solverPlans'][generation]
        if selected['solverExit'] != 0:
            raise ValueError('package solver did not complete')
        after = copy.deepcopy(current)
        for name in selected['removals']: after.pop(name)
        packages = []
        for row in selected['installs']:
            packages.append({'name': Path(row['Filename']).name, 'package': row['Package'], 'version': row['Version'],
                             'architecture': row['Architecture'], 'sha256': row['SHA256']})
            after[row['Package']] = {'version': row['Version'], 'architecture': row['Architecture']}
        phases[phase] = {'packages': packages, 'beforeInventory': current, 'afterInventory': after,
                         'allowedRemovals': selected['removals']}
        current = after
    return {'schemaVersion': 1, 'manager': 'dpkg', 'scratchId': scratch_id, 'phases': phases,
            'scope': 'exclusive-classic-qa-root; no OS/firmware acceptance'}
