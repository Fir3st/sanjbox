#!/usr/bin/env python3
"""Offline exact-byte projection of fixed immutable producer evidence; never runs probes.
Default checks committed fixtures. --write creates/updates only these two owned fixtures.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path

OWN = Path(__file__).resolve().parents[1]
REPO = OWN.parents[2]
EVIDENCE = REPO / 'spikes/s3-pf/provenance-validation/20261106-host-arm64-ba33939'
CASES = ('tcp-v4', 'tcp-v6', 'udp-v4', 'udp-v6', 'udp-adversarial', 'tcp-adversarial',
         'contact-limit', 'interrupted-prefix', 'refused-connect')

def project():
    manifest = json.loads((EVIDENCE / 'manifest.json').read_bytes())
    hashes, vectors = {}, {}
    def supplied(path):
        data = path.read_bytes()
        relative = str(path.relative_to(EVIDENCE))
        digest = hashlib.sha256(data).hexdigest()
        assert manifest[relative] == digest, relative
        hashes[relative] = digest
        return data
    for name in CASES:
        sources = []
        for directory in sorted((EVIDENCE / 'loopback' / name).glob('sanjbox-network-*')):
            text = supplied(directory / 'events.jsonl').decode('utf-8')
            rows = [json.loads(line) for line in text.splitlines()]
            artifacts = []
            # Fixed allowlist only; never follow rawFile or paths from the evidence itself.
            for basename in ['expect.json', 'probe.json', 'sent.bin'] + [f'received-{i}.bin' for i in range(1, 17)]:
                path = directory / basename
                if path.exists():
                    data = supplied(path)
                    artifacts.append(dict(name=basename, count=len(data), sha256=hashlib.sha256(data).hexdigest(), base64=base64.b64encode(data).decode('ascii')))
            sources.append(dict(id=rows[0]['role'], format='sanjboxNetworkProvenanceV1', origin='importedMeasured', text=text, artifacts=artifacts))
        first = json.loads(sources[0]['text'].splitlines()[0])
        envelope = dict(schemaVersion=1, runID=first['runID'], runStartUTC=first['timestamp']['utc'], sources=sources, endpoints=[], bindings=[])
        if len(sources) == 2:
            sender = next(s for s in sources if s['id'] == 'sender')
            connected = next(r for r in map(json.loads, sender['text'].splitlines()) if r['kind'] == 'connected')
            scenario = f"NET-10.{first['family']}.loopback.hostToZone"
            envelope['endpoints'] = [dict(id='exact', scenarioID=scenario, transport=first['transport'], bind=connected['remote'], local=connected['remote'], remote=connected['local'])]
            envelope['bindings'] = [dict(flowID=first['flowID'], scenarioID=scenario, stage='test', endpointID='exact', network=dict(senderSourceID='sender', receiverSourceID='receiver', contactID=1))]
        vectors[name] = envelope
    provenance = dict(kind='exact historical producer bytes; envelopes are offline projections, not new measurements',
        producerSourceRevision='ba339392df85f0798ba66b9f4842735558467646', consumerBaseRevision='dd058d3f4e758ed7fdef7dc64eba1c9a34a66967',
        evidenceDirectory=str(EVIDENCE.relative_to(REPO)),
        sourceManifestSHA256=hashlib.sha256((EVIDENCE/'manifest.json').read_bytes()).hexdigest(),
        note='Four positives are actual signed C1/common processes. Adversarial input traffic was synthetic Python traffic recorded by actual common receiver. No matrix or external clock calibration fabricated. Mutations in tests are synthetic.',
        files=hashes)
    return vectors, provenance

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true')
    args = parser.parse_args()
    outputs = project()
    for name, obj in zip(('network-producer-vectors.json', 'network-producer-provenance.json'), outputs):
        data = (json.dumps(obj, indent=2, sort_keys=True) + '\n').encode()
        destination = OWN / 'Tests/IngressKitTests/Fixtures' / name
        if args.write:
            destination.write_bytes(data)
        else:
            assert destination.read_bytes() == data, f'{name}: exact projection differs'
        print(f'{name}: {len(data)} bytes SHA256 {hashlib.sha256(data).hexdigest()}')
    print(f'PASS: {len(outputs[0])} historical cases, {len(outputs[1]["files"])} exact files verified; no sockets')

if __name__ == '__main__':
    main()
