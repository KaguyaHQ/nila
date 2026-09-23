import { useState, type FormEvent } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { Plus, Pencil, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { NativeSelect } from "@/components/ui/native-select";
import { Dialog, DialogContent, DialogTitle, DialogDescription } from "@/components/ui/dialog";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { BusinessApiError, businessRequest, type BusinessService } from "@/lib/business-api";

const blank = { description: "", sac: "", unit: "service", unit_price: "", gst_rate: "18" };
const rates = ["0.1", "0.25", "1", "1.5", "3", "5", "6", "7.5", "12", "18", "28", "40"];
export function ServicesPage({ services }: { services: BusinessService[] }) {
  const cache = useQueryClient();
  const [open, setOpen] = useState(false);
  const [editing, setEditing] = useState<number | null>(null);
  const [form, setForm] = useState(blank);
  const [removing, setRemoving] = useState<BusinessService | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [busy, setBusy] = useState(false);
  function edit(service?: BusinessService) {
    setEditing(service?.id ?? null);
    setForm(
      service
        ? {
            description: service.description,
            sac: service.sac,
            unit: service.unit ?? "",
            unit_price: service.unit_price,
            gst_rate: String(Number(service.gst_rate)),
          }
        : blank,
    );
    setError(null);
    setOpen(true);
  }
  async function save(event: FormEvent) {
    event.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await businessRequest(editing ? "updateBusinessService" : "createBusinessService", {
        id: editing ?? undefined,
        body: { service: form },
      });
      await cache.invalidateQueries({ queryKey: ["business"] });
      setOpen(false);
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(false);
    }
  }
  async function remove() {
    if (!removing || busy) return;
    setBusy(true);
    setError(null);
    try {
      await businessRequest("deleteBusinessService", { id: removing.id });
      await cache.invalidateQueries({ queryKey: ["business"] });
      setRemoving(null);
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(false);
    }
  }
  const errorView = error && (
    <div role="alert" className="space-y-1 text-sm text-destructive">
      <p>{error.message}</p>
      {error instanceof BusinessApiError &&
        Object.entries(error.fields).map(([field, value]) => (
          <p key={field}>
            {field.replaceAll("_", " ")}: {Array.isArray(value) ? value.join(", ") : String(value)}
          </p>
        ))}
    </div>
  );
  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold">Services</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            Save service details to reuse in quotations and invoices.
          </p>
        </div>
        <Button onClick={() => edit()}>
          <Plus /> Add service
        </Button>
      </div>
      <div className="overflow-hidden rounded-lg border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Description</TableHead>
              <TableHead>SAC</TableHead>
              <TableHead>Unit</TableHead>
              <TableHead className="text-right">Rate</TableHead>
              <TableHead className="text-right">GST</TableHead>
              <TableHead>
                <span className="sr-only">Actions</span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {services.map((service) => (
              <TableRow key={service.id}>
                <TableCell className="max-w-sm whitespace-pre-line font-medium">
                  {service.description}
                </TableCell>
                <TableCell>{service.sac}</TableCell>
                <TableCell>{service.unit || "—"}</TableCell>
                <TableCell className="text-right tabular-nums">
                  {new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR" }).format(
                    Number(service.unit_price),
                  )}
                </TableCell>
                <TableCell className="text-right">{Number(service.gst_rate)}%</TableCell>
                <TableCell>
                  <div className="flex justify-end gap-1">
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      aria-label={`Edit ${service.description}`}
                      onClick={() => edit(service)}
                    >
                      <Pencil />
                    </Button>
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      aria-label={`Delete ${service.description}`}
                      onClick={() => {
                        setRemoving(service);
                        setError(null);
                      }}
                    >
                      <Trash2 />
                    </Button>
                  </div>
                </TableCell>
              </TableRow>
            ))}
            {services.length === 0 && (
              <TableRow>
                <TableCell colSpan={6} className="py-14 text-center text-muted-foreground">
                  No saved services yet. Add a service you bill for regularly.
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </div>
      <Dialog
        open={open}
        onOpenChange={(next) => {
          if (!busy) setOpen(next);
        }}
      >
        <DialogContent
          className="inset-y-0 right-0 left-auto flex h-dvh w-full max-w-full translate-x-0 translate-y-0 flex-col overflow-y-auto rounded-none sm:max-w-md"
          showCloseButton={!busy}
        >
          <DialogTitle>{editing ? "Edit service" : "New service"}</DialogTitle>
          <DialogDescription>
            These defaults are copied into a line when you choose this service.
          </DialogDescription>
          <form id="business-service-form" onSubmit={save} className="flex flex-1 flex-col gap-5">
            <fieldset disabled={busy} className="space-y-5">
              <div className="space-y-2">
                <label htmlFor="service-description" className="text-sm font-medium">
                  Description
                </label>
                <Textarea
                  id="service-description"
                  required
                  maxLength={1000}
                  value={form.description}
                  onChange={(e) => setForm({ ...form, description: e.target.value })}
                />
              </div>
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <label htmlFor="service-sac" className="text-sm font-medium">
                    SAC
                  </label>
                  <Input
                    id="service-sac"
                    required
                    pattern="99[0-9]{4}"
                    maxLength={6}
                    inputMode="numeric"
                    value={form.sac}
                    onChange={(e) => setForm({ ...form, sac: e.target.value })}
                  />
                </div>
                <div className="space-y-2">
                  <label htmlFor="service-unit" className="text-sm font-medium">
                    Unit
                  </label>
                  <Input
                    id="service-unit"
                    required
                    maxLength={30}
                    placeholder="e.g. hour"
                    value={form.unit}
                    onChange={(e) => setForm({ ...form, unit: e.target.value })}
                  />
                </div>
              </div>
              <div className="grid grid-cols-2 gap-4">
                <div className="space-y-2">
                  <label htmlFor="service-price" className="text-sm font-medium">
                    Rate (₹)
                  </label>
                  <Input
                    id="service-price"
                    required
                    type="number"
                    min="0.01"
                    step="0.01"
                    value={form.unit_price}
                    onChange={(e) => setForm({ ...form, unit_price: e.target.value })}
                  />
                </div>
                <div className="space-y-2">
                  <label htmlFor="service-gst" className="text-sm font-medium">
                    GST %
                  </label>
                  <NativeSelect
                    id="service-gst"
                    value={form.gst_rate}
                    onChange={(e) => setForm({ ...form, gst_rate: e.target.value })}
                  >
                    {rates.map((rate) => (
                      <option key={rate} value={rate}>
                        {rate}%
                      </option>
                    ))}
                  </NativeSelect>
                </div>
              </div>
            </fieldset>
            {errorView}
            <div className="mt-auto flex justify-end gap-2 pt-4">
              <Button
                type="button"
                variant="outline"
                disabled={busy}
                onClick={() => setOpen(false)}
              >
                Cancel
              </Button>
              <Button type="submit" disabled={busy}>
                {busy ? "Saving…" : "Save service"}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
      <Dialog
        open={Boolean(removing)}
        onOpenChange={(next) => {
          if (!next && !busy) setRemoving(null);
        }}
      >
        <DialogContent showCloseButton={!busy}>
          <DialogTitle>Remove saved service?</DialogTitle>
          <DialogDescription>
            Existing quotations and invoices keep their copied service details.
          </DialogDescription>
          <p className="text-sm font-medium">{removing?.description}</p>
          {errorView}
          <div className="flex justify-end gap-2">
            <Button variant="outline" disabled={busy} onClick={() => setRemoving(null)}>
              Cancel
            </Button>
            <Button variant="destructive" disabled={busy} onClick={remove}>
              {busy ? "Removing…" : "Remove service"}
            </Button>
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}
