import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Combobox,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxInput,
  ComboboxItem,
  ComboboxList,
  ComboboxTrigger,
} from "@/components/ui/combobox";

type State = { code: string; name: string };

export function StateCombobox({
  id,
  states,
  value,
  onChange,
  disabled = false,
  label = "State",
  inline = false,
  required = false,
}: {
  id: string;
  states: State[];
  value: string;
  onChange: (code: string) => void;
  disabled?: boolean;
  label?: string;
  inline?: boolean;
  required?: boolean;
}) {
  const selected = states.find((state) => state.code === value) ?? null;
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");

  return (
    <Combobox
      items={states}
      value={selected}
      open={open}
      onOpenChange={(next) => {
        setOpen(next);
        if (next) setQuery("");
      }}
      inputValue={query}
      onInputValueChange={setQuery}
      onValueChange={(state) => {
        onChange(state?.code ?? "");
        setQuery("");
        // Base UI may report its open state after the selection callback.
        // Close on the next task so choosing a state always wins that race.
        setTimeout(() => setOpen(false), 0);
      }}
      itemToStringLabel={(state) => state.name}
      isItemEqualToValue={(a, b) => a.code === b.code}
      disabled={disabled}
    >
      {required && (
        <input
          aria-label={label}
          className="pointer-events-none absolute h-px w-px opacity-0"
          required
          tabIndex={-1}
          value={value}
          onChange={() => {}}
          onInvalid={(event) => {
            event.preventDefault();
            document.getElementById(id)?.focus();
          }}
        />
      )}
      <ComboboxTrigger
        id={id}
        aria-label={label}
        render={
          <Button
            type="button"
            variant={inline ? "ghost" : "outline"}
            className={
              inline
                ? "h-8 min-w-44 justify-between rounded-sm border border-border/70 bg-muted/30 px-2 font-normal hover:border-ring/60 hover:bg-accent/50 disabled:border-transparent disabled:bg-transparent"
                : "w-full justify-between font-normal"
            }
          />
        }
      >
        <span className={selected ? "truncate" : "truncate text-muted-foreground"}>
          {selected?.name ?? "Choose state"}
        </span>
      </ComboboxTrigger>
      <ComboboxContent className="w-72">
        <ComboboxInput
          aria-label={`Search ${label.toLowerCase()}`}
          placeholder="Search states…"
          showTrigger={false}
        />
        <ComboboxEmpty>No states found.</ComboboxEmpty>
        <ComboboxList>
          {(state: State) => (
            <ComboboxItem key={state.code} value={state}>
              {state.name}
            </ComboboxItem>
          )}
        </ComboboxList>
      </ComboboxContent>
    </Combobox>
  );
}
