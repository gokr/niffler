"""One budget-guarded Fireworks smoke request, at most 16 output tokens.
No benchmark tasks. Save usage only, never credential values.
"""
import http.server
import json
import pathlib
import threading
import urllib.error
import urllib.request
from budget_proxy import Ledger, handler

ledger = Ledger('/work/pilot-spend.jsonl', 10.0)
proxy = http.server.HTTPServer(('127.0.0.1', 19040), handler(ledger,
    'https://api.fireworks.ai/inference/v1/chat/completions'))
threading.Thread(target=proxy.serve_forever, daemon=True).start()
try:
    request = {'model': 'accounts/fireworks/models/kimi-k3', 'max_tokens': 16,
               'messages': [{'role': 'user', 'content': 'Reply with OK.'}], 'stream': False}
    try:
        with urllib.request.urlopen(urllib.request.Request(
            'http://127.0.0.1:19040/v1/chat/completions',
            data=json.dumps(request).encode(), headers={'Content-Type':'application/json'}), timeout=200) as response:
            result = json.load(response)
        usage = result.get('usage')
        pathlib.Path('/work/fireworks-smoke-usage.json').write_text(json.dumps(usage))
        assert usage and isinstance(usage.get('prompt_tokens'), int), 'Provider usage missing'
        print('FIREWORKS CONNECTIVITY PASSED; usage:', json.dumps(usage))
        print('Conservative ledger charge USD:', ledger.spent)
    except urllib.error.HTTPError as error:
        print('CONNECTIVITY FAILED:', error.code, error.read().decode()[:300])
        print('Reservation retained USD:', ledger.spent)
        raise SystemExit(1)
finally:
    proxy.shutdown(); proxy.server_close()
