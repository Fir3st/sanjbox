#!/usr/bin/python3
"""Offline, versioned F0.7/C-003 decision inventory; never a runtime policy.

Accepted scope, implementation, live evidence and gate results are separate.
This snapshot deliberately cannot accept new domains, evidence or positive
implementation claims without a reviewed code/data change.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('historical_matrix', HERE / 'matrix.py')
historical = importlib.util.module_from_spec(spec)
spec.loader.exec_module(historical)
Invalid = historical.Invalid
require = historical.require
shape = historical.shape
load_json = historical.load_json

DECISION_REVISION = '740593d8d9e66e719c179572354f634c2ed85457'
SOURCE_REVISION = '7b20c41496f9a8d2a8e49604e31c7598a4943adb'
# Independent closed inventory: data cannot add an integration or change its identity.
CATALOG = {
    'claude-oauth': ('Claude', 'Claude subscription', 'oauth', 'c003'),
    'codex-oauth': ('Codex', 'ChatGPT account', 'oauth', 'c003'),
    'opencode-oauth': ('OpenCode', 'integration provider not yet reviewed', 'oauth', 'c003'),
    'opencode-api-key': ('OpenCode', 'existing typed gateway providers only', 'api_key', 'typed_api'),
    'github-classic-pat': ('Git', 'GitHub', 'classic_pat', 'project_git'),
    'xcode-simulator': ('Xcode', 'Apple Simulator only', 'none', 'simulator'),
    'unlisted': ('Unlisted integrations', 'unlisted', 'unlisted', 'unsupported'),
}
SOURCE_PINS = {
    'f0.7': (DECISION_REVISION, 'docs/DECISIONS.md', 'F0.7 — rozsah integrací (2026-11-07)'),
    'c003': (DECISION_REVISION, 'docs/DECISIONS.md', 'Změny kontraktu / C-003'),
    'git-code': (SOURCE_REVISION, 'spikes/s5-gateway/Sources/SanjboxGatewayCore/GitGateway.swift', 'GitConfiguration and GitGateway.response: no real credentials'),
    'model-code': (SOURCE_REVISION, 'spikes/s5-gateway/Sources/SanjboxGatewayCore/ModelAPIPolicy.swift', 'ModelAPITestKey: synthetic laboratory values only'),
    'historical': (SOURCE_REVISION, 'spikes/s5-compatibility/REPORT.md', 'Historical D6 baseline/provisional D5, no current-decision evidence'),
}
# These are decision constraints, not executable enforcement settings.
CONTRACTS = {
    'c003': {
        'route': 'tls_passthrough', 'opt_in': 'required_per_area',
        'domain_scope': 'closed_provider_integration_allowlist',
        'key_insertion': 'none', 'credential_custody': 'area_assumed_compromisable',
        'account_scope': 'not_restricted_by_area',
        'operation_scope': 'opaque_provider_tls_including_project_exfiltration_risk',
        'revocation': 'documented_on_disable_and_delete_required',
        'other_r3_tests': 'unchanged',
    },
    'typed_api': {
        'route': 'typed_gateway_only', 'credential_custody': 'host_keychain_only',
        'key_insertion': 'host_gateway_only', 'provider_scope': 'existing_typed_adapter_only',
        'caller_auth': 'denied', 'passthrough_fallback': 'denied',
    },
    'project_git': {
        'route': 'git_smart_http_only', 'credential_custody': 'host_keychain_only',
        'key_insertion': 'host_gateway_only', 'repository_scope': 'project_repository_only',
        'operations': ['fetch', 'push'], 'account_scope': 'classic_pat_is_not_repo_scoped',
        'area_token': 'denied', 'gh_cli': 'unsupported', 'github_api': 'unsupported',
        'alternate_protocol_fallback': 'denied',
    },
    'simulator': {
        'operations': ['simulator'], 'signing': 'unsupported',
        'apple_id': 'denied', 'app_store_connect_key': 'denied',
        'device_signing': 'requires_future_user_decision',
    },
    'unsupported': {'operations': [], 'fallback': 'denied'},
}
GAPS = {
    'c003': {'reviewed_provider_domains': 'missing', 'per_area_opt_in_enforcement': 'unverified',
             'account_identity_and_actual_scopes': 'unverified',
             'disable_and_delete_revocation': 'undocumented', 'live_compatibility': 'unverified',
             's5_provider_domain_exfiltration_measurement': 'missing'},
    'typed_api': {'live_host_key_custody_and_insertion': 'unimplemented_in_reviewed_spike',
                  'exact_client_adapter_compatibility': 'unverified',
                  'account_identity_and_actual_scopes': 'unverified', 'revocation': 'undocumented',
                  'live_compatibility': 'unverified'},
    'project_git': {'live_host_pat_custody_and_insertion': 'unimplemented_in_reviewed_spike',
                    'project_repository_authorization': 'unverified',
                    'account_identity_and_actual_scopes': 'unverified', 'revocation': 'undocumented',
                    'live_compatibility': 'unverified'},
    'simulator': {'area_session_and_simulator_compatibility': 'unverified'},
    'unsupported': {'user_decision': 'missing'},
}
BASIS_REFS = {
    'c003': ['f0.7', 'c003', 'historical'],
    'typed_api': ['f0.7', 'model-code', 'historical'],
    'project_git': ['f0.7', 'git-code', 'historical'],
    'simulator': ['f0.7'], 'unsupported': ['f0.7'],
}


def exact(value, expected, where, reason):
    # JSON equality alone treats True as 1; preserve types throughout constraints.
    require(type(value) is type(expected) and
            json.dumps(value, sort_keys=True) == json.dumps(expected, sort_keys=True), where, reason)


def validate(document):
    shape(document, {'schema_version', 'layer', 'reviewed_on', 'decision_date', 'purpose',
                     'historical', 'gate_status', 'sources', 'integrations'}, 'current')
    exact(document['schema_version'], 1, 'current', 'unknown schema')
    exact(document['layer'], 'f0.7-c003-v1', 'current', 'unknown decision layer')
    exact(document['purpose'], 'offline_inventory_not_runtime_policy', 'current', 'not runtime configuration')
    exact(document['decision_date'], '2026-11-07', 'current', 'decision date drift')
    exact(document['reviewed_on'], '2026-11-08', 'current', 'review snapshot drift')
    exact(document['historical'], {'baseline_revision': historical.BASELINE,
          'proposed_d5_revision': historical.PROPOSED, 'report': 'REPORT.md'},
          'historical', 'historical layer must remain separate')
    exact(document['gate_status'], {'S5': 'unverified', 'GW-19': 'unverified',
          'R3': 'unverified', 'R8': 'unverified'}, 'gates', 'acceptance is not a passed gate')
    sources = historical.unique_map(document['sources'], 'sources')
    require(set(sources) == set(SOURCE_PINS), 'sources', 'missing or unreviewed source')
    for sid, source in sources.items():
        shape(source, {'id', 'revision', 'path', 'locator'}, 'source.' + sid)
        exact([source['revision'], source['path'], source['locator']], list(SOURCE_PINS[sid]),
              'source.' + sid, 'source pin/locator mismatch')
    rows = historical.unique_map(document['integrations'], 'integrations')
    require(set(rows) == set(CATALOG), 'integrations', 'missing or unlisted integration')
    for rid, row in rows.items():
        where = 'integration.' + rid
        shape(row, {'id', 'client', 'provider_scope', 'auth_mode', 'decision_status',
                    'contract', 'known_gaps', 'implementation_status', 'implementation_evidence',
                    'live_status', 'live_evidence', 'full_r3', 'basis'}, where)
        client, provider, auth, kind = CATALOG[rid]
        exact([row['client'], row['provider_scope'], row['auth_mode']], [client, provider, auth],
              where, 'client/provider/auth mismatch')
        exact(row['contract'], CONTRACTS[kind], where, 'decision constraints changed')
        exact(row['known_gaps'], GAPS[kind], where, 'missing evidence cannot be removed or promoted')
        expected_decision = 'unsupported' if kind == 'unsupported' else 'accepted'
        exact(row['decision_status'], expected_decision, where, 'decision scope changed')
        expected_implementation = 'unsupported' if kind == 'unsupported' else 'blocked'
        exact(row['implementation_status'], expected_implementation, where,
              'accepted decision is not implementation; known gaps block integration')
        exact(row['implementation_evidence'], [], where, 'no reviewed implementation evidence for this integration')
        exact(row['live_status'], 'unverified', where, 'accepted decision is not live verification')
        exact(row['live_evidence'], [], where, 'no reviewed live evidence')
        exact(row['full_r3'], 'not_met_under_c003' if kind == 'c003' else 'unverified',
              where, 'C-003 never establishes full R3; other gates remain unverified')
        historical.claim(row['basis'], sources, where + '.basis')
        exact(row['basis']['refs'], BASIS_REFS[kind], where, 'decision and implementation provenance required')
    return document


def source_url(source):
    return 'https://github.com/Fir3st/sanjbox/blob/' + source['revision'] + '/' + source['path']


def markdown_report(document):
    validate(document)
    rows = {row['id']: row for row in document['integrations']}
    sources = {source['id']: source for source in document['sources']}
    lines = ['# D6 current decisions — F0.7 / C-003 v1', '',
             'Generated by `current_decisions.py report`; reviewed ' + document['reviewed_on'] +
             '; user decision ' + document['decision_date'] + '.', '',
             '**Accepted scope is not implemented or live-verified compatibility. S5, GW-19, R3 and R8 remain unverified.**', '',
             'This is an offline decision inventory, not runtime policy or permission to run an integration. '
             'The closed catalog has six accepted integration scopes and an unsupported default. '
             'Unlisted clients/providers/auth modes do not inherit an exception.', '',
             '[Historical REPORT.md](REPORT.md) retains its 50 rows, baseline `' + historical.BASELINE +
             '` and proposed D5 `' + historical.PROPOSED + '`. Its earlier unresolved-F0.7 and unsupported-passthrough '
             'statements describe those pins; they are not rewritten by the later decision. '
             'Historical local fixtures do not establish these live integrations.', '',
             '| Integration | Provider scope | Auth | User decision | Integration implementation | Live evidence | Full R3 |',
             '|---|---|---|---|---|---|---|']
    for rid in CATALOG:
        row = rows[rid]
        lines.append('| ' + ' | '.join(row[key] for key in ('client', 'provider_scope', 'auth_mode',
                     'decision_status', 'implementation_status', 'live_status', 'full_r3')) + ' |')
    lines += ['', '## C-003 boundary and blockers', '',
              'Claude subscription, Codex ChatGPT and OpenCode OAuth require **opt-in per area** and '
              'a **closed, reviewed domain allowlist for that integration/provider**. TLS passthrough inserts no key. '
              'The token lives in the area and is assumed compromisable; its account permissions are not limited '
              'by the area. Opaque TLS cannot distinguish a foreign account/token or stop project data leaving '
              'through allowed provider domains. **Full R3 is not met under this accepted exception.**', '',
              'No actual provider domain list, account scopes or disable/delete revocation procedure is supplied '
              'by this inventory. OpenCode OAuth provider selection is also unreviewed. Missing reviewed domains '
              'and revocation block implementation readiness; per-area enforcement, exact client compatibility '
              'and live evidence are unverified. S5 must measure the provider-domain exfiltration consequence and '
              'record it as C-003, never as a full R3 pass. All other R3 tests remain unchanged.', '',
              'API-key modes retain typed host-gateway custody and insertion. The OAuth exception is not a '
              'fallback for a typed rejection, another client, another provider, GitHub API or an unlisted integration. '
              'Resolving same-host OAuth/typed routing requires review; this report does not create a route.', '']
    for rid in CATALOG:
        row = rows[rid]
        lines += ['## ' + rid, '', row['basis']['text'], '', '**Decision constraints:**', '']
        for key in CONTRACTS[CATALOG[rid][3]]:
            value = row['contract'][key]
            rendered = ', '.join(value) if isinstance(value, list) else value
            lines += ['- `' + key + '`: `' + (rendered or 'none') + '`.']
        lines += ['', '**Open implementation/evidence gaps:**', '']
        for key in GAPS[CATALOG[rid][3]]:
            value = row['known_gaps'][key]
            lines += ['- `' + key + '`: `' + value + '`.']
        lines += ['', 'Sources: ' + ', '.join('[' + ref + '](' + source_url(sources[ref]) + ')'
                  for ref in row['basis']['refs']) + '.', '']
    lines += ['## Validation limits', '',
              'The validator checks a versioned closed catalog, constraints, provenance and contradictions. '
              'It does not implement enforcement, inspect accounts, verify cited prose or establish gate evidence. '
              'New domains, scopes, revocation evidence or implementation/live claims require a reviewed version update. '
              'The original historical report command remains unchanged.', '']
    return '\n'.join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('validate', 'report'))
    parser.add_argument('--decisions', type=Path, default=HERE / 'current-decisions.json')
    parser.add_argument('--format', choices=('markdown', 'json'), default='markdown')
    args = parser.parse_args(argv)
    try:
        document = validate(load_json(args.decisions))
        if args.command == 'validate':
            print(json.dumps({'valid': True, 'layer': document['layer'], 'integrations': len(CATALOG),
                              'accepted': 6, 'implementation_blocked': 6, 'unsupported': 1,
                              'live_verified': 0, 'c003_full_r3_not_met': 3,
                              'gates': document['gate_status']}, sort_keys=True))
        elif args.format == 'json':
            print(json.dumps(document, indent=2, ensure_ascii=False, sort_keys=True))
        else:
            print(markdown_report(document), end='')
        return 0
    except (Invalid, OSError, ValueError) as error:
        print('invalid: ' + str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
