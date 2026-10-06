"""Strict mapping of Niffler cli run NDJSON into Harbor/Pier counters.

The authoritative result is counted once. Event copies are never summed.
Absent usage/cache values remain None; incomplete usage is reported explicitly.
Descendant usage is excluded by Niffler; the proxy ledger covers all requests.
"""
import json


def extract_usage(lines):
    finals = []
    for line in lines:
        try:
            frame = json.loads(line)
        except (ValueError, TypeError):
            continue
        if frame.get('type') == 'result':
            finals.append(frame)
    if len(finals) != 1:
        raise ValueError('Expected exactly one authoritative result frame')
    usage = finals[0].get('usage') or {}
    reported = usage.get('usageReported', False)
    complete = reported and usage.get('responsesWithUsage') == usage.get('providerResponses')
    values = {}
    for source, dest in (('promptTokens', 'n_input_tokens'),
                         ('completionTokens', 'n_output_tokens'),
                         ('cacheReadTokens', 'n_cache_tokens')):
        value = usage.get(source) if reported else None
        if value is not None and (not isinstance(value, int) or isinstance(value, bool) or value < 0):
            raise ValueError('Invalid usage counter: ' + source)
        values[dest] = value
    if values['n_cache_tokens'] is not None and values['n_input_tokens'] is not None:
        if values['n_cache_tokens'] > values['n_input_tokens']:
            raise ValueError('Cache input exceeds total input')
    values['metadata'] = {
        'usage_complete': complete,
        'descendants_excluded': usage.get('descendantsExcluded'),
        'provider_responses': usage.get('providerResponses'),
        'responses_with_usage': usage.get('responsesWithUsage'),
        'turn_id': finals[0].get('turnId'),
        'outcome': finals[0].get('outcome'),
        'turn_error': (finals[0].get('turnError') or None),
    }
    return values
