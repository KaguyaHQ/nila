# React interaction audit — 22 September 2026

Scope: desktop GST workspaces and clients. Banking, Tally, Winman exports and
business invoicing are outside this audit. GSTR-3B, purchase Excel intake, source
corrections and pairing remain deliberate LiveView handoffs.

## Restored or improved

- Go-to palette: Ctrl/Cmd+K, searchable pages, clients/GSTINs and months. Uses
  shadcn Command; Nila supplies destinations and keeps the current register source.
- Client picker: searchable Combobox, available with the sidebar collapsed. Client
  changes retain period/section and safe filters, dropping document IDs and search.
- Account menu: DropdownMenu for settings and CSRF-protected Phoenix sign-out.
- Sidebar collapse persists; collapsed navigation and shortcut help use Tooltip.
- Invoice jump list: Command in Popover, scoped to the selected review filter.
- Register search survives opening an invoice and returning to the register.
- Invoice edit forms support Ctrl/Cmd+Enter to save, without confirming review.
- Sales filters use ToggleGroup; invoice check disclosure uses Collapsible.
- ITC choices use RadioGroup; optional notes use Textarea.
- Shortcut help uses Dialog and Kbd. The retired disable preference is ignored.
- GSTR-2B connection and OTP use Dialog; fetch, refresh, preparation and source JSON
  stay in the React workspace. Phoenix retains credentials and accounting rules.

The new UI recipes come from the official `base-nova` registry at
`https://ui.shadcn.com/r/styles/base-nova/{component}.json`. Registry placeholders
are resolved to the project's Lucide icons and imports to local components.
Command uses upstream cmdk. Its selected styling explicitly tests
`data-selected="true"`, because cmdk also emits `data-selected="false"`.

## Kept deliberately

- PDF.js rendering, upload progress/retry and evidence-based save logic are domain
  behavior. They are not replacements for shadcn controls.
- Native month entry remains a month input; adding a day calendar would not help.
- Desktop shell layout remains local composition. It does not need a mobile Sheet
  or a wholesale Sidebar rewrite to restore the missing interactions.

## Remaining parity work

LiveView issue rows can open the relevant correction editor and focus its field.
React still uses its explicit edit actions. Its issue API does not yet supply the
correction target metadata. Restore that in a focused API/UI change; do not guess
which accounting field to edit from issue text.

This audit does not declare all LiveView routes migrated. The handoffs above remain.
