"""Real Niffler -> host budget proxy -> fake provider, in isolated Docker.
No model spend. Internal Docker network blocks Internet egress at the bridge;
no Docker socket or host filesystem is exposed to the agent container.
"""
import http.server
import json
import pathlib
import subprocess
import tempfile
import threading
import urllib.request
from budget_proxy import Ledger, handler
from usage_mapping import extract_usage

NETWORK = 'fh-niffler-mock-internal'

def command(*args):
    return subprocess.check_output(args, text=True).strip()

class Mock(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args): pass
    def do_POST(self):
        req = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        usage = {'prompt_tokens': 100, 'completion_tokens': 20, 'total_tokens': 120,
                 'prompt_tokens_details': {'cached_tokens': 80}}
        if req.get('stream'):
            frames = [
                {'id': 'mock', 'object': 'chat.completion.chunk', 'model': req['model'],
                 'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': 'Mock response.'}, 'finish_reason': None}]},
                {'id': 'mock', 'object': 'chat.completion.chunk', 'model': req['model'],
                 'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}], 'usage': usage}]
            body = ''.join('data: '+json.dumps(f)+'\n\n' for f in frames).encode()+b'data: [DONE]\n\n'
            ct = 'text/event-stream'
        else:
            body = json.dumps({'id': 'mock', 'object': 'chat.completion', 'model': req['model'],
                'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'Mock response.'},
                             'finish_reason': 'stop'}], 'usage': usage}).encode()
            ct = 'application/json'
        self.send_response(200); self.send_header('Content-Type', ct)
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

upstream = http.server.HTTPServer(('127.0.0.1', 0), Mock)
threading.Thread(target=upstream.serve_forever, daemon=True).start()
try:
    command('docker', 'network', 'create', '--internal', NETWORK)
    gateway = json.loads(command('docker', 'network', 'inspect', NETWORK))[0]['IPAM']['Config'][0]['Gateway']
    with tempfile.TemporaryDirectory(dir='/work') as directory:
        ledger = Ledger(pathlib.Path(directory)/'ledger.jsonl', 10.0)
        proxy = http.server.HTTPServer((gateway, 19040), handler(ledger,
            f'http://127.0.0.1:{upstream.server_port}/v1/chat/completions'))
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        script = '''set -eu
mkdir -p /opt/niffler040 /logs/agent
tar -xzf /bundle.tar.gz -C /opt/niffler040
export NIF_ROOT=/opt/niffler040 NIF_NATS_SPAWN=1 NIF_AUTO_APPROVE=1
export NIF_OPENAI_API_KEY=runta-secret-stub NIF_OPENAI_MODEL=accounts/fireworks/models/kimi-k3
/opt/niffler040/var/bin/cli run --root /opt/niffler040 --cwd /app --approvals auto 'Reply with a greeting.' > /logs/agent/mock.ndjson 2>/logs/agent/mock.stderr || { cat /logs/agent/mock.stderr; exit 1; }
cat /logs/agent/mock.ndjson
'''
        result = subprocess.run(['docker','run','--rm','--network',NETWORK,
            '--cap-drop','NET_ADMIN','--cap-drop','NET_RAW',
            '-e',f'NIF_OPENAI_BASE_URL=http://{gateway}:19040/v1',
            '-v','/work/niffler040.tar.gz:/bundle.tar.gz:ro',
            '-w','/app','ubuntu:24.04','bash','-lc',script],
            capture_output=True,text=True,timeout=120)
        pathlib.Path('/work/container-mock.ndjson').write_text(result.stdout)
        pathlib.Path('/work/container-mock.stderr').write_text(result.stderr)
        assert result.returncode == 0, result.stdout[-1500:]+result.stderr[-1500:]
        values = extract_usage(result.stdout.splitlines())
        assert values['n_input_tokens'] == 100, values
        assert values['n_cache_tokens'] == 80, values
        assert values['n_output_tokens'] == 20, values
        assert abs(ledger.spent - .0006) < 1e-9, ledger.spent
        # A direct-provider connection must be impossible from the same network.
        denied = subprocess.run(['docker','run','--rm','--network',NETWORK,
            '--cap-drop','NET_ADMIN','--cap-drop','NET_RAW','ubuntu:24.04',
            'bash','-lc','timeout 3 bash -c "echo >/dev/tcp/1.1.1.1/443"'],
            capture_output=True,timeout=10)
        assert denied.returncode != 0, 'Internal network leaked Internet access'
        print('CONTAINER MOCK PASSED: real CLI + guarded proxy + usage mapping; direct Internet blocked')
        proxy.shutdown(); proxy.server_close()
finally:
    upstream.shutdown(); upstream.server_close()
    subprocess.run(['docker','network','rm',NETWORK],capture_output=True)
