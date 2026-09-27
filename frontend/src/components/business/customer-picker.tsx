// Adapted from Midday 51587319f26a0ffaa9dfccab1920373cb65689b7:
// apps/dashboard/src/components/select-customer.tsx and
// apps/dashboard/src/components/forms/customer-form.tsx.
// Retains search -> create with the search text -> select saved customer without
// leaving the invoice. Nila supplies domestic GST fields and its Phoenix API.

import { useQueryClient } from "@tanstack/react-query";
import { useParams } from "@tanstack/react-router";
import { ChevronDownIcon, PlusIcon } from "lucide-react";
import { type FormEvent, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import {
  Dialog as Sheet,
  DialogContent as SheetContent,
  DialogDescription as SheetDescription,
  DialogHeader as SheetHeader,
  DialogTitle as SheetTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Textarea } from "@/components/ui/textarea";
import {
  BusinessApiError,
  type BusinessBootstrap,
  type BusinessCustomer,
  businessRequest,
} from "@/lib/business-api";
import { StateCombobox } from "./state-combobox";

type Props = {
  customers: BusinessCustomer[];
  states: { code: string; name: string }[];
  value: string | number;
  onSelect: (customer: BusinessCustomer) => void;
  disabled?: boolean;
};
type CustomerForm = { name: string; gstin: string; address: string; state_code: string };

export function CustomerPicker({ customers, states, value, onSelect, disabled }: Props) {
  const { businessId } = useParams({ strict: false }) as { businessId: string };
  const cache = useQueryClient();
  const trigger = useRef<HTMLButtonElement>(null);
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [sheetOpen, setSheetOpen] = useState(false);
  const [editing, setEditing] = useState<number | null>(null);
  const [form, setForm] = useState<CustomerForm>({
    name: "",
    gstin: "",
    address: "",
    state_code: "",
  });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<Error | null>(null);
  const selected = customers.find((customer) => customer.id === Number(value));

  function openForm(customer?: BusinessCustomer) {
    setEditing(customer?.id ?? null);
    setForm({
      name: customer?.name ?? search.trim(),
      gstin: customer?.gstin ?? "",
      address: customer?.address ?? "",
      state_code: customer?.state_code ?? "",
    });
    setError(null);
    setOpen(false);
    setSheetOpen(true);
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    // A portalled customer form is still a React child of the invoice form.
    event.stopPropagation();
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      const { customer } = await businessRequest(
        editing ? "updateBusinessCustomer" : "createBusinessCustomer",
        { businessId, id: editing ?? undefined, body: { customer: form } },
      );
      cache.setQueryData<BusinessBootstrap>(["business", businessId], (data) =>
        data
          ? {
              ...data,
              customers: [...data.customers.filter((item) => item.id !== customer.id), customer],
            }
          : data,
      );
      onSelect(customer);
      setSheetOpen(false);
      setSearch("");
      void cache.invalidateQueries({ queryKey: ["business", businessId] });
    } catch (failure) {
      setError(failure instanceof Error ? failure : new Error("The customer could not be saved."));
    } finally {
      setBusy(false);
    }
  }

  const fieldErrors = error instanceof BusinessApiError ? Object.entries(error.fields) : [];

  return (
    <>
      <div className="flex min-w-0 items-start gap-2">
        <Popover
          open={open}
          onOpenChange={(next) => {
            setOpen(next);
            if (next) setSearch("");
          }}
        >
          <PopoverTrigger
            ref={trigger}
            id="business-customer"
            type="button"
            disabled={disabled}
            render={
              <Button
                type="button"
                variant="outline"
                disabled={disabled}
                className="h-9 min-w-0 max-w-sm flex-1 justify-between rounded-sm border-border/70 bg-muted/30 px-3 text-left font-medium hover:border-ring/60 hover:bg-accent/50"
              />
            }
            aria-label="Select customer"
            aria-expanded={open}
          >
            <span className="min-w-0 truncate">{selected?.name ?? "Select customer"}</span>
            <ChevronDownIcon className="size-4 shrink-0 text-muted-foreground" />
          </PopoverTrigger>
          <PopoverContent
            align="start"
            className="w-80 max-w-[calc(100vw-2rem)] p-0"
            finalFocus={sheetOpen ? false : undefined}
          >
            <Command>
              <CommandInput
                id="business-customer-search"
                value={search}
                onValueChange={setSearch}
                placeholder="Search customers…"
                aria-label="Search customers"
              />
              <CommandList>
                <CommandEmpty className="px-3 py-3 text-sm text-muted-foreground">
                  No customers found.
                </CommandEmpty>
                <CommandGroup>
                  {customers.map((customer) => (
                    <CommandItem
                      key={customer.id}
                      value={`${customer.name} ${customer.gstin ?? ""} ${customer.id}`}
                      onSelect={() => {
                        onSelect(customer);
                        setOpen(false);
                      }}
                    >
                      <span className="min-w-0">
                        <span className="block truncate">{customer.name}</span>
                        {customer.gstin && (
                          <span className="block text-xs text-muted-foreground">
                            {customer.gstin}
                          </span>
                        )}
                      </span>
                    </CommandItem>
                  ))}
                </CommandGroup>
                <CommandGroup forceMount className="border-t">
                  <CommandItem
                    id="business-create-customer"
                    forceMount
                    value="create-customer"
                    onSelect={() => openForm()}
                  >
                    <PlusIcon className="size-4" />
                    {search.trim() ? `Create “${search.trim()}”` : "Create customer"}
                  </CommandItem>
                </CommandGroup>
              </CommandList>
            </Command>
          </PopoverContent>
        </Popover>
        {selected && !disabled && (
          <Button
            id="business-edit-customer"
            type="button"
            variant="ghost"
            size="sm"
            className="h-auto shrink-0 px-1 py-1 text-xs text-muted-foreground"
            onClick={() => openForm(selected)}
          >
            Edit
          </Button>
        )}
      </div>
      <Sheet
        open={sheetOpen}
        onOpenChange={(next) => {
          if (!busy) setSheetOpen(next);
        }}
      >
        <SheetContent
          id="business-customer-sheet"
          className="inset-y-0 right-0 left-auto flex h-dvh w-full max-w-full translate-x-0 translate-y-0 flex-col overflow-y-auto rounded-none sm:max-w-md"
          finalFocus={trigger}
          showCloseButton={!busy}
        >
          <SheetHeader>
            <SheetTitle>{editing ? "Edit customer" : "Create customer"}</SheetTitle>
            <SheetDescription>Save this customer and return to your invoice.</SheetDescription>
          </SheetHeader>
          <form
            id="business-inline-customer-form"
            onSubmit={save}
            className="flex flex-1 flex-col gap-5 px-4 pb-6"
          >
            <fieldset disabled={busy} className="space-y-5">
              <div className="space-y-2">
                <label className="text-sm font-medium" htmlFor="invoice-customer-name">
                  Customer name
                </label>
                <Input
                  id="invoice-customer-name"
                  value={form.name}
                  maxLength={200}
                  required
                  autoComplete="organization"
                  onChange={(event) => setForm({ ...form, name: event.target.value })}
                />
              </div>
              <div className="space-y-2">
                <label className="text-sm font-medium" htmlFor="invoice-customer-gstin">
                  GSTIN (optional)
                </label>
                <Input
                  id="invoice-customer-gstin"
                  value={form.gstin}
                  maxLength={15}
                  onChange={(event) => {
                    const gstin = event.target.value.toUpperCase();
                    const state = states.find((item) => item.code === gstin.slice(0, 2));
                    setForm({ ...form, gstin, state_code: state?.code ?? form.state_code });
                  }}
                />
              </div>
              <div className="space-y-2">
                <label className="text-sm font-medium" htmlFor="invoice-customer-address">
                  Billing address
                </label>
                <Textarea
                  id="invoice-customer-address"
                  value={form.address}
                  rows={3}
                  maxLength={2000}
                  required
                  autoComplete="street-address"
                  onChange={(event) => setForm({ ...form, address: event.target.value })}
                />
              </div>
              <div className="space-y-2">
                <label className="text-sm font-medium" htmlFor="invoice-customer-state">
                  State
                </label>
                <StateCombobox
                  id="invoice-customer-state"
                  states={states}
                  value={form.state_code}
                  onChange={(state) => setForm({ ...form, state_code: state })}
                  required
                />
              </div>
            </fieldset>
            {error && (
              <div role="alert" className="text-sm text-destructive">
                <p>{error.message}</p>
                {fieldErrors.map(([field, messages]) => (
                  <p key={field}>
                    {field.replaceAll("_", " ")}:{" "}
                    {Array.isArray(messages) ? messages.join(", ") : String(messages)}
                  </p>
                ))}
              </div>
            )}
            <div className="mt-auto flex justify-end gap-2 pt-3">
              <Button
                type="button"
                variant="outline"
                disabled={busy}
                onClick={() => setSheetOpen(false)}
              >
                Cancel
              </Button>
              <Button id="business-save-customer" type="submit" disabled={busy}>
                {busy ? "Saving…" : "Save customer"}
              </Button>
            </div>
          </form>
        </SheetContent>
      </Sheet>
    </>
  );
}
