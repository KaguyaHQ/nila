"""Offline grading for the June sales-invoice benchmark contract.

Expected case facts come from an explicit manifest or the run's expected.json. This preserves the
benchmark's 18% GST / split 9% heads, method-specific raw field names, and zero
GST case 47. It is not a general GST correctness validator.
"""
import argparse
import json
from pathlib import Path
import re
import statistics


def eq(a, b):
    return isinstance(a, (int, float)) and (not isinstance(a, bool)) and (abs(a - b) <= 0.011)


def exact(a, b):
    return isinstance(a, (int, float)) and (not isinstance(a, bool)) and (abs(a - b) <= 1e-06)


def label(s):
    return re.sub('[^A-Z]', '', str(s or '').upper())


def compact(s):
    return re.sub('[^a-z0-9]', '', str(s or '').lower())


def tax_check(ts, expected, zero=False):
    if zero:
        return not ts or all(((t.get('printed_amount') is None or eq(t['printed_amount'], 0)) and
                              (t.get('printed_rate') is None or eq(t['printed_rate'], 0))
                              for t in ts))
    if len(ts) == 1 and label(ts[0].get('printed_label')) in ['GST', 'GSTTOTAL']:
        return eq(ts[0].get('printed_amount'), expected) and exact(ts[0].get('printed_rate'), 18)
    if len(ts) == 2 and {label(t.get('printed_label')) for t in ts} == {'CGST', 'SGST'}:
        return all((eq(t.get('printed_amount'), expected / 2) and exact(t.get('printed_rate'), 9)
                    for t in ts))
    return False


