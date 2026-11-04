#!/usr/bin/env python3
"""Offline S6 preparation. Never invokes brew, a shell, networking, or installs."""
import argparse
from collections import Counter
from datetime import datetime, timezone, timedelta
import gzip
import hashlib
import json
from pathlib import Path
import re
import sys

BASE = Path(__file__).resolve().parent
DATA = BASE / 'data'
NAME = re.compile(r'[a-z0-9][a-z0-9+_.@-]*\Z', re.ASCII)
SHA = re.compile(r'[0-9a-f]{64}\Z', re.ASCII)
PREFIX = '/opt/snj/t001'
STATUS = 'Neověřeno'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f'duplicate JSON key: {key}')
        result[key] = value
    return result


def decode(raw):
    return json.loads(raw, object_pairs_hook=unique_object,
                      parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)))


def read(path):
    path = Path(path)
    raw = path.read_bytes()
    return decode(gzip.decompress(raw) if path.suffix == '.gz' else raw)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def selection(analytics, size=200):
    require(analytics.get('category') == 'formula_install', 'expected install analytics')
    require(type(size) is int and size > 0, 'invalid selection size')
    totals, seen = Counter(), set()
    for item in analytics['items']:
        label = item['formula']
        require(isinstance(label, str) and label not in seen, 'duplicate/invalid analytics label')
        seen.add(label)
        parts = label.split(' ')
        name = parts[0]
        # Core unqualified canonical names only. Aggregate option variants, not taps.
        if not NAME.fullmatch(name):
            continue
        require(all(re.fullmatch(r'--[A-Za-z0-9_+@.=:/-]+', x) for x in parts[1:]),
                f'unsupported option label: {label}')
        count = item['count']
        require(isinstance(count, str) and re.fullmatch(r'(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)', count),
                'invalid analytics count')
        totals[name] += int(count.replace(',', ''))
    require(len(totals) >= size, 'not enough distinct core names')
    ordered = sorted(totals.items(), key=lambda item: (-item[1], item[0]))[:size]
    return {'schema': 'sanjbox.s6-selection.v1', 'kind': 'metadata-derived',
            'window': [analytics['start_date'], analytics['end_date']],
            'method': 'sum unqualified core name option variants; count descending, ASCII name tie-break',
            'formulae': [{'rank': i + 1, 'name': name, 'install_events': count}
                         for i, (name, count) in enumerate(ordered)]}


def pinned_inputs():
    lock = read(DATA / 'snapshot-lock.json')
    for name, expected in lock['files'].items():
        require(Path(name).name == name, 'bad snapshot filename')
        require(hashlib.sha256((DATA / name).read_bytes()).hexdigest() == expected,
                f'snapshot digest mismatch: {name}')
    raw = gzip.decompress((DATA / 'analytics-install-90d.json.gz').read_bytes())
    require(hashlib.sha256(raw).hexdigest() == read(DATA / 'analytics-source.json')['sha256'],
            'analytics raw digest mismatch')
    chosen = selection(decode(raw))
    require(chosen == read(DATA / 'top-200.json'), 'selection differs from pin')
    return chosen, read(DATA / 'formulae-selected.json.gz')


def sample(chosen):
    rows = chosen['formulae']
    require(len(rows) == 200, 'sample requires exactly 200 targets')
    seed = digest(chosen)
    picked = []
    for start in range(0, 200, 50):
        group = sorted(rows[start:start + 50], key=lambda r: hashlib.sha256(
            (seed + ':' + r['name']).encode()).hexdigest())[:5]
        picked.extend(r['name'] for r in sorted(group, key=lambda r: r['rank']))
    return picked


def absolute(path):
    require(isinstance(path, str) and path.startswith('/') and path != '/' and
            '\\' not in path and all(c not in path for c in '\n\r\t\0') and
            all(c not in ('', '.', '..') for c in path.split('/')[1:]), 'non-canonical absolute path')
    return path


