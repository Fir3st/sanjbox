#!/usr/bin/python3
"""Offline D6 compatibility inventory validator/report; no clients or network.

The validator checks structure, coverage, provenance and contradictions. It cannot
prove that a citation is true, current, or sufficient: those require review.
"""
import argparse
import collections
import datetime
import json
import os
from pathlib import Path
import re
import stat
import sys
from urllib.parse import urlsplit

BASELINE = 'afae1ca7dfe78f03d5006c42b6b01093772eba0c'
PROPOSED = '9ddb62e2efde534d7057a1ce01aa9bd942156ee8'
HERE = Path(__file__).resolve().parent
MAX_BYTES = 1_048_576
# A separate coverage contract: deleting an input row/profile cannot shrink it.
CATALOG = {
    'npm': ('npm', 'npm-registry-http1'),
    'pnpm': ('pnpm', 'npm-registry-http1'),
    'yarn': ('Yarn', 'npm-registry-http1'),
    'bun': ('Bun', 'npm-registry-http1'),
    'pip': ('pip', 'pypi-simple-json-http1'),
    'uv': ('uv', 'pypi-simple-json-http1'),
    'brew': ('Homebrew', 'brew-json-oci-http'),
    'git-http': ('Git', 'git-smart-http-v0'),
    'git-ssh': ('Git', 'ssh-deploy-key'),
    'cargo': ('Cargo', 'cargo-sparse-or-git-index'),
    'go': ('Go', 'goproxy-sumdb-http'),
    'gradle': ('Gradle', 'maven-ivy-http'),
    'maven': ('Maven', 'maven-repository-http'),
    'nuget': ('NuGet', 'nuget-v3-http'),
    'conda': ('Conda', 'conda-channel-http'),
    'rubygems': ('RubyGems', 'rubygems-index-http'),
    'anthropic-python': ('Anthropic SDK (python)', 'anthropic-messages-sse'),
    'anthropic-typescript': ('Anthropic SDK (typescript)', 'anthropic-messages-sse'),
    'openai-python': ('OpenAI SDK (python)', 'openai-responses-chat-sse'),
    'openai-typescript': ('OpenAI SDK (typescript)', 'openai-responses-chat-sse'),
    'opencode': ('OpenCode', 'agent-provider-http-sse'),
    'claude-code': ('Claude Code', 'agent-messages-sse'),
    'codex': ('Codex', 'agent-responses-sse-websocket'),
    'websocket': ('WebSocket', 'rfc6455-ws-wss'),
    'sse': ('SSE transport', 'http1-sse'),
}
POLICIES = {'typed', 'passthrough', 'identity', 'trust', 'cache',
            'd1-limits', 'npm-limits', 'model-limits', 'd5-limits'}
OBSERVATIONS = {
    'npm-fixture': ('npm', 'baseline', BASELINE, 'local_client_fixture'),
    'sse-fixture': ('sse', 'baseline', BASELINE, 'local_transport_fixture'),
    'pip-fixture': ('pip', 'proposed_d5', PROPOSED, 'local_client_fixture'),
    'git-fixture': ('git-http', 'proposed_d5', PROPOSED, 'local_client_fixture'),
}
OFFICIAL_HOSTS = {
    'docs.npmjs.com', 'pnpm.io', 'yarnpkg.com', 'bun.com', 'pip.pypa.io',
    'packaging.python.org', 'docs.astral.sh', 'docs.brew.sh', 'git-scm.com',
    'doc.rust-lang.org', 'go.dev', 'docs.gradle.org', 'maven.apache.org',
    'learn.microsoft.com', 'docs.conda.io', 'guides.rubygems.org',
    'platform.claude.com', 'raw.githubusercontent.com', 'developers.openai.com',
    'pydantic.dev', 'nodejs.org', 'opencode.ai', 'code.claude.com',
    'learn.chatgpt.com', 'www.rfc-editor.org', 'html.spec.whatwg.org',
}

class Invalid(ValueError):
    pass

def require(ok, where, reason):
    if not ok:
        raise Invalid(where + ': ' + reason)

def shape(value, keys, where):
    require(type(value) is dict, where, 'expected object')
    require(set(value) == set(keys), where, 'missing or unexpected fields')

def nonempty(value, where):
    require(type(value) is str and 0 < len(value.strip()) <= 4000, where, 'expected bounded nonempty string')
    require(all(ord(ch) >= 32 or ch == '\n' for ch in value), where, 'control character')

def listing(value, where, maximum=256):
    require(type(value) is list and len(value) <= maximum, where, 'expected bounded list')

def unique_map(items, where):
    listing(items, where)
    result = {}
    for item in items:
        require(type(item) is dict, where, 'expected object item')
        ident = item.get('id')
        nonempty(ident, where + '.id')
        require(ident not in result, where, 'duplicate id: ' + ident)
        result[ident] = item
    return result

