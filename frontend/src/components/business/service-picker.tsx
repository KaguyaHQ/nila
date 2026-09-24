// Selection behavior adapted from Midday invoice/product-autocomplete.tsx
// at 51587319f26a0ffaa9dfccab1920373cb65689b7: copy saved defaults into one
// editable line. Bigcapital ItemsSelect supplies the searchable catalogue pattern.
// Nila deliberately does not auto-save line edits into the catalogue.

import { Search } from "lucide-react";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import type { BusinessService } from "@/lib/business-api";

export function ServicePicker({
  services,
  index,
  disabled,
  onSelect,
}: {
  services: BusinessService[];
  index: number;
  disabled: boolean;
  onSelect: (service: BusinessService) => void;
}) {
  const [open, setOpen] = useState(false);
  return (
    <Popover open={open} onOpenChange={setOpen}>
      <PopoverTrigger
        type="button"
        disabled={disabled}
        aria-label={`Select saved item ${index + 1}`}
        render={
          <Button
            type="button"
            variant="ghost"
            size="icon-sm"
            disabled={disabled}
            className="size-7 shrink-0 text-muted-foreground"
          />
        }
      >
        <Search className="size-3.5" />
      </PopoverTrigger>
      <PopoverContent align="start" className="w-96 max-w-[calc(100vw-2rem)] p-0">
        <Command>
          <CommandInput placeholder="Search items…" aria-label="Search items" />
          <CommandList>
            <CommandEmpty className="p-4 text-sm text-muted-foreground">
              No saved items found. You can still type an item directly into the document.
            </CommandEmpty>
            <CommandGroup>
              {services.map((service) => (
                <CommandItem
                  key={service.id}
                  value={`${service.description} ${service.sac} ${service.id}`}
                  onSelect={() => {
                    onSelect(service);
                    setOpen(false);
                  }}
                >
                  <div className="min-w-0 flex-1">
                    <span className="block whitespace-normal font-medium">
                      {service.description}
                    </span>
                    <span className="block text-xs text-muted-foreground">
                      {service.kind === "goods" ? "HSN" : "SAC"} {service.sac}
                      {service.unit ? ` · ${service.unit}` : ""} · GST {Number(service.gst_rate)}%
                    </span>
                  </div>
                  <span className="shrink-0 tabular-nums">
                    {new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR" }).format(
                      Number(service.unit_price),
                    )}
                  </span>
                </CommandItem>
              ))}
            </CommandGroup>
          </CommandList>
        </Command>
      </PopoverContent>
    </Popover>
  );
}