def topology(manifest):
    """Narrow E1 adapter. Full schema validation remains B3's responsibility."""
    require(manifest.get('schema') == 'sanjbox.state-manifest.v1' and
            manifest.get('intent') == 'design-only', 'expected B3 design manifest')
    zone = manifest['zone']
    require(zone['id'] == 't001' and type(zone['uid']) is int and zone['uid'] > 0 and
            type(zone['gid']) is int and zone['gid'] > 0, 'expected t001 non-root identity')
    volumes = {v['id']: v for v in manifest['volumes']}
    require(len(volumes) == len(manifest['volumes']), 'duplicate volume')
    require(all(v['filesystem'] == 'apfs' and v['ownership'] == 'required' for v in volumes.values()),
            'APFS ownership declaration required')
    roots = {}
    for root in manifest['roots']:
        if root['role'] not in ('home', 'project', 'prefix', 'cache', 'tmp'):
            continue
        require(root['role'] not in roots and root['volumeID'] in volumes, 'duplicate/unknown root')
        require(root['ownerUID'] == zone['uid'] and root['rollback'] == 'whole-volume', 'root ownership/rollback')
        mount = absolute(volumes[root['volumeID']]['mountPoint'])
        rel = root['relativePath']
        require(isinstance(rel, str) and (rel == '.' or (not rel.startswith('/') and
                all(c not in ('', '.', '..') for c in rel.split('/')))), 'invalid relative root')
        roots[root['role']] = absolute(mount if rel == '.' else mount + '/' + rel)
    require(set(roots) == {'home', 'project', 'prefix', 'cache', 'tmp'}, 'missing required root')
    require(roots['prefix'] == PREFIX and len(PREFIX.encode()) == 13, 'wrong short prefix')
    paths = list(roots.values())
    require(all(not (a == b or a.startswith(b + '/') or b.startswith(a + '/'))
                for i, a in enumerate(paths) for b in paths[i + 1:]), 'overlapping roots')
    rb = manifest['rollback']
    require(len(rb['volumeIDs']) == len(set(rb['volumeIDs'])) and set(rb['volumeIDs']) == set(volumes),
            'restore unit must include every volume exactly once')
    require(rb['strategy'] == 'rebuild-writable-state-then-switch' and
            rb['quiescence'] == 'whole-uid-required' and rb['recoveryRequired'] is True and
            rb['startPolicy'] == 'deny-until-verified', 'unsafe rollback declaration')
    return roots


def artifacts(formula, tag):
    name = formula['name']
    stable = formula.get('bottle', {}).get('stable', {})
    files = stable.get('files', {})
    actual_tag = tag if tag in files else 'all' if 'all' in files else tag
    bottle = files.get(actual_tag)
    common = {'name': name, 'version': formula['versions']['stable'], 'revision': formula['revision']}
    result = []
    if bottle:
        result.append(dict(common, kind='bottle', tag=actual_tag, rebuild=stable.get('rebuild'),
                           url=bottle.get('url'), sha256=bottle.get('sha256'), cellar=bottle.get('cellar')))
    source = formula.get('urls', {}).get('stable')
    if source:
        result.append(dict(common, kind='source', tag=None, rebuild=None,
                           url=source.get('url'), sha256=source.get('checksum'), cellar=None))
    return result


def publication_inventory(formulae, tag):
    # No trusted artifact publish-time provider is implemented. Git/source/catalog dates
    # are deliberately ignored even if supplied, as are fetched_at and local receipt time.
    records = []
    for formula in formulae:
        for artifact in artifacts(formula, tag):
            records.append(dict(artifact, publication_time=None,
                                decision='refuse_unknown_publication',
                                evidence='official API snapshot has no artifact-bound publication time'))
    return records


def synthetic_cooldown(artifact, evidence, now, days):
    """Exercises a future evidence contract; never authorizes a real download."""
    require(type(days) is int and days >= 0, 'invalid cooldown days')
    if not evidence or evidence.get('kind') != 'synthetic-artifact-publication':
        return 'refuse_unknown_publication'
    keys = ('name', 'version', 'revision', 'kind', 'tag', 'rebuild', 'url', 'sha256')
    if (not set(keys).issubset(artifact) or not isinstance(evidence.get('artifact'), dict) or
            not set(keys).issubset(evidence['artifact']) or
            not SHA.fullmatch(str(artifact.get('sha256', ''))) or any(
                evidence['artifact'].get(k) != artifact.get(k) for k in keys)):
        return 'refuse_identity_mismatch'
    try:
        require(isinstance(evidence.get('published_at'), str), 'timestamp required')
        published = datetime.fromisoformat(evidence['published_at'].replace('Z', '+00:00'))
        require(published.tzinfo is not None and now.tzinfo is not None, 'timezone required')
    except (ValueError, KeyError, TypeError):
        return 'refuse_unknown_publication'
    if published > now:
        return 'refuse_future_publication'
    return 'eligible_synthetic_only' if published <= now - timedelta(days=days) else 'refuse_too_young'


