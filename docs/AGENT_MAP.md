# Agent Map

Fast path for Claude or any coding agent working in Nila. Read only what
matches the task; do not load the whole docs tree by default.

## First 3 files

1. [`../AGENTS.md`](../AGENTS.md) - coding rules and project boundaries.
2. [`prd.md`](./prd.md) - product intent: why/who, the bet, goals and non-goals.
3. [`architecture.md`](./architecture.md) - runtime, contexts, and state principle.

Then branch by task below.

## Task Routes

| Task | Read first | Then read |
| --- | --- | --- |
| Change business logic | [`architecture.md`](./architecture.md) | Relevant plan in [`plans/`](./.plans/), [`decisions.md`](./decisions.md) if the change crosses architecture |
| Change LiveView or UI | [`design/DESIGN.md`](./design/DESIGN.md) | [`design/PHILOSOPHY.md`](./design/PHILOSOPHY.md), [`design/layout.md`](./design/layout.md), relevant LiveView tests |
| Add or edit a feature | [`prd.md`](./prd.md) | Relevant plan in [`plans/`](./.plans/), customer input in [`discovery/`](./discovery/) |
| Work on transactions | Transactional Code section in [`../AGENTS.md`](../AGENTS.md) | [`decisions.md`](./decisions.md), relevant context tests |
| Work on document extraction | [`processing_contract.md`](./processing_contract.md) | [`architecture.md`](./architecture.md), relevant `Documents` and `Workflows` tests |
| Work on approvals or receivables | [`decisions.md`](./decisions.md) (Collections Cockpit section) | [`plans/workflow-driven-model.md`](./.plans/workflow-driven-model.md), [`discovery/customer-workflows.md`](./discovery/customer-workflows.md), relevant `Nila.Approvals` / `Nila.Quotes` tests |
| Work on auth or settings | [`plans/auth/plan.md`](./.plans/auth/plan.md) or [`plans/settings/README.md`](./.plans/settings/README.md) | [`prd.md`](./prd.md), router and LiveView tests |
| Debug production behavior | [`runbooks/`](./runbooks/) | `hetzner/README.md` if deploy-related |
| Add infra or ops work | [`decisions.md`](./decisions.md) | `hetzner/README.md` |
| Onboard a workspace / import customer data | [`runbooks/data-import.md`](./runbooks/data-import.md) | `Nila.Quotes.Import`, `Nila.Documents.Import` |
| Understand domain terms | [`glossary.md`](./glossary.md) | [`discovery/customer-workflows.md`](./discovery/customer-workflows.md) for multi-line domain detail |

## Source-of-Truth Rules

- Product intent (why/who, goals, non-goals): [`prd.md`](./prd.md).
- Strategy rationale (value model, ICP filter, wedge logic, bets): [`strategy.md`](./strategy.md).
- Current as-built state: the code + per-feature status in [`plans/`](./.plans/).
- Architecture decisions: [`decisions.md`](./decisions.md).
- UI system: [`design/DESIGN.md`](./design/DESIGN.md), with reasoning in [`design/`](./design/).
- Coding rules: [`../AGENTS.md`](../AGENTS.md).
- Claude-specific local notes: [`../CLAUDE.md`](../CLAUDE.md).

If two files disagree, prefer the source of truth above and patch the stale
cross-reference in the same change.

## Search Hints

Use targeted searches instead of broad reads:

```bash
rg "ApprovalRequest|Quote|Artifact|Repo.transact" lib test docs
rg "Status:" docs/.plans
rg "Replaces|Deleted|Status:" docs
```

Large docs to open only when needed:

- [`discovery/customer-workflows.md`](./discovery/customer-workflows.md) - deep customer research.
- [`plans/workflow-driven-model.md`](./.plans/workflow-driven-model.md) - future schema and cockpit direction.
- [`plans/google-drive-ingestion.md`](./.plans/google-drive-ingestion.md) - deferred Drive ingestion plan.
