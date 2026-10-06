"""Check complete, paired runs without exposing request contents."""
from pathlib import Path
import json, hashlib, sys

root = Path(sys.argv[1])
settings = json.loads((root / 'inputs/settings.json').read_text())
sources = json.loads((root / 'inputs/sources.json').read_text())
expected = len(sources) * settings['repeats'] * len(settings['arms'])
paths = sorted((root / 'attempts').glob('*/*-request.json'))
assert len(paths) == expected, (len(paths), expected)
groups, response_ids, seen = {}, [], set()
for path in paths:
    prefix = path.name.removesuffix('-request.json')
    result = json.loads((path.parent / (prefix + '-result.json')).read_text())
    key = (result['case_id'], result['arm'], result['repeat'])
    assert key not in seen, key
    seen.add(key)
    assert result['arm'] in settings['arms']
    assert result['http_status'] == 200 and result['local_schema_valid'], prefix
    request = json.loads(path.read_text())
    source = request['messages'][-1]['content'][1:]
    fixed = {k: v for k, v in request.items() if k not in ['messages', 'response_format']}
    signature = (json.dumps(source, sort_keys=True), json.dumps(fixed, sort_keys=True))
    groups.setdefault(result['case_id'], set()).add(signature)
    response = json.loads((path.parent / (prefix + '-response.json')).read_text())
    if response.get('id'):
        response_ids.append(response['id'])
assert all(len(s) == 1 for s in groups.values()), 'input or settings drift'
assert len(response_ids) == len(set(response_ids)), 'duplicate response IDs'
for source in sources:
    assert hashlib.sha256(Path(source['pdf']).read_bytes()).hexdigest() == source['pdf_sha256']
    for page in source['pages']:
        assert hashlib.sha256(Path(page['input_path']).read_bytes()).hexdigest() == page['input_sha256']
audit = dict(attempts=expected, cases=len(groups), matched_inputs_and_settings=True,
             all_http_200=True, all_schema_valid=True, unique_response_ids=len(response_ids))
(root / 'audit.json').write_text(json.dumps(audit, indent=2))
print(json.dumps(audit, indent=2))