def cask_candidate(cask, home):
    require(NAME.fullmatch(cask['token']) is not None, 'invalid cask token')
    install = []
    for artifact in cask['artifacts']:
        # uninstall/zap are recorded metadata, never executed by E1 cleanup.
        install.extend(k for k in artifact if k not in ('uninstall', 'zap', 'target'))
    app_artifacts = [a for a in cask['artifacts'] if 'app' in a]
    simple_apps = all(isinstance(a['app'], list) and len(a['app']) == 1 and
                      isinstance(a['app'][0], str) and
                      re.fullmatch(r'[A-Za-z0-9 _+.-]+\.app', a['app'][0]) and
                      a.get('target') == '/Applications/' + a['app'][0]
                      for a in app_artifacts)
    apps = [a['app'][0] for a in app_artifacts if isinstance(a['app'], list) and a['app']]
    app_only = bool(app_artifacts) and simple_apps and set(install) == {'app'} and not cask.get('disabled', False)
    return {'name': cask['token'], 'version': cask['version'], 'sha256': cask['sha256'],
            'url': cask['url'], 'appdir': home + '/Applications', 'apps': apps,
            'app_only_candidate': app_only,
            'decision': 'refuse_unknown_publication',
            'limitations': 'appdir changes app destination only; no proof of all writes or no elevation'}


def plan(chosen, formulae, manifest, tag):
    require(re.fullmatch(r'arm64_[a-z0-9_]+', tag), 'explicit Apple Silicon bottle tag required')
    roots = topology(manifest)
    names = [r['name'] for r in chosen['formulae']]
    by_name = {f['name']: f for f in formulae}
    require(len(by_name) == len(formulae) and set(by_name) == set(names), 'catalog/selection mismatch')
    require(all(f['tap'] == 'homebrew/core' and f['full_name'] == f['name'] for f in formulae),
            'canonical core formulae required')
    brew = PREFIX + '/bin/brew'
    environment = {'HOME': roots['home'], 'PATH': PREFIX + '/bin:/usr/bin:/bin:/usr/sbin:/sbin',
                   'TMPDIR': roots['tmp'] + '/', 'HOMEBREW_TEMP': roots['tmp'],
                   'HOMEBREW_CACHE': roots['cache'] + '/Homebrew',
                   'HOMEBREW_LOGS': roots['home'] + '/Library/Logs/Homebrew',
                   'HOMEBREW_NO_AUTO_UPDATE': '1', 'HOMEBREW_NO_INSTALL_CLEANUP': '1',
                   'HOMEBREW_NO_ANALYTICS': '1', 'HOMEBREW_NO_SUDO': '1'}
    commands = []
    for name in names:
        f = by_name[name]
        commands.append({'name': name, 'argv': [brew, 'install', '--formula', name],
                         'expected_version': f['versions']['stable'], 'revision': f['revision'],
                         'metadata_has_target_bottle': any(a['kind'] == 'bottle' for a in artifacts(f, tag)),
                         'disabled': f.get('disabled', False), 'deprecated': f.get('deprecated', False),
                         'status': 'proposal-only; cooldown unresolved; user approval required'})
    casks = [cask_candidate(read(DATA / ('cask-' + n + '.json')), roots['home'])
             for n in ('rectangle', 'itsycal')]
    bootstrap = next(x for x in read(DATA / 'source-contracts.json') if '/Homebrew/install/' in x['url'])
    installer_path = roots['home'] + '/s6-install-' + bootstrap['revision'] + '.sh'
    return {'schema': 'sanjbox.s6-plan.v1', 'kind': 'preparation-only', 'acceptance_status': STATUS,
            'executable': False, 'selection_sha256': digest(chosen), 'tag': tag, 'roots': roots,
            'manifest_sha256': digest(manifest), 'environment': environment,
            'bootstrap': bootstrap,
            'bootstrap_commands': [
                ['/usr/bin/curl', '--fail', '--location', '--proto', '=https', '--tlsv1.2',
                 '--output', installer_path, bootstrap['url']],
                ['/usr/bin/shasum', '-a', '256', installer_path],
                ['/usr/bin/env', 'HOMEBREW_NO_SUDO=1', 'HOMEBREW_NO_ANALYTICS=1',
                 '/bin/bash', installer_path, '--path=' + PREFIX]],
            'bootstrap_warning': 'User must compare SHA before execution; installer fetches current brew; record actual revision',
            'brew_revision_reference': read(DATA / 'brew-source.json')['revision'],
            'formula_commands': commands, 'test_sample': sample(chosen),
            'test_commands': [[brew, 'test', name] for name in sample(chosen)],
            'collection_commands': [[brew, 'info', '--json=v2', '--installed']],
            'casks': casks,
            'cask_commands': [[brew, 'install', '--cask', '--appdir=' + roots['home'] + '/Applications', c['name']]
                              for c in casks if c['app_only_candidate']],
            'publication': publication_inventory(formulae, tag),
            'blockers': ['S4/B4 topology and rollback not verified', 'artifact publication time unknown',
                         'dependencies/resources/redirects/caches need D5/S5 enforcement',
                         'lab credentials/session and host-prefix before/after evidence not collected']}


