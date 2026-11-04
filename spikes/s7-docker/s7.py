#!/usr/bin/env python3
"""Bounded offline S7 design validator/planner and SYNTHETIC oracles; no runtime I/O."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import struct
import sys

BASE = Path(__file__).resolve().parent
STATUS = 'Neověřeno'
MAX_INPUT = 262144
ZONES = ('t001', 't002', 't003')
SHA = re.compile(r'[0-9a-f]{64}\Z')
CHANNELS = ['ipv4-tcp', 'ipv4-udp', 'ipv6-tcp', 'ipv6-udp', 'dns', 'mdns', 'quic', 'icmp']


def require(condition, message):
    if not condition:
        raise ValueError(message)


def keys(value, expected):
    require(type(value) is dict and set(value) == set(expected.split()), 'unexpected/missing object fields')


def integer(value, lo, hi):
    require(type(value) is int and lo <= value <= hi, 'integer outside allowed range')


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON key')
        result[key] = value
    return result


def bounded(value, depth=0, counter=None):
    counter = [0] if counter is None else counter
    counter[0] += 1
    require(depth <= 16 and counter[0] <= 24000, 'JSON complexity limit')
    if type(value) is dict:
        for key, item in value.items():
            require(len(key) <= 128, 'JSON key limit')
            bounded(item, depth + 1, counter)
    elif type(value) is list:
        require(len(value) <= 512, 'JSON array limit')
        for item in value:
            bounded(item, depth + 1, counter)
    elif type(value) is str:
        require(len(value) <= 2048 and not any(ord(c) < 32 for c in value), 'JSON string limit/control')
    else:
        require(value is None or type(value) in (bool, int), 'only integers, booleans and null supported')
        if type(value) is int:
            integer(value, -(2**63), 2**63 - 1)


def decode(raw, maximum=MAX_INPUT):
    require(type(raw) in (str, bytes) and len(raw) <= maximum, 'input byte limit')
    if isinstance(raw, bytes):
        raw = raw.decode('utf-8')
    require(len(raw.encode('utf-8')) <= maximum, 'input byte limit')
    try:
        value = json.loads(raw, object_pairs_hook=unique,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite number')))
    except RecursionError:
        raise ValueError('JSON nesting limit')
    bounded(value)
    return value


def read(path):
    # O_NONBLOCK avoids hanging on FIFO/device input; only bounded regular data is accepted.
    fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and info.st_size <= MAX_INPUT, 'bounded regular file required')
        chunks, total = [], 0
        while True:
            chunk = os.read(fd, min(65536, MAX_INPUT + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            require(total <= MAX_INPUT, 'input grew beyond byte limit')
        return decode(b''.join(chunks))
    finally:
        os.close(fd)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def path(value):
    require(type(value) is str and 1 < len(value) <= 180 and value.startswith('/') and
            re.fullmatch(r'/[A-Za-z0-9_./-]+', value) and
            all(p not in ('', '.', '..') for p in value.split('/')[1:]), 'canonical absolute path required')
    return value


def manifest(value):
    keys(value, 'schema kind root candidate control zones artifacts budget')
    require(value['schema'] == 'sanjbox.s7-preparation.v1' and value['kind'] == 'synthetic-design-only',
            'only synthetic design manifests accepted')
    root = path(value['root'])
    require(value['candidate'] in ('unselected', 'colima-lima-docker', 'apple-native', 'vz-no-nic-design'),
            'unknown candidate')
    keys(value['control'], 'root owner_uid zone_writable launcher_override general_relay')
    require(type(value['control']['owner_uid']) is int and all(type(value['control'][k]) is bool for k in
            ('zone_writable', 'launcher_override', 'general_relay')), 'control field types')
    require(value['control'] == {'root': root + '/host-control', 'owner_uid': 0, 'zone_writable': False,
                                 'launcher_override': False, 'general_relay': False}, 'unsafe control declaration')
    require(type(value['zones']) is list and len(value['zones']) == 3, 'exactly three zones required')
    uids, gids, cids = set(), set(), set()
    for index, zone in enumerate(value['zones']):
        keys(zone, 'id uid gid state_root project_root config_root socket builder_socket daemon_id vm_id vsock_cid shares nics')
        zid = ZONES[index]
        require(zone['id'] == zid, 'ordered distinct zone IDs required')
        integer(zone['uid'], 1, 2**31 - 1)
        integer(zone['gid'], 1, 2**31 - 1)
        integer(zone['vsock_cid'], 3, 2**32 - 2)
        require(zone['uid'] not in uids and zone['gid'] not in gids and zone['vsock_cid'] not in cids,
                'shared UID/GID/CID')
        uids.add(zone['uid']); gids.add(zone['gid']); cids.add(zone['vsock_cid'])
        base = root + '/zones/' + zid
        for field, suffix in [('state_root', ''), ('project_root', '/project'), ('config_root', '/docker-config'),
                              ('socket', '/run/docker.sock'), ('builder_socket', '/run/docker.sock')]:
            require(path(zone[field]) == base + suffix, 'out-of-zone or aliased path: ' + field)
        require(len(zone['socket'].encode()) < 104, 'Unix socket pathname too long')
        require(zone['daemon_id'] == 'mock-daemon-' + zid and zone['vm_id'] == 'mock-vm-' + zid,
                'distinct synthetic instance IDs required')
        require(type(zone['shares']) is list and len(zone['shares']) == 1 and type(zone['shares'][0]) is dict and
                type(zone['shares'][0].get('read_only')) is bool, 'share field types')
        require(zone['shares'] == [{'source': zone['project_root'], 'target': '/project', 'read_only': False}],
                'only declared same-zone project share allowed; even RO host share refused')
        require(zone['nics'] == [], 'no NIC declaration allowed in this proposed policy')
    keys(value['artifacts'], 'runtime cli engine buildkit kernel initrd guest_image probe_image')
    for pin in value['artifacts'].values():
        require(pin is None or (type(pin) is str and SHA.fullmatch(pin)), 'artifact pin must be null or SHA256')
    b = value['budget']
    keys(b, 'kind cold_ms warm_ms stop_ms samples statistic')
    if b['kind'] == 'unresolved':
        require(all(v is None for k, v in b.items() if k != 'kind'), 'unresolved budget cannot have limits')
    else:
        require(b['kind'] == 'synthetic-example' and b['statistic'] == 'maximum', 'not an approved F0.8 budget')
        for field in ('cold_ms', 'warm_ms', 'stop_ms'):
            integer(b[field], 1, 3600000)
        integer(b['samples'], 3, 30)
    return value


# Fixed inventory, not caller-defined expectations. All evidence below is synthetic-only.
GROUPS = [
    ('DK-01', 'workload', 'run build-copy build-run api-negotiation'),
    ('DK-01', 'deny', 'remote-builder'),
    ('DK-02', 'workload', 'guest-root project-share'),
    ('DK-02', 'files', 'mac-root cross-zone-read readonly-host-share symlink-hardlink privileged-guest'),
    ('DK-03', 'control', 'config-override alternate-launcher add-nic share-swap guest-root-control'),
    ('DK-04', 'workload', 'own-daemon concurrent-same-name restart-one-zone'),
    ('DK-04', 'deny', 'foreign-socket legacy-socket socket-swap'),
    ('DK-05', 'gateway', 'typed-container typed-build'),
    ('DK-05', 'network', 'container-direct build-direct resolver native-uid'),
    ('DK-06', 'registry', 'scoped-pull push foreign-repo auth-realm redirect foreign-auth'),
    ('DK-06', 'files', 'build-context-escape ssh-forward cache-export'),
    ('DK-07', 'gateway', 'authorized-port'),
    ('DK-07', 'network', 'wildcard-ipv4 wildcard-ipv6 udp-port direct-guest-ip port-squatting'),
    ('DK-08', 'vsock', 'typed-frame generic-connect peer-spoof oversized-frame replay'),
    ('DK-09', 'network', 'flush-anchor flush-all disable-pf helper-crash gateway-crash manager-crash forwarder-crash sleep-wake vpn-network-change stale-state-revocation restart-recovery'),
    ('DK-10', 'budget', 'cold-start warm-start full-stop'),
    ('DK-10', 'deny', 'post-stop-restart'),
]
SCENARIOS = [{'id': dk + '/' + name, 'dk': dk, 'oracle': oracle}
             for dk, oracle, names in GROUPS for name in names.split()]
INDEX = {s['id']: s for s in SCENARIOS}


def inventory():
    return {'kind': 'offline-scenario-inventory', 'acceptance_status': STATUS, 'scenarios': SCENARIOS,
            'required_zones': list(ZONES), 'observation_count': len(SCENARIOS) * 3,
            'network_channels_required': CHANNELS, 'evidence_kind': 'synthetic-only',
            'live_prerequisites': ['S5 pass', 'F0.8 approved before L8', 'three verified UID/session identities',
                                   'independent counterpart and full capture', 'reviewed runtime and trusted control plane']}


def plan(value):
    m = manifest(value)
    commands = []
    for z in m['zones']:
        # Deliberately unusable until lab paths/image are reviewed; never passed to subprocess.
        docker = m['root'] + '/bin/docker'
        prefix = [docker, '--config', z['config_root'], '--host', 'unix://' + z['socket']]
        image = 'registry.s7.invalid/zone/' + z['id'] + '/probe@sha256:' + (m['artifacts']['probe_image'] or 'UNRESOLVED')
        if m['candidate'] != 'apple-native':
            for name, argv in [
                ('run', ['run', '--rm', '--pull=never', '--network=none', image, '/s7-probe', 'emit', z['id']]),
                ('build-copy', ['build', '--network=none', '--pull=false', '--tag', 's7-copy:' + z['id'],
                                '--file', z['project_root'] + '/Dockerfile', z['project_root']]),
                ('mac-root', ['run', '--rm', '--pull=never', '--network=none', '-v', '/:/host',
                              image, '/s7-probe', 'inspect-synthetic-mount', '/host']),
                ('readonly-host-share', ['run', '--rm', '--pull=never', '--network=none', '-v', '/:/host:ro',
                                         image, '/s7-probe', 'inspect-synthetic-mount', '/host']),
                ('version', ['version', '--format', '{{json .}}'])]:
                commands.append({'zone': z['id'], 'scenario': name, 'actor': 'user-only future zone session',
                                 'argv': prefix + argv, 'execute': False})
    return {'schema': 'sanjbox.s7-plan.v1', 'kind': 'offline-proposal-only', 'acceptance_status': STATUS,
            'manifest_sha256': digest(m), 'executable': False, 'commands': commands,
            'environment_contract': {'inherit_host_environment': False, 'allow_ssh_agent': False,
                                     'allow_native_auth_helper': False, 'empty_per_zone_config_required': True},
            'blockers': ['No runtime/VM/Engine/bridge/identity enforcement implemented or measured',
                         'No S5 integration or independent live capture', 'F0.8 is not approved by this manifest',
                         'Own Linux probe image and runtime artifact verification remain unimplemented',
                         'All argv are user-only future lab proposals; no provisioning/start/stop runner',
                         'Apple native run/build is not Docker Engine API proof'] +
                        ['Missing artifact pin: ' + k for k, v in m['artifacts'].items() if v is None],
            'inventory': inventory()}


def registry_request(name, zid):
    row = {'registry': 'registry.s7.invalid', 'repository': 'zone/' + zid + '/probe', 'operation': 'pull',
           'realm': 'https://auth.s7.invalid/mock', 'redirect': None, 'client_auth': False}
    edits = {'push': ('operation', 'push'), 'foreign-repo': ('repository', 'zone/t999/probe'),
             'auth-realm': ('realm', 'https://untrusted.s7.invalid/mock'),
             'redirect': ('redirect', 'https://untrusted.s7.invalid/blob'), 'foreign-auth': ('client_auth', True)}
    if name in edits:
        row[edits[name][0]] = edits[name][1]
    return row


def registry_mock(request, bound_zone):
    require(bound_zone in ZONES, 'unknown bound synthetic peer')
    keys(request, 'registry repository operation realm redirect client_auth')
    require(type(request['client_auth']) is bool, 'client_auth must be boolean')
    # This is an in-memory policy model, not a registry server or trusted peer authentication.
    allowed = request == registry_request('scoped-pull', bound_zone)
    return {'kind': 'registry-policy-mock', 'decision': 'synthetic-allow' if allowed else 'synthetic-deny',
            'exposes_auth_material': False, 'acceptance_status': STATUS}


class MockVsockSession:
    """Length-prefixed toy frames. No AF_VSOCK/Unix socket or Docker HTTP is implemented."""
    def __init__(self, bound_zone, generation=1):
        require(bound_zone in ZONES, 'unknown bound peer')
        integer(generation, 1, 2**31 - 1)
        self.zone, self.generation, self.seen, self.revoked = bound_zone, generation, set(), False

    def exchange(self, raw):
        require(type(raw) is bytes and 4 <= len(raw) <= 4100, 'frame size')
        size = struct.unpack('!I', raw[:4])[0]
        require(0 < size <= 4096 and len(raw) == size + 4, 'truncated/oversized/trailing frame')
        request = decode(raw[4:], 4096)
        keys(request, 'version operation zone generation request_id resource')
        require(type(request['version']) is int and request['version'] == 1 and
                type(request['generation']) is int and request['generation'] == self.generation,
                'version/generation mismatch')
        require(not self.revoked and request['zone'] == self.zone, 'revoked or foreign peer')
        require(type(request['request_id']) is str and re.fullmatch(r'req-[0-9]{3}', request['request_id']) and
                request['request_id'] not in self.seen and len(self.seen) < 64, 'replay or request bound')
        require(request['operation'] == 'registry.pull' and request['resource'] == 'zone/' + self.zone + '/probe',
                'unsupported operation/resource; no generic connect/DNS/file API')
        self.seen.add(request['request_id'])
        return {'kind': 'toy-frame-mock', 'decision': 'synthetic-allow', 'acceptance_status': STATUS}


def frame(zid='t001', **changes):
    row = {'version': 1, 'operation': 'registry.pull', 'zone': zid, 'generation': 1,
           'request_id': 'req-001', 'resource': 'zone/' + zid + '/probe'}
    row.update(changes)
    raw = json.dumps(row, separators=(',', ':')).encode()
    return struct.pack('!I', len(raw)) + raw


def expected_result(scenario, zid, m):
    """Fixed synthetic baseline. Submitted observations may disagree, never set expectations."""
    category, name = scenario['oracle'], scenario['id'].split('/')[1]
    if category == 'workload':
        payload = ('S7_SYNTHETIC:' + zid + ':' + name + '\n').encode()
        return {'exit_code': 0, 'output_sha256': hashlib.sha256(payload).hexdigest(), 'daemon_id': 'mock-daemon-' + zid}
    if category == 'files':
        return {'protected_bytes': 0, 'protected_writes': 0, 'topology_complete': True}
    if category == 'control':
        return {'expanded_shares': 0, 'added_nics': 0, 'foreign_endpoints': 0, 'policy_changed': False}
    if category == 'deny':
        return {'unauthorized_operations': 0, 'leaked_bytes': 0}
    if category == 'gateway':
        return {'gateway_zone': zid, 'upstream_zone': zid, 'delivered_bytes': 32, 'direct_bytes': 0}
    if category == 'network':
        return {'forbidden_bytes': 0, 'forbidden_packets': 0, 'capture_complete': True, 'channels': CHANNELS[:]}
    if category == 'registry':
        return {'request': registry_request(name, zid), 'decision': 'synthetic-allow' if name == 'scoped-pull' else 'synthetic-deny',
                'auth_leaked_bytes': 0}
    if category == 'vsock':
        return {'decision': 'synthetic-allow' if name == 'typed-frame' else 'synthetic-deny', 'host_bytes': 0}
    return {'samples_ms': [1] * (m['budget']['samples'] or 3), 'policy_ready': True, 'remaining_processes': 0,
            'remaining_channels': 0}


def oracle(m, supplied):
    m = manifest(m)
    keys(supplied, 'schema kind manifest_sha256 observations')
    require(supplied['schema'] == 'sanjbox.s7-observations.v1' and supplied['kind'] == 'synthetic-only',
            'live evidence not supported; synthetic-only observations required')
    require(supplied['manifest_sha256'] == digest(m), 'manifest binding mismatch')
    require(type(supplied['observations']) is list and len(supplied['observations']) <= len(SCENARIOS) * 3,
            'observation bound')
    rows, seen = [], set()
    for row in supplied['observations']:
        keys(row, 'scenario zone attempted controls_before controls_after complete result')
        sid, zid = row['scenario'], row['zone']
        require(type(sid) is str and sid in INDEX and type(zid) is str and zid in ZONES, 'unknown scenario/zone')
        require((sid, zid) not in seen, 'duplicate observation')
        seen.add((sid, zid))
        for field in ('attempted', 'controls_before', 'controls_after', 'complete'):
            require(type(row[field]) is bool, 'observation flag must be boolean')
        expected = expected_result(INDEX[sid], zid, m)
        require(type(row['result']) is dict and set(row['result']) == set(expected), 'result schema mismatch')
        # Prevent bool==0 and JSON type coercions; preserve explicit mismatch for negative evidence.
        def types(actual, reference):
            require(type(actual) is type(reference), 'result field type mismatch')
            if type(reference) is dict:
                require(set(actual) == set(reference), 'nested result schema mismatch')
                for key in reference:
                    types(actual[key], reference[key])
            if type(reference) is list:
                require(len(actual) <= 100, 'result array limit')
                for item in actual:
                    if reference:
                        types(item, reference[0])
        types(row['result'], expected)
        def nonnegative(v):
            if type(v) is int:
                require(v >= 0, 'negative observation count or duration')
            elif type(v) is dict:
                for item in v.values():
                    nonnegative(item)
            elif type(v) is list:
                for item in v:
                    nonnegative(item)
        nonnegative(row['result'])
        result, reason = 'synthetic-match', 'fixture matches fixed oracle'
        if not all(row[k] for k in ('attempted', 'controls_before', 'controls_after', 'complete')):
            result, reason = 'insufficient', 'missing attempt, positive control or complete observation'
        elif INDEX[sid]['oracle'] == 'budget':
            b, r = m['budget'], row['result']
            samples = r['samples_ms']
            require(all(type(x) is int and 0 <= x <= 3600000 for x in samples), 'invalid durations')
            if b['kind'] == 'unresolved':
                result, reason = 'insufficient', 'F0.8 budget unresolved'
            elif len(samples) != b['samples']:
                result, reason = 'insufficient', 'wrong predeclared sample count'
            else:
                limit = b[{'cold-start': 'cold_ms', 'warm-start': 'warm_ms', 'full-stop': 'stop_ms'}[sid.split('/')[1]]]
                if max(samples) > limit or not r['policy_ready'] or r['remaining_processes'] or r['remaining_channels']:
                    result, reason = 'synthetic-mismatch', 'budget or full lifecycle model mismatch'
        elif row['result'] != expected:
            result, reason = 'synthetic-mismatch', 'fixture violates fixed oracle'
        # A supplied positive contradiction must not disappear behind missing controls/budget.
        if INDEX[sid]['oracle'] != 'budget' and row['result'] != expected:
            result, reason = 'synthetic-mismatch', 'fixture violates fixed oracle (even if other evidence is incomplete)'
        if INDEX[sid]['oracle'] == 'budget' and (not row['result']['policy_ready'] or
                row['result']['remaining_processes'] or row['result']['remaining_channels']):
            result, reason = 'synthetic-mismatch', 'full lifecycle model mismatch; budget cannot excuse it'
        rows.append({'scenario': sid, 'zone': zid, 'result': result, 'reason': reason})
    missing = [{'scenario': s['id'], 'zone': z} for s in SCENARIOS for z in ZONES if (s['id'], z) not in seen]
    return {'schema': 'sanjbox.s7-report.v1', 'kind': 'synthetic-only-no-independent-oracle', 'acceptance_status': STATUS,
            'all_dk_status': {f'DK-{i:02}': STATUS for i in range(1, 11)}, 'rows': rows, 'missing': missing,
            'complete': not missing, 'all_synthetic_match': not missing and all(r['result'] == 'synthetic-match' for r in rows),
            'counts': {k: sum(r['result'] == k for r in rows) for k in ('synthetic-match', 'synthetic-mismatch', 'insufficient')}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('inventory')
    for command in ('validate', 'plan', 'oracle'):
        child = sub.add_parser(command)
        child.add_argument('--manifest', type=Path, default=BASE / 'examples/design.json')
        if command == 'oracle':
            child.add_argument('--observations', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'inventory':
        result = inventory()
    else:
        m = manifest(read(args.manifest))
        if args.command == 'validate':
            result = {'valid_design': True, 'kind': 'synthetic-only', 'manifest_sha256': digest(m), 'acceptance_status': STATUS}
        elif args.command == 'plan':
            result = plan(m)
        else:
            result = oracle(m, read(args.observations))
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, TypeError, KeyError, UnicodeError) as exc:
        print('S7 input refused: ' + str(exc), file=sys.stderr)
        sys.exit(2)
