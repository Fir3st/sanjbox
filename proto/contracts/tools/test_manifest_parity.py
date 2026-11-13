#!/usr/bin/env python3
"""Compare complete reports against CURRENT B3 sources, without a package/runtime dependency.

Only the two checked-in synthetic examples and generated mutations are inputs. Both executables
are pure in-memory validators compiled into a newly owned temporary directory. No manifest path
is resolved, no probe/lifecycle/APFS code is compiled, and no B3 file is modified.
"""
import copy
import json
from pathlib import Path
import subprocess
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[3]
B3 = ROOT / 'spikes/s4-state/Sources/StateManifest'
H1 = ROOT / 'proto/contracts/Sources/SanjboxContracts'


def compile_oracle(directory, name, sources, document_type, validate):
    main = directory / (name + '.swift')
    main.write_text('''import Foundation
@main struct Oracle {
    static func main() throws {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let documents = try JSONDecoder().decode([''' + document_type + '''].self, from: input)
        let reports = documents.map { ''' + validate + ''' }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(reports))
    }
}
''')
    binary = directory / name
    subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path',
                    str(directory / 'module-cache'), *map(str, sources), str(main), '-o', str(binary)], check=True, timeout=90)
    return binary


def main():
    required = [B3 / (name + '.swift') for name in ['Manifest', 'Paths', 'Validation']]
    required += [ROOT / ('spikes/s4-state/examples/' + phase + '.state-manifest.json') for phase in ['mvp', 'f4']]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise SystemExit('B3 parity requires the complete repository checkout; missing: ' + ', '.join(missing))
    if shutil.which('swiftc') is None:
        raise SystemExit('B3 parity requires the Swift compiler (swiftc on PATH); no tests were skipped.')
    base = json.loads((ROOT / 'spikes/s4-state/examples/mvp.state-manifest.json').read_text())
    f4 = json.loads((ROOT / 'spikes/s4-state/examples/f4.state-manifest.json').read_text())
    cases = [('mvp', base, None), ('f4', f4, None)]

    def add(name, code, mutate):
        document = copy.deepcopy(base)
        mutate(document)
        cases.append((name, document, code))

    def field(path, values, code):
        for index, value in enumerate(values):
            def mutate(d, path=path, value=value):
                for part in path[:-1]:
                    d = d[part]
                d[path[-1]] = value
            add('.'.join(map(str, path)) + ':' + str(index), code, mutate)

    field(['schema'], ['v2'], 'design-only')
    field(['intent'], ['verified'], 'design-only')
    field(['phase'], ['future'], 'phase')
    field(['zone', 'id'], ['', 'ABC1', 'a-bc', 'longer'], 'zone-id')
    field(['zone', 'uid'], [0], 'zone-identity')
    field(['zone', 'gid'], [0], 'zone-identity')
    field(['hostAccess'], ['inherited'], 'host-access')
    field(['outsideWrites'], ['enforced'], 'outside-writes')
    for collection in ['containers', 'volumes', 'roots']:
        field([collection], [[], base[collection] * 65], 'collection-limit')
    field(['readOnlyInputs'], [base['readOnlyInputs'] * 33], 'collection-limit')
    for collection in ['containers', 'volumes', 'roots', 'readOnlyInputs']:
        field([collection, 0, 'id'], ['BAD', 'x' * 33], 'identifier')
        add('duplicate-' + collection, 'duplicate-id', lambda d, c=collection: d[c].append(copy.deepcopy(d[c][0])))
    for collection in ['containers', 'volumes']:
        field([collection, 0, 'declaredUUID'], ['bad', '00000000-0000-0000-0000-000000000000'], 'invalid-declared-uuid')
    def uuid_alias(d):
        d['containers'][0]['declaredUUID'] = 'abcdefab-1234-1234-1234-123456789abc'
        d['volumes'][0]['declaredUUID'] = 'ABCDEFAB-1234-1234-1234-123456789ABC'
    add('uuid-case-alias', 'uuid-alias', uuid_alias)
    field(['containers', 0, 'planningBudgetBytes'], [0], 'zero-container-budget')
    add('unused-container', 'unused-container', lambda d: d['containers'].append({'id': 'unused'}))
    field(['volumes', 0, 'containerID'], ['unknown'], 'container-reference')
    field(['volumes', 0, 'mountPoint'], ['/', '/Users', '/volumes', '/opt', '/opt/snj', '/Applications', '/Library',
        '/System', '/private', '/usr', '/tmp/test', '/VAR/test', '/etc/test', '/System/Volumes/Data/test',
        '/a//b', '/a/../b', '/a/./b', '/a/', '/a\\b', '/a\u0085b', '/' + 'a' * 1024], 'mount-path')
    for field_name in ['filesystem', 'ownership']:
        field(['volumes', 0, field_name], ['wrong'], 'filesystem-policy')
    field(['volumes', 0, 'quota', 'limitBytes'], [None, 0], 'quota-limit')
    field(['volumes', 0, 'quota', 'reserveBytes'], [2**64 - 1], 'reserve-exceeds-quota')
    field(['volumes', 0, 'quota', 'mode'], ['wrong', 'unbounded', 'unresolved'], 'quota-mode')
    add('unused-volume', 'unused-volume', lambda d: d['volumes'].append(dict(copy.deepcopy(d['volumes'][0]), id='unused', mountPoint='/Volumes/Unused')))
    field(['volumes', 0, 'mountPoint'], ['/opt/snj/t001', '/OPT/SNJ/T001/child'], 'mount-overlap')
    field(['roots', 0, 'role'], ['additional'], 'required-roles')
    field(['runtimePolicy'], ['declared-unverified'], 'runtime-mvp')
    field(['phase'], ['f4-design'], 'runtime-f4')
    field(['roots', 0, 'role'], ['wrong'], 'root-role')
    field(['roots', 0, 'ownerUID'], [0, 99], 'root-owner')
    field(['roots', 0, 'rollback'], ['excluded'], 'partial-rollback')
    field(['roots', 0, 'purpose'], ['', 'x' * 257], 'root-purpose')
    field(['roots', 0, 'volumeID'], ['unknown'], 'volume-reference')
    field(['roots', 0, 'relativePath'], ['/absolute', '../escape', 'a//b', 'a\\b', 'x\u0085y'], 'root-path')
    field(['roots', 0, 'relativePath'], ['x' * 1024], 'resolved-path-limit')
    prefix_index = next(i for i, r in enumerate(base['roots']) if r['role'] == 'prefix')
    field(['roots', prefix_index, 'relativePath'], ['child'], 'prefix-layout')
    home_index = next(i for i, r in enumerate(base['roots']) if r['role'] == 'home')
    project_index = next(i for i, r in enumerate(base['roots']) if r['role'] == 'project')
    field(['roots', project_index, 'relativePath'], ['HOME', 'home/child'], 'root-overlap')
    def unicode_overlap(d):
        d['roots'][home_index]['relativePath'] = 'caf\u00e9'
        d['roots'][project_index]['relativePath'] = 'cafe\u0301'
    add('unicode-root-alias', 'root-overlap', unicode_overlap)
    field(['rollback', 'unitID'], ['BAD'], 'restore-membership')
    field(['rollback', 'volumeIDs'], [[], ['state', 'state'], ['unknown'], ['state'] * 17], 'restore-membership')
    # Collection guard wins for >16 references.
    cases[-1] = (cases[-1][0], cases[-1][1], 'collection-limit')
    for key in ['strategy', 'quiescence', 'startPolicy']:
        field(['rollback', key], ['wrong'], 'restore-contract')
    field(['rollback', 'recoveryRequired'], [False], 'restore-contract')
    for key, values in [('directoryPath', ['/tmp/control', '/a/../control']), ('ownerUID', [base['zone']['uid']]),
                        ('directoryMode', ['0777']), ('rollback', ['included'])]:
        field(['hostControl', key], values, 'host-control')
    add('zone-root-cannot-own-control', 'host-control', lambda d: d['zone'].update(uid=0))
    for key in ['policyFile', 'recoveryFile']:
        field(['hostControl', key], ['', '.', '..', 'a/b', 'a\\b', 'x\u0085y', 'x' * 129], 'control-file')
    field(['hostControl', 'recoveryFile'], ['POLICY.JSON'], 'control-alias')
    field(['hostControl', 'directoryPath'], ['/Volumes/Sanjbox', base['volumes'][0]['mountPoint'] + '/control'], 'control-in-restore')
    field(['readOnlyInputs', 0, 'path'], ['/tmp/a', '/a/../b'], 'read-only-input')
    field(['readOnlyInputs', 0, 'purpose'], ['', 'x' * 257], 'read-only-input')
    field(['readOnlyInputs', 0, 'path'], [base['volumes'][0]['mountPoint'], base['hostControl']['directoryPath']], 'input-state-overlap')
    add('input-overlap', 'input-overlap', lambda d: d['readOnlyInputs'].append(dict(d['readOnlyInputs'][0], id='another')))
    def quotas(d, mode):
        d['volumes'][0]['quota'] = {'mode': mode, 'reserveBytes': 0}
    for mode in ['unbounded', 'unresolved']:
        add('quota-warning-' + mode, 'quota-unverified', lambda d, m=mode: quotas(d, m))
    field(['containers', 0, 'planningBudgetBytes'], [None], 'container-budget-unresolved')
    field(['containers', 0, 'planningBudgetBytes'], [1], 'quotas-oversubscribed')
    def budget(d):
        d['containers'][0]['planningBudgetBytes'] = 1
        d['volumes'][0]['quota']['reserveBytes'] = 2
    add('reserve-budget', 'reserves-exceed-budget', budget)
    for capacity in ['limitBytes', 'reserveBytes']:
        def overflow(d, capacity=capacity):
            for volume in d['volumes']:
                volume['quota'][capacity] = 2**64 - 1
        add(capacity + '-overflow', 'budget-overflow', overflow)
    # Exact full-width arithmetic, optional fields, and both accepted warning-bearing examples.
    for value in [2**53 + 1, 2**64 - 1]:
        def exact(d, value=value):
            d['containers'][0]['planningBudgetBytes'] = value
            d['volumes'][0]['quota']['limitBytes'] = value - 1
            d['volumes'][1]['quota']['limitBytes'] = 1
        add('exact-capacity-' + str(value), None, exact)

    with tempfile.TemporaryDirectory(prefix='sanjbox-h1-parity-', dir='/private/tmp') as temporary:
        directory = Path(temporary)
        b3 = compile_oracle(directory, 'B3Oracle', [B3 / (n + '.swift') for n in ['Manifest', 'Paths', 'Validation']],
                            'Manifest', 'Validator().validate($0)')
        h1 = compile_oracle(directory, 'H1Oracle', sorted(H1.glob('*.swift')),
                            'StateManifestDocument', 'StateManifestSchema.report($0)')
        inputs = json.dumps([d for _, d, _ in cases], ensure_ascii=False).encode()
        reports = [json.loads(subprocess.run([str(binary)], input=inputs, capture_output=True, check=True, timeout=30).stdout)
                   for binary in [b3, h1]]
        assert all(len(report) == len(cases) for report in reports), 'Oracle omitted a case report'
        observed_codes = set()
        for (name, _, expected), original, contract in zip(cases, *reports):
            assert original == contract, f'{name}: B3/H1 report drift\nB3={original}\nH1={contract}'
            codes = {finding['code'] for finding in contract['findings']}
            observed_codes |= codes
            assert expected is None or expected in codes, (name, expected, codes)
            assert contract['consistentDesign'] == (not any(f['severity'] == 'error' for f in contract['findings']))
            assert contract['deploymentReady'] is False and contract['acceptanceStatus'] == 'Neověřeno'
        # Pin all B3 semantic finding codes so deleted/missed rule coverage fails independently.
        expected_codes = set('''collection-limit design-only phase zone-id zone-identity host-access outside-writes
identifier duplicate-id invalid-declared-uuid uuid-alias zero-container-budget unused-container container-reference
mount-path filesystem-policy quota-limit reserve-exceeds-quota quota-mode quota-unverified unused-volume
mount-overlap required-roles runtime-mvp runtime-f4 root-role root-owner partial-rollback root-purpose
volume-reference root-path resolved-path-limit prefix-layout root-overlap restore-membership restore-contract
multi-volume-recovery host-control control-file control-alias control-in-restore read-only-input input-state-overlap
input-overlap budget-overflow reserves-exceed-budget quotas-oversubscribed container-budget-unresolved'''.split())
        assert observed_codes == expected_codes, (expected_codes - observed_codes, observed_codes - expected_codes)
        print(f'PASS: {len(cases)} synthetic cases; all {len(expected_codes)} B3 finding codes and complete reports match.')


if __name__ == '__main__':
    main()
