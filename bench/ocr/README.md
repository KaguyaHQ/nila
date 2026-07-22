# OCR benchmark

Runs the operational Mistral OCR provider and the costly LlamaExtract comparison adapter against identical GST source documents. Run it only when a paid Llama comparison is intentional.

```bash
mix nila.benchmark_ocr --manifest bench/ocr/manifest.json
```

Both `MISTRAL_API_KEY` and `LLAMA_CLOUD_API_KEY` must be configured. The worker's `GST_OCR_PROVIDER` setting does not affect the benchmark. Raw provider responses and normalized outputs are written under `bench/ocr/results/`, which is ignored.

Provider agreement is not ground truth. Compare discrepancies against the filed-return JSON and human-reviewed corrections under `test/fixtures`; production uses Mistral regardless of Llama parity because LlamaExtract is prohibitively costly.
