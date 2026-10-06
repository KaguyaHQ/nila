"""Grade saved answers and real application outputs; no network calls."""
from pathlib import Path
from decimal import Decimal, ROUND_HALF_UP
import json,re,collections,openpyxl
import sys
R=Path(sys.argv[1])
OUT=Path(sys.argv[2]) if len(sys.argv)>2 else R
OUT.mkdir(parents=True,exist_ok=True)
truth=json.loads((R/'inputs/expectations.json').read_text())
def cents(v):
    if v is None:return None
    return int((Decimal(str(v))*100).quantize(Decimal('1'),rounding=ROUND_HALF_UP))
def eq(a,b):return cents(a)==cents(b)
def kind(c):
    if 'kind' in c:return c['kind']
    if 'observed_kind' in c:return c['observed_kind']
    label=(c.get('printed_label') or '').upper()
    heads=[h for h in ['cgst','sgst','igst','cess'] if h.upper() in label]
    if len(heads)==1:return heads[0]
    if len(heads)>1 or label.strip()=='GST' or ('TAX' in label and ('TOTAL' in label or 'AMOUNT' in label)):return 'combined'
    return 'unknown'
def amount(c):return c.get('amount') if 'amount' in c else c.get('printed_amount')
def rate(c):return c.get('rate') if 'kind' in c or 'observed_kind' in c else c.get('printed_rate')
def signature(cs,rates=False):
    return sorted((kind(c),cents(amount(c)),cents(rate(c)) if rates else None) for c in cs)
def tax_economics(cs,expected,heads):
    """Every entry must have the right amount. Correct combined never masks bad heads."""
    observed=collections.defaultdict(list)
    for c in cs: observed[kind(c)].append(amount(c))
    if any(k not in ['cgst','sgst','igst','combined'] or len(v)!=1 or v[0] is None for k,v in observed.items()):return False
    expected_total=sum(amount(t) for t in expected if kind(t)!='combined')
    combined=[amount(t) for t in expected if kind(t)=='combined']
    if combined:expected_total=combined[0]
    for k,v in observed.items():
        if not eq(v[0],expected_total if k=='combined' else heads.get(k,0)):return False
    if 'combined' in observed:return True
    return eq(sum(v[0] for v in observed.values()),expected_total)