def reference_list(refs, known, where):
    listing(refs, where, 16)
    require(len(refs) > 0, where, 'uncited claim')
    require(all(type(x) is str and x in known for x in refs), where, 'unknown citation')
    require(len(refs) == len(set(refs)), where, 'duplicate citation')

def claim(value, sources, where):
    shape(value, {'text', 'refs'}, where)
    nonempty(value['text'], where + '.text')
    reference_list(value['refs'], sources, where + '.refs')

def date_value(value, where):
    require(type(value) is str and re.fullmatch(r'\d{4}-\d{2}-\d{2}', value), where, 'invalid date')
    try:
        return datetime.date.fromisoformat(value)
    except ValueError:
        raise Invalid(where + ': invalid date') from None

def strict_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Invalid('JSON: duplicate object key')
        result[key] = value
    return result

def reject_constant(_):
    raise Invalid('JSON: nonfinite constant')

def load_json(path):
    """Read one bounded regular non-symlink input; never write or execute it."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        require(stat.S_ISREG(os.fstat(fd).st_mode), 'input', 'not a regular file')
        with os.fdopen(fd, 'rb', closefd=False) as stream:
            raw = stream.read(MAX_BYTES + 1)
    finally:
        os.close(fd)
    require(len(raw) <= MAX_BYTES, 'input', 'exceeds 1 MiB')
    try:
        value = json.loads(raw.decode('utf-8'), object_pairs_hook=strict_pairs, parse_constant=reject_constant)
    except (UnicodeError, json.JSONDecodeError, RecursionError):
        raise Invalid('input: malformed UTF-8 JSON or excessive nesting') from None
    # Do not recurse through attacker-controlled structure.
    pending = [(value, 0)]
    nodes = 0
    while pending:
        current, depth = pending.pop()
        nodes += 1
        require(depth <= 32 and nodes <= 50_000, 'input', 'structure budget exceeded')
        children = current.values() if type(current) is dict else current if type(current) is list else ()
        pending.extend((child, depth + 1) for child in children)
    return value

def validate(matrix, source_manifest):
    shape(source_manifest, {'schema_version', 'sources'}, 'sources')
    require(type(source_manifest['schema_version']) is int and source_manifest['schema_version'] == 1, 'sources', 'unknown schema')
    sources = unique_map(source_manifest['sources'], 'sources')
    for sid, source in sources.items():
        where = 'source.' + sid
        common = {'id', 'kind', 'url', 'title', 'reviewed_on', 'version_scope', 'locator'}
        kind = source.get('kind')
        is_repo = type(kind) is str and kind in {'repository_document', 'repository_source', 'local_client_fixture', 'local_transport_fixture'}
        require(type(kind) is str and (kind == 'official_documentation' or is_repo), where, 'unknown source kind')
        shape(source, common | ({'revision', 'path'} if is_repo else set()), where)
        for field in ('id', 'url', 'title', 'version_scope', 'locator'):
            nonempty(source[field], where + '.' + field)
        date_value(source['reviewed_on'], where)
        url = urlsplit(source['url'])
        require(url.scheme == 'https' and not url.username and not url.password and not url.query and url.port is None, where, 'unsafe source URL')
        if is_repo:
            require(type(source['revision']) is str and source['revision'] in {BASELINE, PROPOSED}, where, 'unreviewed repository revision')
            path = source['path']
            nonempty(path, where + '.path')
            require(not path.startswith('/') and '..' not in path.split('/') and '\\' not in path, where, 'invalid repository path')
            require(source['url'] == 'https://github.com/Fir3st/sanjbox/blob/' + source['revision'] + '/' + path, where, 'source pin/URL mismatch')
            if kind.startswith('local_'):
                require(sid in OBSERVATIONS and kind == OBSERVATIONS[sid][3], where, 'unregistered fixture evidence')
        else:
            require(url.hostname in OFFICIAL_HOSTS, where, 'source outside reviewed primary publishers')
            if url.hostname == 'raw.githubusercontent.com':
                require(url.path == '/anthropics/anthropic-sdk-typescript/main/src/client.ts', where, 'unreviewed upstream source')
    shape(matrix, {'schema_version', 'reviewed_on', 'baseline_revision', 'proposed_d5_revision', 'gate_status',
                   'live_integration_status', 'policies', 'profiles', 'observations', 'rows'}, 'matrix')
    require(type(matrix['schema_version']) is int and matrix['schema_version'] == 1, 'matrix', 'unknown schema')
    review_date = date_value(matrix['reviewed_on'], 'matrix.reviewed_on')
    require(matrix['baseline_revision'] == BASELINE and matrix['proposed_d5_revision'] == PROPOSED, 'matrix', 'revision drift needs a reviewed contract update')
    require(matrix['gate_status'] == matrix['live_integration_status'] == 'unverified', 'matrix', 'unsupported gate/live positive')
    require(all(date_value(x['reviewed_on'], 'source.date') <= review_date for x in sources.values()), 'matrix', 'source reviewed after matrix')
    shape(matrix['policies'], POLICIES, 'policies')
    for key, value in matrix['policies'].items():
        claim(value, sources, 'policy.' + key)
    profiles = unique_map(matrix['profiles'], 'profiles')
    require(set(profiles) == set(CATALOG), 'profiles', 'missing or unexpected required profile')
    for pid, profile in profiles.items():
        shape(profile, {'id', 'tool', 'protocol', 'version', 'operations', 'exclusions', 'http', 'https',
                        'credentials', 'limits', 'collision'}, 'profile.' + pid)
        require((profile['tool'], profile['protocol']) == CATALOG[pid], 'profile.' + pid, 'tool/protocol mismatch')
        for field in ('version', 'operations', 'exclusions', 'http', 'https', 'credentials', 'collision'):
            claim(profile[field], sources, pid + '.' + field)
        listing(profile['limits'], pid + '.limits', len(POLICIES))
        require(profile['limits'] and all(type(x) is str and x in POLICIES for x in profile['limits']), pid, 'missing/unknown constraints')
        require(len(profile['limits']) == len(set(profile['limits'])), pid, 'duplicate constraints')
        require(any(sources[s]['kind'] == 'official_documentation' for s in profile['version']['refs']) or pid == 'git-ssh' or pid == 'git-http', pid, 'missing primary version/protocol source')
    observations = unique_map(matrix['observations'], 'observations')
    require(set(observations) == set(OBSERVATIONS), 'observations', 'missing or unreviewed fixture observation')
    for oid, observation in observations.items():
        shape(observation, {'id', 'profile', 'layer', 'revision', 'client_version', 'result', 'provenance', 'refs'}, 'observation.' + oid)
        profile, layer, revision, kind = OBSERVATIONS[oid]
        require((observation['profile'], observation['layer'], observation['revision']) == (profile, layer, revision), oid, 'fixture layer/revision/profile mismatch')
        require(observation['result'] == 'passed_local_fixture' and observation['provenance'] == 'inherited_report_not_rerun_by_D6', oid, 'unsupported evidence promotion')
        nonempty(observation['client_version'], oid + '.client_version')
        reference_list(observation['refs'], sources, oid + '.refs')
        require(oid in observation['refs'] and oid in sources and sources[oid]['kind'] == kind and sources[oid]['revision'] == revision, oid, 'fixture citation required; documentation alone cannot prove compatibility')
    rows = unique_map(matrix['rows'], 'rows')
    expected = {pid + '/' + policy for pid in CATALOG for policy in ('typed', 'passthrough')}
    require(set(rows) == expected, 'rows', 'missing or unexpected tool/protocol/policy row')
    seen = set()
    for rid, row in rows.items():
        shape(row, {'id', 'profile', 'tool', 'protocol', 'policy', 'baseline', 'proposed_d5'}, rid)
        pid, policy = rid.split('/')
        require(row['profile'] == pid and row['policy'] == policy and (row['tool'], row['protocol']) == CATALOG[pid], rid, 'tuple mismatch')
        key = row['tool'], row['protocol'], policy
        require(key not in seen, rid, 'duplicate tool/protocol/policy tuple')
        seen.add(key)
        for layer in ('baseline', 'proposed_d5'):
            assessment = row[layer]
            if layer == 'proposed_d5' and assessment is None:
                require(policy == 'passthrough' or pid not in {'pip', 'uv', 'brew', 'git-http'}, rid, 'missing provisional assessment')
                continue
            require(layer == 'baseline' or (policy == 'typed' and pid in {'pip', 'uv', 'brew', 'git-http'}), rid, 'unexpected provisional assessment')
            shape(assessment, {'status', 'basis', 'observations'}, rid + '.' + layer)
            status = assessment['status']
            require(type(status) is str and status in {'unsupported', 'untested', 'fixture_only'}, rid, 'unsupported positive/status')
            claim(assessment['basis'], sources, rid + '.' + layer + '.basis')
            listing(assessment['observations'], rid + '.observations', 4)
            require(all(type(x) is str and x in observations for x in assessment['observations']), rid, 'unknown observation')
            require(len(set(assessment['observations'])) == len(assessment['observations']), rid, 'duplicate observation')
            if policy == 'passthrough':
                require(status == 'unsupported' and not assessment['observations'], rid, 'passthrough cannot be positive')
            elif status == 'fixture_only':
                require(bool(assessment['observations']), rid, 'positive needs observed fixture')
                for oid in assessment['observations']:
                    require((observations[oid]['profile'], observations[oid]['layer']) == (pid, layer), rid, 'wrong client or evidence layer')
            else:
                require(not assessment['observations'], rid, 'unsupported/untested cannot carry a passing observation')
            # Known absent adapters cannot be relabelled as merely untested.
            allowed_untested = {'pnpm', 'yarn', 'bun'} if layer == 'baseline' else {'uv'}
            require(status != 'untested' or (policy == 'typed' and pid in allowed_untested), rid, 'known unsupported adapter cannot become untested')
    return matrix

def link_claim(value, sources):
    text = value['text'].replace('|', '\\|').replace('\n', ' ')
    links = ', '.join('[' + sid + '](' + sources[sid]['url'] + ')' for sid in dict.fromkeys(value['refs']))
    return text + ' ' + links

def markdown_report(matrix, manifest):
    validate(matrix, manifest)
    sources = {s['id']: s for s in manifest['sources']}
    profiles = {p['id']: p for p in matrix['profiles']}
    lines = ['# D6 compatibility matrix', '',
             'Generated by `matrix.py report`; reviewed ' + matrix['reviewed_on'] + '.', '',
             'Baseline `' + BASELINE + '`; provisional D5 `' + PROPOSED + '` is a separate proposal, not an installed dependency.', '',
             '**S5/GW-19 and live integration remain unverified.** `fixture_only` means a narrowly scoped inherited local observation. `untested` means a candidate wire subset exists but this client was not run. `unsupported` means absent, incompatible or denied; it is not a deferred positive.', '',
             '| Client | Protocol | Typed baseline | Provisional D5 | Passthrough |',
             '|---|---|---|---|---|']
    rows = {r['id']: r for r in matrix['rows']}
    for pid in CATALOG:
        row = rows[pid + '/typed']
        prop = row['proposed_d5']
        lines.append('| ' + row['tool'] + ' | `' + row['protocol'] + '` | ' + row['baseline']['status'] + ' | ' + (prop['status'] if prop else 'no change') + ' | unsupported |')
    lines += ['', '## Shared policy and limits', '']
    for pid in sorted(matrix['policies']):
        lines += ['- **' + pid + ':** ' + link_claim(matrix['policies'][pid], sources)]
    lines += ['', '## Exact subsets and evidence', '']
    for pid in CATALOG:
        p = profiles[pid]
        row = rows[pid + '/typed']
        lines += ['### ' + p['tool'] + ' — ' + p['protocol'], '']
        for field in ('version', 'operations', 'exclusions', 'http', 'https', 'credentials', 'collision'):
            lines += ['- **' + field + ':** ' + link_claim(p[field], sources)]
        lines += ['- **Constraints:** ' + ', '.join('`' + x + '`' for x in p['limits']) + '.']
        for layer in ('baseline', 'proposed_d5'):
            a = row[layer]
            if a:
                lines += ['- **' + layer + ': ' + a['status'] + '.** ' + link_claim(a['basis'], sources)]
                for oid in a['observations']:
                    observation = next(x for x in matrix['observations'] if x['id'] == oid)
                    lines += ['  - Inherited observation: ' + observation['client_version'] + '; `' + oid + '`; not rerun by D6.']
        lines += ['']
    lines += ['## Source maintenance', '', 'Official pages are dated review snapshots, not immutable copies or executable-version pins. Repository evidence is pinned by full commit. Recheck the cited sections and pin the exact client before any future fixture; review the protocol/auth/trust/auxiliary paths before changing a status. The validator checks citations and provenance structure, not the truth or freshness of their content.', '']
    return '\n'.join(lines)

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('validate', 'report'))
    parser.add_argument('--matrix', type=Path, default=HERE / 'matrix.json')
    parser.add_argument('--sources', type=Path, default=HERE / 'sources.json')
    parser.add_argument('--format', choices=('markdown', 'json'), default='markdown')
    args = parser.parse_args(argv)
    try:
        matrix, sources = load_json(args.matrix), load_json(args.sources)
        validate(matrix, sources)
        if args.command == 'validate':
            counts = collections.Counter(r['baseline']['status'] for r in matrix['rows'])
            print(json.dumps({'valid': True, 'profiles': len(matrix['profiles']), 'rows': len(matrix['rows']), 'baseline': dict(sorted(counts.items())), 'gate': 'unverified'}, sort_keys=True))
        elif args.format == 'json':
            print(json.dumps(matrix, indent=2, ensure_ascii=False, sort_keys=True))
        else:
            print(markdown_report(matrix, sources), end='')
        return 0
    except (Invalid, OSError, ValueError) as error:
        # No input data, parser excerpts, environment or file content is emitted.
        print('invalid: ' + str(error), file=sys.stderr)
        return 2

if __name__ == '__main__':
    raise SystemExit(main())
