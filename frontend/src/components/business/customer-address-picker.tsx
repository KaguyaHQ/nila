import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Check, ChevronDown, Plus, Pencil } from "lucide-react";
import { type FormEvent, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Command,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { NativeSelect } from "@/components/ui/native-select";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Textarea } from "@/components/ui/textarea";
import {
  BusinessApiError,
  type BusinessBootstrap,
  type BusinessCustomerAddress,
  businessRequest,
} from "@/lib/business-api";
import { StateCombobox } from "./state-combobox";

type AddressUsage = "billing" | "shipping" | "either";
type AddressDraft = Omit<BusinessCustomerAddress, "id" | "customer_id">;

export function CustomerAddressPicker({
  customerId,
  addresses,
  type,
  value,
  states,
  onSelect,
  disabled,
}: {
  customerId: number;
  addresses: BusinessCustomerAddress[];
  type: "billing" | "shipping";
  value: string | number | null | undefined;
  states: { code: string; name: string }[];
  onSelect: (address: BusinessCustomerAddress | null) => void;
  disabled?: boolean;
}) {
  const cache = useQueryClient();
  const trigger = useRef<HTMLButtonElement>(null);
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState("");
  const [formOpen, setFormOpen] = useState(false);
  const [editing, setEditing] = useState<BusinessCustomerAddress | null>(null);
  const [draft, setDraft] = useState<AddressDraft>(() => blankAddress(type));
  const submitInFlight = useRef(false);
  const addressSave = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: async (input: {
      editingId: number | null;
      customerId: number;
      address: AddressDraft;
    }) => {
      const result = input.editingId
        ? await businessRequest("updateBusinessCustomerAddress", {
            customer_id: input.customerId,
            id: input.editingId,
            body: { address: input.address },
          })
        : await businessRequest("createBusinessCustomerAddress", {
            customer_id: input.customerId,
            body: { address: input.address },
          });
      return result.address;
    },
    onSuccess: (address) => {
      cache.setQueryData<BusinessBootstrap>(["business"], (current) => {
        if (!current) return current;
        const currentAddresses = current.customer_addresses ?? [];
        return {
          ...current,
          customer_addresses: [
            ...currentAddresses.filter((entry) => entry.id !== address.id),
            address,
          ],
        };
      });
      onSelect(address);
      setFormOpen(false);
      void cache.invalidateQueries({ queryKey: ["business"] });
    },
  });
  const busy = addressSave.isPending;
  const error = addressSave.error;
  const choices = addresses.filter(
    (address) => address.usage === type || address.usage === "either",
  );
  const selected = addresses.find((address) => address.id === Number(value));

  function startAdd() {
    addressSave.reset();
    setEditing(null);
    setDraft(blankAddress(type));
    setOpen(false);
    setFormOpen(true);
  }

  function startEdit() {
    if (!selected) return;
    addressSave.reset();
    setEditing(selected);
    setDraft({
      label: selected.label,
      address: selected.address,
      state_code: selected.state_code,
      gstin: selected.gstin,
      usage: selected.usage,
      is_primary_billing: selected.is_primary_billing,
      is_primary_shipping: selected.is_primary_shipping,
    });
    setFormOpen(true);
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    event.stopPropagation();
    if (submitInFlight.current || addressSave.isPending) return;
    submitInFlight.current = true;
    try {
      await addressSave.mutateAsync({
        customerId,
        editingId: editing?.id ?? null,
        address: draft,
      });
    } catch {
      // The mutation keeps its error for the dialog to display.
    } finally {
      submitInFlight.current = false;
    }
  }

  const fieldErrors = error instanceof BusinessApiError ? Object.entries(error.fields) : [];

  return (
    <>
      <div className="flex min-w-0 items-center gap-1.5">
        <Popover
          open={open}
          onOpenChange={(next) => {
            setOpen(next);
            if (next) setSearch("");
          }}
        >
          <PopoverTrigger
            ref={trigger}
            render={
              <Button
                type="button"
                variant="outline"
                disabled={disabled}
                className="h-8 min-w-0 max-w-sm flex-1 justify-between px-2 text-left font-normal"
              />
            }
            aria-label={`Select ${type} address`}
            aria-expanded={open}
          >
            <span className="truncate">
              {selected?.label ?? (type === "billing" ? "Customer's primary address" : "Choose saved address")}
            </span>
            <ChevronDown className="size-4 shrink-0 text-muted-foreground" />
          </PopoverTrigger>
          <PopoverContent align="start" className="w-80 p-0" finalFocus={formOpen ? false : undefined}>
            <Command>
              <CommandInput
                value={search}
                onValueChange={setSearch}
                placeholder={`Search ${type} addresses…`}
                aria-label={`Search ${type} addresses`}
              />
              <CommandList>
                <CommandEmpty className="px-3 py-3 text-sm text-muted-foreground">
                  No saved addresses found.
                </CommandEmpty>
                <CommandGroup>
                  {type === "shipping" && (
                    <CommandItem
                      value="manual-shipping-address"
                      onSelect={() => {
                        onSelect(null);
                        setOpen(false);
                      }}
                    >
                      <Check className={!value ? "size-4 opacity-100" : "size-4 opacity-0"} />
                      Enter address manually
                    </CommandItem>
                  )}
                  {choices.map((address) => (
                    <CommandItem
                      key={address.id}
                      value={`${address.label} ${address.address} ${address.state_code} ${address.gstin ?? ""}`}
                      onSelect={() => {
                        onSelect(address);
                        setOpen(false);
                      }}
                    >
                      <Check className={address.id === Number(value) ? "size-4 opacity-100" : "size-4 opacity-0"} />
                      <span className="min-w-0">
                        <span className="block truncate">{address.label}</span>
                        <span className="block truncate text-xs text-muted-foreground">
                          {address.state_code}{address.gstin ? ` · ${address.gstin}` : ""}
                        </span>
                      </span>
                    </CommandItem>
                  ))}
                </CommandGroup>
                <CommandGroup forceMount className="border-t">
                  <CommandItem value="add-address" forceMount onSelect={startAdd}>
                    <Plus className="size-4" /> Add saved address
                  </CommandItem>
                </CommandGroup>
              </CommandList>
            </Command>
          </PopoverContent>
        </Popover>
        {selected && !disabled && (
          <Button type="button" variant="ghost" size="icon-sm" aria-label="Edit selected address" onClick={startEdit}>
            <Pencil className="size-3.5" />
          </Button>
        )}
      </div>
      <Dialog open={formOpen} onOpenChange={(next) => !busy && setFormOpen(next)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>{editing ? "Edit saved address" : "Add saved address"}</DialogTitle>
            <DialogDescription>Save an address for this customer and use it on future invoices.</DialogDescription>
          </DialogHeader>
          <form onSubmit={save} className="space-y-4">
            <fieldset disabled={busy} className="space-y-4">
              <div className="space-y-2">
                <Label htmlFor="customer-address-label">Label</Label>
                <Input id="customer-address-label" required maxLength={100} value={draft.label} placeholder="Bengaluru Office" onChange={(event) => setDraft({ ...draft, label: event.target.value })} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="customer-address-text">Address</Label>
                <Textarea id="customer-address-text" required maxLength={2000} rows={3} value={draft.address} onChange={(event) => setDraft({ ...draft, address: event.target.value })} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="customer-address-state">State</Label>
                <StateCombobox id="customer-address-state" states={states} value={draft.state_code} required onChange={(state_code) => setDraft({ ...draft, state_code })} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="customer-address-gstin">GSTIN (optional)</Label>
                <Input id="customer-address-gstin" maxLength={15} value={draft.gstin ?? ""} onChange={(event) => setDraft({ ...draft, gstin: event.target.value.toUpperCase() })} />
              </div>
              <div className="space-y-2">
                <Label htmlFor="customer-address-usage">Use this address for</Label>
                <NativeSelect
                  id="customer-address-usage"
                  className="w-full"
                  value={draft.usage}
                  onChange={(event) => {
                    const usage = event.target.value as AddressUsage;
                    setDraft({
                      ...draft,
                      usage,
                      is_primary_billing:
                        usage === "shipping" ? false : draft.is_primary_billing,
                      is_primary_shipping:
                        usage === "billing" ? false : draft.is_primary_shipping,
                    });
                  }}
                >
                  <option value="billing">Billing</option>
                  <option value="shipping">Shipping</option>
                  <option value="either">Billing or shipping</option>
                </NativeSelect>
              </div>
              {draft.usage !== "shipping" && (
                <label className="flex items-center gap-2 text-sm">
                  <Checkbox
                    checked={draft.is_primary_billing}
                    onCheckedChange={(checked) =>
                      setDraft({ ...draft, is_primary_billing: Boolean(checked) })
                    }
                  />
                  Default billing address
                </label>
              )}
              {draft.usage !== "billing" && (
                <label className="flex items-center gap-2 text-sm">
                  <Checkbox
                    checked={draft.is_primary_shipping}
                    onCheckedChange={(checked) =>
                      setDraft({ ...draft, is_primary_shipping: Boolean(checked) })
                    }
                  />
                  Default shipping address
                </label>
              )}
            </fieldset>
            {error && (
              <div role="alert" className="text-sm text-destructive">
                <p>{error.message}</p>
                {fieldErrors.map(([field, messages]) => (
                  <p key={field}>{field.replaceAll("_", " ")}: {Array.isArray(messages) ? messages.join(", ") : String(messages)}</p>
                ))}
              </div>
            )}
            <div className="flex justify-end gap-2">
              <Button type="button" variant="outline" disabled={busy} onClick={() => setFormOpen(false)}>Cancel</Button>
              <Button type="submit" disabled={busy}>{busy ? "Saving…" : "Save address"}</Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
    </>
  );
}

function blankAddress(type: "billing" | "shipping"): AddressDraft {
  return {
    label: "",
    address: "",
    state_code: "",
    gstin: null,
    usage: type,
    is_primary_billing: false,
    is_primary_shipping: false,
  };
}
