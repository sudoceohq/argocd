#!/usr/bin/env python3
"""Live qualification only. Captured Envoy secret responses never reach disk/logs."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
CONTEXT = None
CLUSTER = None

def command(*args):
    return (args[0], '--context', CONTEXT, *args[1:]) if args[0] in ('kubectl', 'istioctl') else args

def run(*args):
    result = subprocess.run(command(*args), capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed (exit {result.returncode}); no captured payload logged')
    return result.stdout

def chain_from_response(response):
    for secret in response.get('dynamicActiveSecrets', []):
        chain = secret.get('secret', {}).get('tlsCertificate', {}).get('certificateChain', {})
        if 'inlineBytes' in chain:
            return base64.b64decode(chain['inlineBytes'], validate=True).decode('ascii')
        if 'inlineString' in chain:
            return chain['inlineString']
    raise ValueError('No active workload certificate chain')

def certificate(pod, trusted_root):
    # istioctl may return secret fields. Extract ONLY public certificate chain in memory.
    payload = run('istioctl', 'proxy-config', 'secret', pod, '-n', 'mesh-test', '-o', 'json')
    chain = chain_from_response(json.loads(payload))
    del payload
    certs = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', chain, re.S)
    if len(certs) < 2:
        raise ValueError('Workload must return leaf and issuing intermediate')
    with tempfile.TemporaryDirectory() as directory:
        files = {name: Path(directory) / name for name in ('root.pem', 'leaf.pem', 'chain.pem')}
        files['root.pem'].write_text(trusted_root)
        files['leaf.pem'].write_text(certs[0])
        files['chain.pem'].write_text('\n'.join(certs[1:]))
        run('openssl', 'verify', '-purpose', 'sslclient', '-CAfile', str(files['root.pem']), '-untrusted', str(files['chain.pem']), str(files['leaf.pem']))
        run('openssl', 'x509', '-in', str(files['leaf.pem']), '-checkend', '60', '-noout')
        text = run('openssl', 'x509', '-in', str(files['leaf.pem']), '-text', '-noout')
        identities = re.findall(r'URI:([^,\s]+)', text)
        if identities != [f"spiffe://{CLUSTER['trustDomain']}/ns/mesh-test/sa/client"]:
            raise ValueError('Unexpected workload SPIFFE identities')
        serial = run('openssl', 'x509', '-in', str(files['leaf.pem']), '-serial', '-noout').strip()
        validity = run('openssl', 'x509', '-in', str(files['leaf.pem']), '-dates', '-noout')
        return {'serial': serial, 'validity': validity}

def traffic(permissive):
    command = ('--', 'curl', '--fail', '--silent', '--show-error', '--max-time', '10', '--write-out', '%{http_code}', 'http://server.mesh-test.svc/')
    run('kubectl', '-n', 'mesh-test', 'exec', 'deploy/client', '-c', 'client', *command)
    plaintext = subprocess.run(command('kubectl', '-n', 'mesh-test', 'exec', 'deploy/plaintext', '-c', 'plaintext', *command), capture_output=True, text=True)
    if (plaintext.returncode == 0) != permissive:
        raise ValueError('Plaintext result does not match requested PERMISSIVE/STRICT phase')
    if not permissive and not plaintext.stdout.endswith('000'):
        raise ValueError('Plaintext received an HTTP response; require transport rejection, not just application denial')
    if not permissive:
        policy = json.loads(run('kubectl', '-n', 'mesh-test', 'get', 'peerauthentication', 'strict', '-o', 'json'))
        if policy.get('spec', {}).get('mtls', {}).get('mode') != 'STRICT':
            raise ValueError('STRICT PeerAuthentication is absent')
    # Direct requests bypassing the HTTP application prove the sidecar reports mTLS.
    stats = run('kubectl', '-n', 'mesh-test', 'exec', 'deploy/server', '-c', 'istio-proxy', '--', 'pilot-agent', 'request', 'GET', 'stats/prometheus')
    if not any('istio_requests_total{' in line and 'connection_security_policy="mutual_tls"' in line and 'response_code="200"' in line and float(line.rsplit(' ', 1)[-1]) > 0 for line in stats.splitlines()):
        raise ValueError('No successful mutual_tls traffic counter')

def self_test():
    pem = '-----BEGIN CERTIFICATE-----\npublic\n-----END CERTIFICATE-----'
    response = {'dynamicActiveSecrets': [{'secret': {'tlsCertificate': {'certificateChain': {'inlineBytes': base64.b64encode(pem.encode()).decode()}, 'privateKey': {'inlineBytes': 'NEVER_EXTRACT'}}}}]}
    assert chain_from_response(response) == pem
    response['dynamicActiveSecrets'][0]['secret']['tlsCertificate']['certificateChain'] = {'inlineString': pem}
    assert chain_from_response(response) == pem
    try:
        chain_from_response({'dynamicActiveSecrets': []})
    except ValueError:
        pass
    else:
        raise AssertionError('Missing workload chain must fail')
    print('Certificate response parser: passed')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cluster', default=os.environ.get('THRIFTY_CLUSTER', 'management'))
    parser.add_argument('--context', default=os.environ.get('KUBE_CONTEXT'))
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--permissive', action='store_true', help='Before enabling STRICT, plaintext must work')
    parser.add_argument('--renewal', action='store_true', help='Observe natural rotation for up to 70 minutes without restarting pods')
    parser.add_argument('--require-renewal', action='store_true', help='Require fresh local proof before promoting STRICT')
    args = parser.parse_args()
    if args.self_test:
        self_test(); return
    global CLUSTER, CONTEXT
    if not re.fullmatch(r'[a-z][a-z0-9-]*', args.cluster):
        raise ValueError('Invalid cluster ID')
    config = ROOT / 'clusters' / args.cluster / 'cluster.yaml'
    CLUSTER = json.loads(run('ruby', '-ryaml', '-rjson', '-e', 'puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))', str(config)))['cluster']
    if not CLUSTER['enabled'] or not CLUSTER['prepared']:
        raise ValueError('Cluster is disabled or external prerequisites are incomplete')
    CONTEXT = CLUSTER.get('context') or args.context
    if not CONTEXT:
        raise ValueError('Set --context explicitly or cluster.context')
    server = run('kubectl', 'config', 'view', '--minify', '-o', 'jsonpath={.clusters[0].cluster.server}').strip()
    if server != CLUSTER.get('operatorServer', CLUSTER['server']):
        raise ValueError('Context API does not match configured cluster')
    root = json.loads(run('kubectl', '-n', 'cert-manager', 'get', 'configmap', 'istio-root-ca', '-o', 'json'))['data']['ca.pem']
    pods = json.loads(run('kubectl', '-n', 'mesh-test', 'get', 'pods', '-l', 'app=client', '-o', 'json'))['items']
    if len(pods) != 1:
        raise ValueError('Exactly one qualification client is required')
    pod = pods[0]['metadata']['name']; uid = pods[0]['metadata']['uid']
    if 'istio-proxy' not in [c['name'] for c in pods[0]['spec']['containers']]:
        raise ValueError('Qualification client is not enrolled')
    namespaces = {n['metadata']['name']: n for n in json.loads(run('kubectl', 'get', 'namespaces', '-o', 'json'))['items']}
    for namespace in ('kube-system', 'longhorn-system', 'vault', 'crossplane-system', 'cert-manager', 'argocd', 'istio-system'):
        labels = namespaces.get(namespace, {}).get('metadata', {}).get('labels', {})
        if labels.get('istio-injection') == 'enabled' or labels.get('istio.io/dataplane-mode') == 'ambient' or 'istio.io/rev' in labels:
            raise ValueError(f'{namespace} must remain excluded from enrollment')
    denied = subprocess.run(command('kubectl', 'auth', 'can-i', 'create', 'certificaterequests.cert-manager.io', '-n', 'istio-system', '--as=system:serviceaccount:mesh-test:client'), capture_output=True, text=True)
    if denied.returncode != 1 or denied.stdout.strip() != 'no':
        raise ValueError('Workload can request identities directly, or RBAC check failed')
    first = certificate(pod, root); traffic(args.permissive)
    root_hash = hashlib.sha256(root.encode()).hexdigest()
    evidence_path = ROOT / '.evidence' / args.cluster / 'renewal.json'
    if args.renewal:
        deadline = time.monotonic() + 4200
        while time.monotonic() < deadline:
            time.sleep(30)
            current = json.loads(run('kubectl', '-n', 'mesh-test', 'get', 'pod', pod, '-o', 'json'))
            if current['metadata']['uid'] != uid:
                raise ValueError('Pod was replaced; cannot prove automatic renewal')
            next_cert = certificate(pod, root)
            if next_cert['serial'] != first['serial'] and next_cert['validity'] != first['validity']:
                traffic(args.permissive)
                evidence_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                evidence_path.write_text(json.dumps({'cluster': args.cluster, 'server': server, 'observedAt': time.time(), 'podUid': uid, 'rootSha256': root_hash, 'before': first, 'after': next_cert}, indent=2)+'\n')
                break
        else:
            raise ValueError('No natural renewal observed within 70 minutes')
    if args.require_renewal:
        evidence = json.loads(evidence_path.read_text())
        if not (evidence['cluster']==args.cluster and evidence['server']==server and 0 <= time.time() - evidence['observedAt'] < 7200 and evidence['podUid'] == uid and evidence['rootSha256'] == root_hash and evidence['before']['serial'] != evidence['after']['serial']):
            raise ValueError('Renewal proof is stale or belongs to another pod/root')
    print('Verified Vault chain, SPIFFE identity, mTLS traffic, namespace exclusions and plaintext ' + ('baseline' if args.permissive else 'rejection'))

if __name__ == '__main__':
    main()
