import { TableRow } from "@/components/ui/table";
import { cn } from "@/lib/utils";
import { createLink } from "@tanstack/react-router";
import type { ComponentProps, MouseEvent } from "react";

const interactive =
  "a, button, input, select, textarea, label, summary, [role=button], [role=checkbox], [role=switch], [role=combobox], [contenteditable], [tabindex], [data-row-action]";

function openRecord(event: MouseEvent<HTMLTableRowElement>) {
  if (
    event.defaultPrevented ||
    (event.type === "auxclick" && event.button !== 1) ||
    !(event.target instanceof Element) ||
    !event.currentTarget.contains(event.target) ||
    window.getSelection()?.toString()
  )
    return;

  const control = event.target.closest(interactive);
  if (control && event.currentTarget.contains(control)) return;

  const link = event.currentTarget.querySelector<HTMLAnchorElement>("a[data-record-link]");
  if (!link) return;
  event.preventDefault();
  link.dispatchEvent(
    new MouseEvent("click", {
      bubbles: true,
      cancelable: true,
      ctrlKey: event.ctrlKey || event.button === 1,
      metaKey: event.metaKey,
      shiftKey: event.shiftKey,
      altKey: event.altKey,
    }),
  );
}

// The visible link owns routing and keyboard access. A row without that link is inert.
// Keep one RecordTableLink per row; other links/buttons retain their own actions.
export function RecordTableRow({
  className,
  ...props
}: Omit<ComponentProps<typeof TableRow>, "onClick" | "onAuxClick">) {
  return (
    <TableRow
      {...props}
      className={cn(
        "hover:bg-transparent has-[[data-record-link]]:cursor-pointer has-[[data-record-link]]:hover:bg-muted/50 has-[[data-record-link]:focus-visible]:bg-muted/50",
        className,
      )}
      onClick={openRecord}
      onAuxClick={openRecord}
    />
  );
}

export const RecordTableLink = createLink(function RecordAnchor({
  className,
  ...props
}: ComponentProps<"a">) {
  return (
    <a
      {...props}
      data-record-link
      className={cn(
        "rounded-sm focus-visible:outline-2 focus-visible:outline-ring focus-visible:outline-offset-4",
        className,
      )}
    />
  );
});