def score_run(result, accounting, expected):
    """Score saved result metadata and replayed accounting against one expected case.

    accounting is the raw_named/normalized replay object, or None for a missing
    replay. No model calls, normalization, filesystem writes, or mutation occurs.
    """
    checks = {}
    details = {}
    actual = {}
    fails = []

    def check(k, ok, got=None, want=None, detail=False):
        (details if detail else checks)[k] = bool(ok)
        if not ok:
            fails.append({
                'field': k,
                'actual': got,
                'expected': want,
                'category': 'detail' if detail else 'financial'
            })

    if accounting is None:
        return {
            **result, 'financial_pass': False,
            'details_pass': False,
            'failures': [{
                'field': 'model_response',
                'actual': result.get('status'),
                'expected': 'usable JSON'
            }]
        }
    a = accounting
    d = a['raw_named']
    n = a['normalized']
    raw = d['line_items']
    norm = n['line_items']
    count = len(expected['before_gst'])
    new = result['method'] in ['plain', 'markdown', 'poppler']
    zero = result['case'] == '47'
    check('item_count',
          len(raw) == count and len(norm) == count, {
              'raw': len(raw),
              'normalized': len(norm)
          }, count)
    actual['items'] = []
    for i, line in enumerate(raw):
        if i >= count:
            break
        nl = norm[i] if i < len(norm) else {}
        base = expected['before_gst'][i]
        gross = expected['gross'][i]
        tax = expected['tax'][i]
        check(f'item{i + 1}.normalized_before_gst', eq(nl.get('taxable_value'), base),
              nl.get('taxable_value'), base)
        base_fields = ['amount_before_gst'] if new else ['printed_taxable_value']
        for k in base_fields:
            check(f'item{i + 1}.{k}', line.get(k) is None or eq(line[k], base), line.get(k), base)
        gross_field = 'amount_including_gst' if new else 'printed_line_total'
        amount_keys = ['amount_before_gst', 'amount_including_gst'] if new else [
            'printed_taxable_value', 'printed_line_total', 'printed_line_amount'
        ]
        check(
            f'item{i + 1}.amount_present',
            any((isinstance(line.get(k), (int, float)) and (not isinstance(line.get(k), bool))
                 for k in amount_keys)), {k: line.get(k)
                                          for k in amount_keys},
            'at least one whole-item monetary amount')
        check(f'item{i + 1}.{gross_field}',
              line.get(gross_field) is None or eq(line[gross_field], gross), line.get(gross_field),
              gross)
        if not new and line.get('printed_line_amount') is not None:
            v = line['printed_line_amount']
            inc = line.get('line_amount_tax_inclusion')
            ok = eq(v, base) and inc in ['exclusive', 'unknown', None] or (eq(
                v, gross) and inc in ['inclusive', 'unknown', None])
            check(f'item{i + 1}.printed_line_amount', ok, {
                'amount': v,
                'inclusion': inc
            }, {
                'before': base,
                'gross': gross
            })
        for k in ['discount_rate', 'discount_amount']:
            check(f'item{i + 1}.{k}', line.get(k) is None or eq(line[k], 0), line.get(k), 0)
        ts = line.get('printed_tax_components') or []
        check(f'item{i + 1}.tax_components', tax_check(ts, tax, zero), ts, [] if zero else {
            'GST_amount': tax,
            'GST_rate': 18,
            'or_split': {
                'CGST': tax / 2,
                'SGST': tax / 2
            }
        })
        for k, src in [('hsn_sac', 'hsn'), ('quantity', 'quantity'),
                       ('printed_unit_price', 'unit_price')]:
            check(
                f'item{i + 1}.{k}',
                line.get(k) == expected[src][i] if k == 'hsn_sac' else exact(
                    line.get(k), expected[src][i]), line.get(k), expected[src][i], True)
        desc = (line.get('item_name') or '') + ' ' + (line.get('description') or '')
        check(f'item{i + 1}.identity',
              compact(expected['item_codes'][i]) in compact(desc), desc, expected['item_codes'][i],
              True)
        check(f'item{i + 1}.repeat_count',
              line.get('repeat_count') == 1, line.get('repeat_count'), 1, True)
        check(f'item{i + 1}.uom',
              compact(line.get('uom')) == compact(expected['uom'][i]), line.get('uom'),
              expected['uom'][i], True)
        actual['items'].append({
            'before': line.get('amount_before_gst') if new else line.get('printed_taxable_value'),
            'line_amount': line.get('printed_line_amount'),
            'gross': line.get(gross_field),
            'taxes': ts,
            'normalized_before': nl.get('taxable_value'),
            'expected_before': base,
            'expected_gross': gross,
            'expected_tax': tax
        })
    footer = d.get('printed_tax_totals') or []
    for head in ['cgst', 'sgst']:
        vals = [
            t.get('printed_amount') for t in footer
            if label(t.get('printed_label')) == head.upper()
        ]
        check(head, not vals and zero or (len(vals) == 1 and eq(vals[0], expected[head])), vals,
              None if zero else expected[head])
    check(
        'footer_tax_values',
        all((label(t.get('printed_label')) in ['CGST', 'SGST']
             and eq(t.get('printed_amount'), expected[label(t.get('printed_label')).lower()])
             or (label(t.get('printed_label')) in [
                 'GST', 'TAX', 'TAXAMOUNT', 'TOTALGST', 'GSTTOTAL', 'TOTALTAX', 'TOTALTAXAMOUNT',
                 'GSTAMOUNT', 'TOTAL'
             ] and eq(t.get('printed_amount'), expected['cgst'] + expected['sgst']))
             or (t.get('printed_amount') is None or eq(t['printed_amount'], 0)) for t in footer)),
        footer, 'correct CGST/SGST and optional matching aggregate, not summed twice')
    check(
        'subtotal',
        any((eq(d.get(k), expected['subtotal'])
             for k in ['printed_subtotal_before_discount', 'printed_total_taxable'])),
        {k: d.get(k)
         for k in ['printed_subtotal_before_discount', 'printed_total_taxable']},
        expected['subtotal'])
    for k in ['printed_subtotal_before_discount', 'printed_total_taxable']:
        check(k, d.get(k) is None or eq(d[k], expected['subtotal']), d.get(k), expected['subtotal'])
    for k in ['printed_discount_amount', 'printed_additional_charges']:
        check(k, d.get(k) is None or eq(d[k], 0), d.get(k), 0)
    check(
        'rounding',
        d.get('printed_rounding_adjustment') is None and expected['rounding'] == 0
        or eq(d.get('printed_rounding_adjustment'), expected['rounding']),
        d.get('printed_rounding_adjustment'), expected['rounding'])
    check('grand_total', eq(d.get('printed_grand_total'), expected['grand_total']),
          d.get('printed_grand_total'), expected['grand_total'])
    check(
        'total_tax',
        d.get('printed_total_tax') is None
        or eq(d['printed_total_tax'], expected['cgst'] + expected['sgst']),
        d.get('printed_total_tax'), expected['cgst'] + expected['sgst'])
    for k, got, want in [('document_type', d.get('document_type'), 'invoice'),
                         ('document_status', d.get('document_status'), 'active'),
                         ('invoice_number', d.get('invoice_number'), expected['invoice_number']),
                         ('date', n.get('invoice_date'), expected['date']),
                         ('supplier_gstin', (d.get('supplier')
                                             or {}).get('gstin'), expected['supplier_gstin']),
                         ('buyer_gstin', (d.get('bill_to')
                                          or {}).get('gstin'), expected['buyer_gstin'])]:
        check(k, got == want, got, want, True)
    actual.update({
        'footer_taxes': footer,
        'subtotal': d.get('printed_subtotal_before_discount'),
        'total_taxable': d.get('printed_total_taxable'),
        'grand_total': d.get('printed_grand_total'),
        'rounding': d.get('printed_rounding_adjustment')
    })
    return {
        **result, 'raw_money_checks_pass': all(
            (v for k, v in checks.items() if not k.endswith('.normalized_before_gst'))),
        'normalized_bases_pass': all(
            (v for k, v in checks.items() if k.endswith('.normalized_before_gst'))),
        'missing_printed_gross': [
            i + 1 for i, line in enumerate(raw) if not zero and (
                line.get('amount_including_gst') if new else line.get('printed_line_total')) is None
            and (not (not new and line.get('line_amount_tax_inclusion') == 'inclusive' and
                      (line.get('printed_line_amount') is not None)))
        ],
        'financial_pass': all(checks.values()),
        'details_pass': all(details.values()),
        'checks': checks,
        'details': details,
        'failures': fails,
        'actual': actual,
        'source_issue': expected['source_issue']
    }


