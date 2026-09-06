# Nila design — start here

## Current direction

**Crispness with warmth.** Light navigation, white panels, a quiet canvas, readable
ink and restrained colour. Origin's light application is the visual reference;
Nila adapts its clarity to dense accounting work. Product UI is light-only.
The moon identity means calm, reliable and reflective; it does not require decoration.

## Read only what the task needs

Always read this file and [OPINIONS.md](OPINIONS.md) before product UI changes.

| Task | Additional reading |
| --- | --- |
| Tokens, classes, components or mechanical UI | [FRONTEND.md](FRONTEND.md) |
| New screen, workflow or substantial restructuring | [COMPOSITION.md](COMPOSITION.md), [TASTE.md](TASTE.md); FRONTEND for implementation |
| Aesthetic judgment | [TASTE.md](TASTE.md) |
| Public/marketing pages | [MARKETING.md](MARKETING.md), TASTE; FRONTEND for implementation |

Each file owns its subject. Do not copy rules between them. The [archive](archive/README.md)
is historical evidence, not routine reading or current instructions. User decisions
supersede these defaults; update the owning document when a decision becomes durable.

## Truth and accessibility invariants

- Phoenix owns business truth. UI must not imply a transition that was not recorded.
- Machine checks, human assurance, workflow state and approval remain distinct.
  Unresolved work cannot look verified, approved, reconciled or complete.
- Numbers state their basis. Derived identity is not independent corroboration.
  Keep source evidence and attributed human decisions connected to their result.
- Required words and values remain readable. Colour may reinforce meaning, never carry
  it alone or imply stronger assurance. Do not shrink operational text into context.
- Use plain, precise language familiar to CAs and staff. No hype or exclamation marks.

## Authorities

`assets/css/app.css` owns exact tokens; `lib/nila_web/components/` owns recipes.
FRONTEND defines their contracts and upstream authority. `/dev/design-system` is the
executable reference. Composition and taste are judged in the rendered product;
passing a guard alone does not establish visual quality.

## Completion loop

1. State the user-visible outcome; apply OPINIONS to scope.
2. Inspect the current desktop screen and an analogous accepted surface.
3. Implement through shared tokens/components, improving the shared recipe when needed.
4. Run `mix nila.style_guard` and checks appropriate to the change.
5. Inspect the rendered affected states: hierarchy, alignment, clipping, empty states,
   controls and readable text at actual scale. Compare equivalent roles across routes.
6. Remove additions that do not help the task. Report changes and validation honestly.

Nila is a desktop workbench. Check narrow layouts when shared shell/layout changes risk
breakage; routine mobile parity is not a requirement. Do not redesign adjacent areas.
