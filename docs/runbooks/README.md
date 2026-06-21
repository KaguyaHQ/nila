# Runbooks

Operational and debugging playbooks for things that are already shipped.
Each file is one diagnosis you might need to do more than once: "why is
X slow", "why are Y jobs piling up", "how do I reproduce Z outside the
app".

## What lives here

- The **symptom** (what you saw that brought you here).
- A **fast reproduction** outside the app (curl, psql, IEx one-liner).
- The **root causes** ranked by likelihood, with how to tell them apart.
- The **knobs that actually move the needle**, and the ones that don't.

What does **not** live here: feature design (that's `docs/.plans/`),
system decisions (`docs/decisions.md`), open ops backlog (`docs/TODO.md`).

## Conventions

- Title is the symptom, not the subsystem (`assistant-latency.md`, not
  `assistant.md`).
- Lead with TL;DR — what's almost certainly going on and how to confirm
  in under a minute.
- Keep the reproduction self-contained. Future-you should not have to
  reverse-engineer the payload from the app code.
- When a runbook's advice goes stale, fix it in place. The point is to
  stay loadbearing.
