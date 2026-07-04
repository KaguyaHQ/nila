# Processing Contract

This contract describes how document processors should interact with Nila once added.

## Input

Nila sends a document reference, metadata, and requested artifact kinds. The processor may read bytes through a controlled storage URL or receive bytes directly, depending on the adapter.

## Output

Processors return structured artifacts:

```json
{
  "kind": "bank_statement_extraction",
  "version": 1,
  "data": {
    "account_number": "XXXX1234",
    "period_start": "2026-05-01",
    "period_end": "2026-05-31",
    "transactions": [
      {
        "date": "2026-05-06",
        "narration": "UPI/EXAMPLE TRADERS/...",
        "amount": "12500.00",
        "direction": "credit"
      }
    ]
  },
  "confidence": {
    "transactions.0.amount": 0.98,
    "transactions.0.direction": 0.91
  },
  "exceptions": []
}
```

## Rules

- Processors do not write business state.
- Phoenix stores returned artifacts with `pending_review` status.
- Humans approve or reject exceptions.
- Approved artifacts can trigger workflow steps and audited state transitions.