grades=[]
for path in sorted((R/'attempts').glob('*/*-result.json')):
    result=json.loads(path.read_text()); key=path.name.removesuffix('-result.json');d=path.parent
    t=truth[result['case_id']];checks={};detail={}
    rawpath=d/(key+'-decoded.json');output_dir=OUT/'attempts'/key;pipepath=output_dir/(key+'-pipeline.json')
    if not rawpath.exists() or not pipepath.exists():
        grades.append(dict(id=key,arm=result['arm'],case_id=result['case_id'],error='missing answer or replay'));continue
    raw=json.loads(rawpath.read_text());p=json.loads(pipepath.read_text())
    lines=[line for line in raw['line_items'] for _ in range(line.get('repeat_count',1))]
    checks['identity']=(raw['invoice_number']==t['invoice_number'] and p['normalized']['invoice_date']==t['date'] and p['normalized']['seller_gstin']==t['seller'] and p['normalized']['buyer_gstin']==t['buyer'])
    checks['base_and_grand']=(len(lines)==len(t['values']) and all(eq(x.get('printed_taxable_value'),v) for x,v in zip(lines,t['values'])) and eq(raw['printed_grand_total'],t['grand']))
    checks['hsn']=[x.get('hsn_sac') for x in lines]==t['hsn']
    checks['printed_item_taxes']=(len(lines)==len(t['item_taxes']) and all(signature(x.get('printed_tax_components',[]),True)==signature(e,True) for x,e in zip(lines,t['item_taxes'])))
    actual=signature(raw['printed_tax_totals']); expected=signature(t['summary'])
    if result['case_id']=='caltech-jan-p2':
        checks['printed_summary']=actual in [expected,signature([dict(kind='combined',amount=4680)])]
    else: checks['printed_summary']=actual==expected
    checks['summary_amounts_correct']=tax_economics(raw['printed_tax_totals'],t['summary'],t['tax_heads'])
    item_money=True
    for i,(x,e) in enumerate(zip(lines,t['item_taxes'])):
        cs=x.get('printed_tax_components',[])
        if not e:
            # Moving a correct footer amount to an item loses source location,
            # but is not a wrong number. Judge that separately above.
            if cs:
                allowed=[];heads={}
                for tax in t['summary']:
                    h=kind(tax)
                    if h in ['cgst','sgst','igst'] and tax.get('rate') is not None:
                        value=float((Decimal(str(t['values'][i]))*Decimal(str(tax['rate']))/100).quantize(Decimal('.01'),rounding=ROUND_HALF_UP))
                        allowed.append(dict(kind=h,amount=value));heads[h]=value
                item_money &= bool(allowed) and tax_economics(cs,allowed,heads)
            continue
        heads={h:sum(amount(tax) for tax in e if kind(tax)==h) for h in ['cgst','sgst','igst']}
        if any(kind(tax)=='combined' for tax in e):
            total=next(amount(tax) for tax in e if kind(tax)=='combined');heads={'cgst':total/2,'sgst':total/2,'igst':0}
        item_money &= tax_economics(cs,e,heads)
    checks['item_amounts_correct']=item_money and len(lines)==len(t['item_taxes'])
    checks['raw_financial_facts']=all(checks[k] for k in ['identity','base_and_grand','hsn','summary_amounts_correct','item_amounts_correct'])
    checks['pipeline_tax_heads']=all(eq(p['tax_heads'].get(h,0),v) for h,v in t['tax_heads'].items())
    checks['pipeline_taxable']=eq(p['totals']['taxable'],t['taxable'])
    workbook=openpyxl.load_workbook(output_dir/(key+'-workings.xlsx'),data_only=False,read_only=True)
    sales=workbook['Sales'];cells={c:sales[c].value for c in ['A5','G5','H5','I5','J5','K5','O5']}
    checks['xlsx_sales_numbers']=(cells['A5']==t['invoice_number'] and eq(cells['G5'],t['taxable']) and eq(cells['K5'],t['grand']) and all(eq(cells[c],t['tax_heads'][h]) for c,h in [('H5','cgst'),('I5','sgst'),('J5','igst')]))
    detail['xlsx_sales_cells']=cells
    calc=workbook['Calculations']
    calc_rows=[row for row in calc.iter_rows(min_row=5,values_only=True) if row[0]==t['invoice_number']]
    detail['xlsx_calculation_rows']=[{k:row[col] for k,col in [('taxable',9),('cgst',10),('sgst',13),('igst',16)]} for row in calc_rows]
    checks['xlsx_calculation_numbers']=bool(calc_rows) and all(all(isinstance(row[col],(int,float)) for row in calc_rows) and eq(sum(row[col] for row in calc_rows),expected) for col,expected in [(9,t['taxable']),(10,t['tax_heads']['cgst']),(13,t['tax_heads']['sgst']),(16,t['tax_heads']['igst'])])
    detail['issues']=[dict(code=i['code'],level=i.get('level'),message=i.get('message')) for i in p['issues']]
    detail['verification_failed']=p['verification']['failed_checks']
    detail['actual_summary']=raw['printed_tax_totals']
    invs=[i for group in p['derived'].get('b2b',[]) for i in group['inv']]
    expected_heads=dict(t['tax_heads'])
    if result['case_id']=='breeze-111': expected_heads={'cgst':61937.46,'sgst':61937.46,'igst':0} # invoice totals differ from sum of rounded item taxes
    if len(invs)==1:
        rows=[i['itm_det'] for i in invs[0]['itms']]
        checks['gstr_tax_numbers']=(eq(sum(x['txval'] for x in rows),t['taxable']) and all(eq(sum(x.get(f,0) for x in rows),expected_heads[h]) for f,h in [('camt','cgst'),('samt','sgst'),('iamt','igst')]))
        checks['gstr_invoice_value']=eq(invs[0]['val'],t['grand'])
        detail['gstr_invoice_value']=invs[0]['val']
    else:checks['gstr_tax_numbers']=False;checks['gstr_invoice_value']=False
    checks['all_source_checks']=all(checks[k] for k in ['raw_financial_facts','printed_item_taxes','printed_summary'])
    financial_keys=['identity','pipeline_tax_heads','pipeline_taxable','xlsx_sales_numbers','xlsx_calculation_numbers','gstr_tax_numbers','gstr_invoice_value']
    final_correct=all(checks[k] for k in financial_keys)
    ready=p['reviewable']
    outcome=('correct_ready' if final_correct else 'wrong_ready') if ready else ('correct_held' if final_correct else 'wrong_held')
    detail['readiness_outcome']=outcome
    detail['final_failed']=[k for k in financial_keys if not checks[k]]
    grades.append(dict(id=key,arm=result['arm'],case_id=result['case_id'],checks=checks,detail=detail))
if any('error' in g for g in grades):
    raise SystemExit('Run is incomplete or has failed attempts. Finish replay and report those failures before scoring: ' + ', '.join(g['id'] for g in grades if 'error' in g))
(OUT/'scores.json').write_text(json.dumps(grades,indent=2),encoding='utf-8')
summary={}
for arm in dict.fromkeys(g['arm'] for g in grades):
    gs=[g for g in grades if g['arm']==arm]
    summary[arm]={k:sum(g.get('checks',{}).get(k,False) for g in gs) for k in grades[0]['checks']}
    summary[arm]['attempts']=len(gs)
    summary[arm]['raw_fact_error_in_ready_answer']=sum(not g['checks']['raw_financial_facts'] and g['detail']['readiness_outcome'].endswith('ready') for g in gs)
    summary[arm]['readiness']=dict(collections.Counter(g['detail']['readiness_outcome'] for g in gs))
(OUT/'summary.json').write_text(json.dumps(summary,indent=2),encoding='utf-8')
print(json.dumps(summary,indent=2))
for case in truth:
    print(case,[(g['arm'],[k for k,v in g['checks'].items() if not v]) for g in grades if g['case_id']==case])