def formula_index(info):
    require(isinstance(info, dict) and isinstance(info.get('formulae'), list), 'expected brew info --json=v2')
    indexed = {}
    for formula in info['formulae']:
        name = formula['name']
        require(isinstance(name, str) and NAME.fullmatch(name) and name not in indexed, 'duplicate/invalid receipt name')
        require(isinstance(formula.get('installed'), list), 'missing installed array')
        indexed[name] = formula
    return indexed


def report(chosen, formulae, before, after, attempts, tests):
    names = [r['name'] for r in chosen['formulae']]
    known = {f['name']: f for f in formulae}
    pre, post = formula_index(before), formula_index(after)
    def results(rows, allowed):
        result = {}
        for row in rows:
            require(row['name'] in allowed and row['name'] not in result, 'duplicate/unplanned outcome')
            require(type(row['exit_code']) is int and 0 <= row['exit_code'] <= 255, 'invalid exit code')
            result[row['name']] = row['exit_code']
        return result
    attempted = results(attempts, set(names))
    sampled = sample(chosen)
    tested = results(tests, set(sampled))
    rows = []
    for name in names:
        code = attempted.get(name)
        record = post.get(name, {}).get('installed', [])
        status = 'unknown'
        if pre.get(name, {}).get('installed'):
            status = 'preexisting'
        elif code is None:
            status = 'unattempted'
        elif code != 0:
            status = 'failed'
        elif post.get(name, {}).get('tap') != 'homebrew/core' or post.get(name, {}).get('full_name') != name:
            status = 'origin_mismatch'
        elif len(record) != 1:
            status = 'missing_receipt' if not record else 'ambiguous_receipt'
        else:
            expected = known[name]['versions']['stable']
            revision = known[name]['revision']
            expected += ('_' + str(revision)) if revision else ''
            receipt = record[0]
            if receipt.get('version') != expected:
                status = 'version_drift'
            elif receipt.get('used_options') != []:
                status = 'options_or_missing_options'
            elif type(receipt.get('poured_from_bottle')) is bool:
                status = 'bottle' if receipt['poured_from_bottle'] else 'source'
        rows.append({'name': name, 'outcome': status, 'exit_code': code})
    counts = Counter(r['outcome'] for r in rows)
    classified = counts['bottle'] + counts['source']
    testrows = [{'name': n, 'outcome': 'missing' if n not in tested else
                 'passed' if tested[n] == 0 else 'failed', 'exit_code': tested.get(n)} for n in sampled]
    return {'schema': 'sanjbox.s6-report.v1', 'acceptance_status': STATUS,
            'kind': 'supplied-receipts-only; no independent oracle', 'cohort_total': len(names),
            'counts': dict(sorted(counts.items())), 'classified': classified,
            'bottle_fraction_of_classified': counts['bottle'] / classified if classified else None,
            'bottle_fraction_of_all_200': counts['bottle'] / len(names),
            'cohort_complete': classified == len(names), 'rows': rows,
            'test_sample': testrows, 'test_sample_all_passed': all(r['outcome'] == 'passed' for r in testrows),
            'other_installed_formulae': sorted(set(post) - set(names)),
            'unverified': ['credentials/session', 'artifact identity and publish time', 'host prefix unchanged',
                           'cask destinations and writes', 'no privileged operations', 'APFS and rollback']}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command', required=True)
    sub.add_parser('select', help='verify frozen inputs and print deterministic top 200')
    pp = sub.add_parser('plan', help='print proposal only; never execute')
    pp.add_argument('--manifest', type=Path, default=BASE.parent / 's4-state/examples/mvp.state-manifest.json')
    pp.add_argument('--tag', default='arm64_golden_gate')
    sub.add_parser('cooldown', help='inventory exact artifacts; unknown publication refuses')
    rp = sub.add_parser('report')
    for flag in ('before', 'after', 'attempts', 'tests'):
        rp.add_argument('--' + flag, type=Path, required=True)
    args = p.parse_args()
    chosen, formulae = pinned_inputs()
    if args.command == 'select':
        result = chosen
    elif args.command == 'plan':
        result = plan(chosen, formulae, read(args.manifest), args.tag)
    elif args.command == 'cooldown':
        result = {'kind': 'metadata-inspection-only', 'acceptance_status': STATUS,
                  'records': publication_inventory(formulae, 'arm64_golden_gate')}
    else:
        result = report(chosen, formulae, read(args.before), read(args.after), read(args.attempts), read(args.tests))
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError) as exc:
        print('S6 input refused: ' + str(exc), file=sys.stderr)
        sys.exit(2)
