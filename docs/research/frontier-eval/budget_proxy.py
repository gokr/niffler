"""Pilot-only OpenAI proxy: reserve spend before forwarding; never retry upstream.
Run on the runtime host, outside task containers. One serial lane and ledger
across candidate/control trials. No credentials are stored: Runta injects the
Fireworks credential at egress; upstream receives only its stub.

Conservative pricing: $3/M input, $15/M output, cached input charged as fresh.
Prompt reservations use the model's entire 1,048,576-token context window,
not a guessed bytes-to-tokens conversion. Output is bounded at 16,384 tokens
so one request cannot outrun the pilot's $10 cap; 4,096 was too tight for
Kimi K3's reasoning phase (observed: 4,096 reasoning tokens, zero content).
This cap is a pilot constraint and must be disclosed in any comparison.
"""
import argparse
import http.server
import json
import pathlib
import threading
import urllib.request

import os
import math

OUTPUT_CAP = 16_384
INPUT_RATE = 3 / 1_000_000
OUTPUT_RATE = 15 / 1_000_000
LOCK = threading.Lock()


def text_only(content):
    """str/None content, or a parts array of pure text parts (pi sends that)."""
    if isinstance(content, (str, type(None))):
        return True
    if isinstance(content, list):
        return all(isinstance(p, dict) and isinstance(p.get('text'), str)
                   and not any(k in p for k in ('image_url', 'input_audio'))
                   for p in content)
    return False


def reservation(body):
    request = json.loads(body)
    if request.get('model') != 'accounts/fireworks/models/kimi-k3':
        raise ValueError('Only standard-tier Kimi K3 is authorized')
    if request.get('n', 1) != 1 or request.get('service_tier') not in (None, 'standard'):
        raise ValueError('Multiple completions and premium tiers are not authorized')
    for message in request.get('messages', []):
        if not text_only(message.get('content')):
            raise ValueError('Pilot guard supports text only; image pricing is not bounded')
    if request.get('stream'):
        request.setdefault('stream_options', {})['include_usage'] = True
    output = min(int(request.get('max_completion_tokens', request.get('max_tokens', OUTPUT_CAP))), OUTPUT_CAP)
    if output <= 0:
        raise ValueError('invalid output limit')
    request.pop('max_completion_tokens', None)
    request['max_tokens'] = output
    # Reserve the full provider context window: no tokenizer approximation
    # can authorize spending past the cap. This intentionally holds ~$3.21
    # until usage arrives, even for a tiny request. Unsupported routes refuse.
    return request, 1_048_576 * INPUT_RATE + output * OUTPUT_RATE


def usage_from_response(raw):
    try:
        return json.loads(raw).get('usage')
    except (ValueError, UnicodeError):
        usage = None
        for line in raw.splitlines():
            if not line.startswith(b'data: '):
                continue
            try:
                item = json.loads(line[6:])
            except ValueError:
                continue
            if item.get('usage'):
                usage = item['usage']
        return usage


def measured_cost(usage):
    if not isinstance(usage, dict):
        return None
    if 'prompt_tokens' not in usage or 'completion_tokens' not in usage:
        return None
    p, c = usage['prompt_tokens'], usage['completion_tokens']
    if not isinstance(p, int) or not isinstance(c, int) or min(p, c) < 0:
        return None
    return p * INPUT_RATE + c * OUTPUT_RATE


class Ledger:
    def __init__(self, path, limit):
        if not math.isfinite(limit) or limit <= 0:
            raise ValueError('Budget must be positive and finite')
        self.path, self.limit = pathlib.Path(path), limit
        self.records = []
        if self.path.exists():
            self.records = [json.loads(s) for s in self.path.read_text().splitlines() if s]
        self.spent = sum(r.get('charge', 0) for r in self.records)

    def append(self, record):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open('a') as f:
            f.write(json.dumps(record) + '\n')
            f.flush()
            os.fsync(f.fileno())
        self.records.append(record)

    def reserve(self, charge):
        if self.spent + charge > self.limit:
            return False
        self.append({'kind': 'reserve', 'charge': charge})
        self.spent += charge
        return True

    def settle(self, reserved, usage):
        actual = measured_cost(usage)
        # Missing usage stays charged at the reservation. Never pretend zero.
        if actual is None:
            self.append({'kind': 'missing-usage', 'charge': 0})
            return
        refund = max(0, reserved - actual)
        extra = max(0, actual - reserved)
        self.append({'kind': 'usage', 'usage': usage, 'charge': extra - refund,
                     'reserved': reserved, 'conservative_cost': actual})
        self.spent += extra - refund
        if extra:
            self.limit = 0  # accounting bound violated: refuse all later calls


def handler(ledger, upstream):
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def do_POST(self):
            if self.path != '/v1/chat/completions':
                self.send_error(404)
                return
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= 4_000_000:
                self.send_error(413)
                return
            body = self.rfile.read(size)
            try:
                request, reserve = reservation(body)
            except (ValueError, TypeError) as exc:
                print('guard rejected request:', exc, flush=True)
                self.send_error(400, str(exc))
                return
            with LOCK:
                if not ledger.reserve(reserve):
                    self.send_error(429, 'pilot budget exhausted')
                    return
                try:
                    req = urllib.request.Request(upstream,
                        data=json.dumps(request).encode(),
                        headers={'Content-Type': 'application/json',
                                 'Authorization': 'Bearer runta-secret-stub'})
                    with urllib.request.urlopen(req, timeout=180) as response:
                        raw = response.read(16_000_001)
                        if len(raw) > 16_000_000:
                            raise ValueError('response too large')
                        content_type = response.headers.get('Content-Type', 'application/json')
                    usage = usage_from_response(raw)
                    ledger.settle(reserve, usage)
                    self.send_response(200)
                    self.send_header('Content-Type', content_type)
                    self.send_header('Content-Length', str(len(raw)))
                    self.end_headers()
                    self.wfile.write(raw)
                except Exception:
                    # Request may have incurred upstream cost. Keep reservation.
                    ledger.append({'kind': 'upstream-failure', 'charge': 0})
                    self.send_error(502, 'upstream failed; reservation retained')
    return Handler


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--ledger', required=True)
    parser.add_argument('--limit', type=float, default=10.0)
    parser.add_argument('--port', type=int, default=19040)
    parser.add_argument('--bind', default='127.0.0.1')
    parser.add_argument('--upstream', default='https://api.fireworks.ai/inference/v1/chat/completions')
    args = parser.parse_args()
    http.server.HTTPServer((args.bind, args.port),
        handler(Ledger(args.ledger, args.limit), args.upstream)).serve_forever()
