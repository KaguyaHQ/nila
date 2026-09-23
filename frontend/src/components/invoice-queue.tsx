import { useRef, useState } from "react";
import { Check, List } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Command,
  CommandEmpty,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import {
  Sheet,
  SheetContent,
  SheetTrigger,
  SheetHeader,
  SheetTitle,
  SheetDescription,
} from "@/components/ui/sheet";
import type { SalesInvoiceReviewData } from "@/lib/sales-review-api";
type QueueItem = SalesInvoiceReviewData["queue"][number];
export function InvoiceQueue({
  items,
  currentId,
  onSelect,
  disabled = false,
}: {
  items: QueueItem[];
  currentId: string;
  onSelect: (id: string) => void;
  disabled?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const search = useRef<HTMLInputElement>(null);
  return (
    <Sheet open={open} onOpenChange={setOpen}>
      <SheetTrigger render={<Button variant="ghost" size="sm" disabled={disabled} />}>
        <List /> Invoice list
      </SheetTrigger>
      <SheetContent initialFocus={search} className="gap-0 sm:max-w-sm">
        <SheetHeader>
          <SheetTitle>Invoice list</SheetTitle>
          <SheetDescription>
            {items.length} {items.length === 1 ? "invoice" : "invoices"} in this view · amounts from
            lines
          </SheetDescription>
        </SheetHeader>
        <Command className="min-h-0 flex-1 rounded-none!">
          <CommandInput ref={search} aria-label="Find invoice" placeholder="Find invoice…" />
          <CommandList aria-label="Invoice queue" className="max-h-none flex-1">
            <CommandEmpty>No invoices found.</CommandEmpty>
            {items.map((item) => (
              <CommandItem
                key={item.id}
                value={item.id}
                keywords={[item.number, item.customer ?? ""]}
                aria-current={item.id === currentId ? "true" : undefined}
                className={
                  item.id === currentId ? "border-l-2 border-primary bg-muted py-3" : "py-3"
                }
                onSelect={() => {
                  setOpen(false);
                  onSelect(item.id);
                }}
              >
                <span className="min-w-0 flex-1 truncate">
                  <span className="block font-medium">{item.number || "Number not provided"}</span>
                  <span className="block truncate text-xs text-muted-foreground">
                    {item.customer || "Customer not provided"}
                  </span>
                </span>
                <span className="shrink-0 text-right text-xs text-muted-foreground">
                  <span className="mb-1 block text-sm tabular-nums text-foreground">
                    {item.amount || "—"}
                  </span>
                  {item.status === "ready" ? "Ready" : "Needs review"}
                </span>
                {item.id === currentId && <Check className="size-4" aria-label="Current invoice" />}
              </CommandItem>
            ))}
          </CommandList>
        </Command>
      </SheetContent>
    </Sheet>
  );
}