def summarize(runs):
    """Aggregate scores and the original saved request usage metadata."""
    summary = {}
    for method in sorted({x['model_alias'] + '-' + x['method'] for x in runs}):
        rs = [x for x in runs if x['model_alias'] + '-' + x['method'] == method]
        summary[method] = {
            'count': len(rs),
            'financial_pass': sum((x['financial_pass'] for x in rs)),
            'raw_money_checks_pass': sum((x.get('raw_money_checks_pass', False) for x in rs)),
            'normalized_bases_pass': sum((x.get('normalized_bases_pass', False) for x in rs)),
            'details_pass': sum((x['details_pass'] for x in rs)),
            'all_selected_pass': sum((x['financial_pass'] and x['details_pass'] for x in rs)),
            'mean_ms': round(statistics.mean((x['duration_ms'] for x in rs))),
            'input_tokens': sum((x.get('usage', {}).get('prompt_tokens', 0) for x in rs)),
            'output_tokens': sum((x.get('usage', {}).get('completion_tokens', 0) for x in rs)),
            'provider_reported_cost': sum((x.get('usage', {}).get('cost', 0) for x in rs)),
            'cost_available_count': sum(('cost' in x.get('usage', {}) for x in rs)),
            'http_attempts': sum((x.get('http_attempts', 0) for x in rs)),
            'failures': [{
                'case': x['case'],
                'failures': x['failures']
            } for x in rs if not (x['financial_pass'] and x['details_pass'])]
        }
    return {'summary': summary, 'runs': runs}


def score_directory(directory, expected=None, accounting_dir=None):
    """Score saved result/accounting pairs against expected case facts, without writing.

    If expected is omitted, read the directory's historical expected.json.
    If accounting_dir is supplied, read replayed accounting there instead.
    """
    r = Path(directory)
    accounting_root = Path(accounting_dir) if accounting_dir is not None else r
    truth = expected if expected is not None else json.loads(
        (r / 'expected.json').read_text(encoding='utf-8'))
    runs = []
    for p in sorted(r.glob('*-result.json')):
        out = json.loads(p.read_text(encoding='utf-8'))
        q = accounting_root / p.name.replace('-result.json', '-accounting.json')
        accounting = json.loads(q.read_text(encoding='utf-8')) if q.exists() else None
        runs.append(score_run(out, accounting, truth[out['case']]))
    return summarize(runs)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',
                        type=Path,
                        help='Saved June-contract run directory containing expected.json')
    parser.add_argument('--output',
                        type=Path,
                        help='Output path; defaults to DIRECTORY/scores.json')
    parser.add_argument('--expected',
                        type=Path,
                        help='Expected case manifest; defaults to DIRECTORY/expected.json')
    parser.add_argument('--accounting-dir',
                        type=Path,
                        help='Directory containing replayed accounting; defaults to DIRECTORY')
    args = parser.parse_args(argv)
    expected = json.loads(args.expected.read_text(encoding='utf-8')) if args.expected else None
    scores = score_directory(args.directory, expected, args.accounting_dir)
    destination = args.output if args.output is not None else args.directory / 'scores.json'
    destination.write_text(json.dumps(scores, indent=2), encoding='utf-8')
    print(
        json.dumps(
            {
                k: {
                    a: b
                    for a, b in v.items() if a != 'failures'
                }
                for k, v in scores['summary'].items()
            },
            indent=2))


if __name__ == '__main__':
    main()
