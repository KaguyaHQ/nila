# Processing Contract

This contract describes how document processors should interact with Nila once added.

## Input

Nila sends a document reference, metadata, and requested artifact kinds. The processor may read bytes through a controlled storage URL or receive bytes directly, depending on the adapter.

## Output

Processors return structured artifacts:

```json
{
  "kind": "invoice_extraction",
  "version": 1,
  "data": {
    "supplier_name": "Example Traders",
    "invoice_number": "INV-001",
    "invoice_date": "2026-05-26",
    "total_amount": "12500.00"
  },
  "confidence": {
    "invoice_number": 0.98,
    "total_amount": 0.91
  },
  "exceptions": []
}
```

## Rules

- Processors do not write business state.
- Phoenix stores returned artifacts with `pending_review` status.
- Humans approve or reject exceptions.
- Approved artifacts can trigger workflow steps and audited state transitions.
