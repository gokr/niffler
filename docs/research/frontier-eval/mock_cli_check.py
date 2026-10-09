"""Run the real pinned CLI against a local fake OpenAI provider. No paid calls."""
import http.server
import json
import os
import subprocess
import threading
from pathlib import Path
from usage_mapping import extract_usage

calls = []
class Mock(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args): pass
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        calls.append(request)
        usage = {'prompt_tokens': 100, 'completion_tokens': 20, 'total_tokens': 120,
                 'prompt_tokens_details': {'cached_tokens': 80}}
        if request.get('stream'):
            frames = [
                {'id': 'mock', 'object': 'chat.completion.chunk', 'model': request['model'],
                 'choices': [{'index': 0, 'delta': {'role': 'assistant', 'content': 'Mock response.'}, 'finish_reason': None}]},
                {'id': 'mock', 'object': 'chat.completion.chunk', 'model': request['model'],
                 'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}], 'usage': usage},
            ]
            body = ''.join('data: '+json.dumps(f)+'\n\n' for f in frames).encode()+b'data: [DONE]\n\n'
            content_type = 'text/event-stream'
        else:
            body = json.dumps({'id': 'mock', 'object': 'chat.completion', 'model': request['model'],
                'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': 'Mock response.'},
                             'finish_reason': 'stop'}], 'usage': usage}).encode()
            content_type = 'application/json'
        self.send_response(200); self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

server = http.server.HTTPServer(('127.0.0.1', 0), Mock)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = dict(os.environ, NIF_ROOT='/work/harness', NIF_NATS_SPAWN='1',
    NIF_AUTO_APPROVE='1', NIF_OPENAI_API_KEY='mock-not-a-secret',
    NIF_OPENAI_BASE_URL=f'http://127.0.0.1:{server.server_port}/v1',
    NIF_OPENAI_MODEL='accounts/fireworks/models/kimi-k3')
try:
    result = subprocess.run(['/work/harness/var/bin/cli', 'run', '--root', '/work/harness',
        '--cwd', '/work', '--approvals', 'auto', 'Reply with a short greeting.'],
        env=env, text=True, capture_output=True, timeout=90)
    Path('/work/mock-cli.ndjson').write_text(result.stdout)
    Path('/work/mock-cli.stderr').write_text(result.stderr)
    if result.returncode:
        raise RuntimeError(f'CLI exit {result.returncode}: {result.stderr[-2000:]} {result.stdout[-2000:]}')
    usage = extract_usage(result.stdout.splitlines())
    assert usage['n_input_tokens'] == 100, usage
    assert usage['n_output_tokens'] == 20, usage
    assert usage['n_cache_tokens'] == 80, usage
    assert usage['metadata']['usage_complete'], usage
    assert len(calls) == 1, len(calls)
    print('REAL CLI MOCK PASSED: input=100, output=20, cached=80, one provider request')
finally:
    server.shutdown(); server.server_close()
