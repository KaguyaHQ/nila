# Model cost baseline

Measured on September 14, 2026 from a local Vercel AI Gateway request export.
The source export is not included in this repository.

## Sample

- 1,100 requests from August 29 through September 14, 2026.
- All requests used `alibaba/qwen3.7-flash`. There were no Gemma 4 calls.
- 1,099 requests succeeded; one returned HTTP 503 with zero tokens and zero cost.
- Averages below use the 1,099 successful requests. Costs are in USD.

## Cost

Input accounted for **54.5%** of spending and output for **45.5%**.
The input-to-output cost ratio was **1.20:1**.

| Measure | Cost |
| --- | ---: |
| Input, including cache reads | $0.143025228 |
| Output, including reasoning | $0.119490800 |
| Total | $0.262516028 |
| Average successful call | $0.000238868 |
| 1,000 successful calls at this average | $0.238868 |
| Most expensive call | $0.001041320 |

Every request's recorded cost matched this calculation:

```text
cost = (inputTokens × 0.03
      + cacheReadTokens × 0.006
      + (outputTokens + reasoningTokens) × 0.13) / 1,000,000
```

These are the rates verified against this export, not a claim about future
pricing. Cache writes and additional fees were zero throughout the sample.

## Tokens

| Tokens per successful call | Average | Maximum |
| --- | ---: | ---: |
| Fresh input | 4,179 | 9,363 |
| Cached input | 794 | 6,656 |
| Total input | 4,974 | 9,363 |
| Returned output | 799 | 5,646 |
| Reasoning | 37 | 7,383 |
| Total output, including reasoning | 836 | 7,925 |

In this export, `inputTokens` excludes `cacheReadTokens`, and `outputTokens`
excludes `reasoningTokens`. Total input and total output above add those fields
per request before calculating averages and maxima. Maxima can come from
different calls and should not be added together.

Total input was 5,465,978 tokens; total output including reasoning was 919,160
tokens. The input-to-output token ratio was **5.95:1**. Every request's total
input was below 32K tokens.

## Applying this to invoices

For planning, assume roughly one extraction call per invoice, with segmentation
cost spread across the invoices in each uploaded file:

```text
cost per invoice = extraction cost
                 + segmentation cost / invoices in the file
                 + retry cost per invoice
```

Under that assumption, **about $0.239 per 1,000 invoices** is a rough extraction
estimate using this sample's average call cost. It is not a measured full cost
per invoice: the export does not identify segmentation, extraction, or retry
calls, nor does it establish how many invoices were processed. Verify those
counts before using this as the full processing cost.
