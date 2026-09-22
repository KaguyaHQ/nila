import { useState } from "react";
import { Check, List } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Command, CommandEmpty, CommandInput, CommandItem, CommandList } from "@/components/ui/command";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";

type QueueItem = { id: string; number: string; status: "needs_review" | "ready" };

export function InvoiceQueue({ items, currentId, onSelect, disabled = false }: {
  items: QueueItem[];
  currentId: string;
  onSelect: (id: string) => void;
  disabled?: boolean;
}) {
  const [open, setOpen] = useState(false);

  return <Popover open={open} onOpenChange={setOpen}>
    <PopoverTrigger render={<Button variant="ghost" size="icon-sm" aria-label="Jump to invoice" disabled={disabled} />}><List /></PopoverTrigger>
    <PopoverContent align="end" className="w-80 max-w-[calc(100vw-2rem)] p-0">
      <Command>
        <CommandInput aria-label="Find invoice" placeholder="Find invoice…" />
        <CommandList aria-label="Invoice queue">
          <CommandEmpty>No invoices found.</CommandEmpty>
          {items.map(item => <CommandItem key={item.id} value={item.id} keywords={[item.number]} onSelect={() => { setOpen(false); onSelect(item.id); }}>
            <span className="min-w-0 flex-1 truncate">{item.number || "Number not provided"}</span>
            <span className="text-xs text-muted-foreground">{item.status === "ready" ? "Ready" : "Needs review"}</span>
            {item.id === currentId && <Check className="size-4" aria-label="Current invoice" />}
          </CommandItem>)}
        </CommandList>
      </Command>
    </PopoverContent>
  </Popover>;
}
