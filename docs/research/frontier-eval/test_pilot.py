"""Credential-free unit/integration checks for pilot accounting."""
import http.server
import importlib.util
import json
import pathlib
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

spec = importlib.util.spec_from_file_location('budget_proxy', pathlib.Path(__file__).with_name('budget_proxy.py'))
assert spec is not None and spec.loader is not None
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


from usage_mapping import extract_usage

class Tests(unittest.TestCase):
    def test_authoritative_usage_is_not_double_counted(self):
        u = {'usageReported': True, 'promptTokens': 100, 'completionTokens': 20,
             'cacheReadTokens': 80, 'providerResponses': 2, 'responsesWithUsage': 2,
             'descendantsExcluded': True}
        values = extract_usage([json.dumps({'type': 'event', 'usage': u}),
                                json.dumps({'type': 'result', 'usage': u, 'outcome': 'error', 'turnError': 'cut'})])
        self.assertEqual(values['n_input_tokens'], 100)
        self.assertEqual(values['n_cache_tokens'], 80)
        self.assertTrue(values['metadata']['usage_complete'])
        self.assertEqual(values['metadata']['outcome'], 'error')

    def test_absent_usage_stays_unknown(self):
        values = extract_usage([json.dumps({'type': 'result', 'usage': {'usageReported': False}})])
        self.assertIsNone(values['n_input_tokens'])
        self.assertIsNone(values['n_cache_tokens'])

    def test_duplicate_final_refused(self):
        with self.assertRaises(ValueError):
            extract_usage(['{"type":"result"}', '{"type":"result"}'])

    def test_reservation_caps_output_and_rejects_other_models(self):
        request, cost = p.reservation(json.dumps({'model': 'accounts/fireworks/models/kimi-k3',
            'messages': [{'role': 'user', 'content': 'hello'}], 'max_tokens': 100000}).encode())
        self.assertEqual(request['max_tokens'], 16384)
        self.assertGreater(cost, 3.39)
        self.assertLess(cost, 3.40)
        with self.assertRaises(ValueError):
            p.reservation(b'{"model":"expensive-other-model"}')
        with self.assertRaises(ValueError):
            p.reservation(json.dumps({'model': 'accounts/fireworks/models/kimi-k3',
                'messages': [{'content': [{'type': 'image_url'}]}]}).encode())

    def test_text_parts_accepted_but_media_refused(self):
        parts = {'model': 'accounts/fireworks/models/kimi-k3', 'messages': [
            {'role': 'user', 'content': [{'type': 'text', 'text': 'hello'}]}]}
        p.reservation(json.dumps(parts).encode())
        parts['messages'][0]['content'].append({'type': 'image_url', 'image_url': {}})
        with self.assertRaises(ValueError):
            p.reservation(json.dumps(parts).encode())

    def test_stream_usage(self):
        raw = b'data: {"usage":null}\n\ndata: {"usage":{"prompt_tokens":100,"completion_tokens":20,"prompt_tokens_details":{"cached_tokens":80}}}\n\ndata: [DONE]\n'
        u = p.usage_from_response(raw)
        self.assertEqual(u['prompt_tokens_details']['cached_tokens'], 80)
        self.assertAlmostEqual(p.measured_cost(u), .0006)

    def test_reservations_persist_and_missing_usage_is_not_free(self):
        with tempfile.TemporaryDirectory(dir=pathlib.Path(__file__).parent) as d:
            f = pathlib.Path(d) / 'ledger.jsonl'
            ledger = p.Ledger(f, .1)
            self.assertTrue(ledger.reserve(.08))
            ledger.settle(.08, None)
            self.assertFalse(ledger.reserve(.03))
            self.assertAlmostEqual(p.Ledger(f, .1).spent, .08)

    def test_actual_usage_refunds_unused_reservation(self):
        with tempfile.TemporaryDirectory(dir=pathlib.Path(__file__).parent) as d:
            ledger = p.Ledger(pathlib.Path(d) / 'ledger', .1)
            ledger.reserve(.08)
            ledger.settle(.08, {'prompt_tokens': 100, 'completion_tokens': 20})
            self.assertAlmostEqual(ledger.spent, .0006)

    def test_budget_denial_never_calls_upstream(self):
        calls = []
        class Mock(http.server.BaseHTTPRequestHandler):
            def log_message(self, format, *args): pass
            def do_POST(self):
                calls.append(1)
                self.rfile.read(int(self.headers['Content-Length']))
                body = json.dumps({'usage': {'prompt_tokens': 100, 'completion_tokens': 20}}).encode()
                self.send_response(200); self.end_headers(); self.wfile.write(body)
        upstream = http.server.HTTPServer(('127.0.0.1', 0), Mock)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        with tempfile.TemporaryDirectory(dir=pathlib.Path(__file__).parent) as d:
            ledger = p.Ledger(pathlib.Path(d) / 'ledger', .001)
            proxy = http.server.HTTPServer(('127.0.0.1', 0), p.handler(ledger,
                f'http://127.0.0.1:{upstream.server_port}/v1/chat/completions'))
            threading.Thread(target=proxy.serve_forever, daemon=True).start()
            body = json.dumps({'model': 'accounts/fireworks/models/kimi-k3', 'messages': [{'role': 'user', 'content': 'hello'}]}).encode()
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(urllib.request.Request(
                    f'http://127.0.0.1:{proxy.server_port}/v1/chat/completions', data=body))
            self.assertEqual(caught.exception.code, 429)
            self.assertEqual(calls, [])
            proxy.shutdown(); proxy.server_close()
        upstream.shutdown(); upstream.server_close()


if __name__ == '__main__':
    unittest.main()
