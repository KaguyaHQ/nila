import { useState } from "react";
import { Pencil } from "lucide-react";
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

export function InlineLedger({
  name,
  identity,
  label,
  choices,
  forcePicker = false,
  suggestedIdentity,
  suggestedName,
  editable,
  pending,
  onChange,
}: {
  name: string | null;
  identity: string | null;
  label: string;
  choices: { identity: string; name: string }[];

  forcePicker?: boolean;
  suggestedIdentity?: string | null;
  suggestedName?: string | null;

  editable: boolean;
  pending: boolean;
  onChange: (value: string) => void;
}) {
  const [editing, setEditing] = useState(false);
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const selected = choices.find((item) => item.identity === identity) ?? null;

  const edit = () => {
    setQuery("");
    setEditing(true);
    setOpen(true);
  };

  const picker = editable && (forcePicker || editing || (!identity && !suggestedIdentity));

  return (
    <div className="min-w-0 space-y-1">
      {picker ? (
        <div className="flex w-full min-w-0 max-w-lg items-center gap-1">
          <Combobox
            items={choices}
            value={selected}
            open={open}
            onOpenChange={(next) => {
              setOpen(next);
              if (next) setQuery("");
            }}
            inputValue={query}
            onInputValueChange={setQuery}
            itemToStringLabel={(item) => item.name}
            isItemEqualToValue={(a, b) => a.identity === b.identity}
            disabled={pending}
            onValueChange={(value) => {
              if (value) {
                onChange(value.identity);
                setEditing(false);
                setOpen(false);
                setQuery("");
              }
            }}
          >
            <ComboboxTrigger
              aria-label={label}
              render={
                <Button variant="outline" className="min-w-0 flex-1 justify-between font-normal" />
              }
            >
              <span className="min-w-0 truncate">{selected?.name ?? "Choose ledger"}</span>
            </ComboboxTrigger>
            <ComboboxContent className="w-[max(var(--anchor-width),20rem)] min-w-0">
              <ComboboxInput
                aria-label={`Search ${label.toLowerCase()}`}
                placeholder="Search ledgers…"
                showTrigger={false}
              />
              <ComboboxEmpty>No ledgers found.</ComboboxEmpty>
              <ComboboxList>
                {(item: { identity: string; name: string }) => (
                  <ComboboxItem key={item.identity} value={item} className="whitespace-normal">
                    {item.name}
                  </ComboboxItem>
                )}
              </ComboboxList>
            </ComboboxContent>
          </Combobox>
          {editing && !forcePicker && (
            <Button variant="ghost" size="sm" className="shrink-0" disabled={pending} onClick={() => setEditing(false)}>
              Cancel
            </Button>
          )}
        </div>
      ) : (
        <div className="flex items-center gap-1">
          <span className="min-w-0 wrap-anywhere">{name || (suggestedName ? `Suggested: ${suggestedName}` : "Choose ledger")}</span>
          {editable && identity && (
            <Button
              variant="ghost"
              size="icon-sm"
              aria-label={`Change ${label}`}
              disabled={pending}
              onClick={edit}
            >
              <Pencil />
            </Button>
          )}
        </div>
      )}
      {editable && !identity && suggestedIdentity && !editing && (
        <div className="flex gap-2">
          <Button
            variant="outline"
            size="sm"
            disabled={pending}
            aria-label={`Confirm ${label}`}
            onClick={() => onChange(suggestedIdentity)}
          >
            Confirm
          </Button>
          <Button
            variant="ghost"
            size="sm"
            disabled={pending}
            aria-label={`Change ${label}`}
            onClick={edit}
          >
            Change
          </Button>
        </div>
      )}
    </div>
  );
}
