/**
 * Adapted from Midday invoice/form.tsx (paper composition), meta.tsx and
 * line-items.tsx (inline column grid and row/add controls).
 * Copyright (c) 2023-present Midday Labs AB. AGPL-3.0.
 * Source: https://github.com/midday-ai/midday/tree/51587319f26a0ffaa9dfccab1920373cb65689b7/apps/dashboard/src/components/invoice
 * Nila adaptation: controlled React state replaces RHF; GST/SAC fields replace
 * template settings, and every calculated amount comes from Phoenix.
 */
import { useState } from "react";
import { Link } from "react-router-dom";
import { Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { InlineInput, InlineSelect, InlineTextarea } from "./inline-input";
import { ServicePicker } from "./service-picker";
import { CustomerPicker } from "./customer-picker";
import type { BusinessBootstrap, BusinessInvoice, BusinessLine, InvoiceInput } from "@/lib/business-api";

export type InvoiceCalculation = import("@/lib/generated/workspace").components["schemas"]["InvoiceCalculation"];

const amount = (value?: number) => typeof value === "number" ? new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR" }).format(value / 100) : "—";
const columns = "sm:grid-cols-[minmax(0,1fr)_68px_48px_80px_60px_94px_24px]";
const rates = ["0.1", "0.25", "1", "1.5", "3", "5", "6", "7.5", "12", "18", "28", "40"];

export function InvoiceDocument({ value, saved, original, business, calculation, calculating, onChange, disabled }: {
  value: InvoiceInput;
  saved?: BusinessInvoice;
  original?: BusinessInvoice;
  business: BusinessBootstrap;
  calculation: InvoiceCalculation | null;
  calculating: boolean;
  onChange: (next: Partial<InvoiceInput>) => void;
  disabled: boolean;
}) {
  const [showReference, setShowReference] = useState(Boolean(value.purchase_order_number || value.purchase_order_date));
  const [showDelivery, setShowDelivery] = useState(Boolean(value.delivery_address));
  const issued = Boolean(saved && saved.status !== "draft");
  const quotation = value.document_type === "quotation";
  const credit = value.document_type === "credit_note";
  const supplier = issued ? saved?.snapshot?.supplier : { name: business.profile?.legal_name || business.business.name, address: business.profile?.address, gstin: business.business.gstin };
  const customer = issued ? saved?.snapshot?.customer : credit ? original?.snapshot?.customer : business.customers.find(item => item.id === Number(value.customer_id));
  const totals = calculation?.totals;
  function lineChange(index: number, field: keyof BusinessLine, next: string) {
    onChange({ lines: value.lines.map((line, i) => i === index ? { ...line, [field]: next } : line) });
  }
  return <article aria-label="Editable invoice" className="relative mx-auto flex min-h-[900px] w-full max-w-[840px] flex-col border bg-background px-5 py-7 sm:px-10 sm:py-9">
    <div className="flex items-start justify-between gap-6">
      <div className="min-w-0 flex-1">
        <h1 className="mb-5 text-2xl font-semibold tracking-tight">{quotation ? "Quotation" : credit ? "Credit note" : "Tax invoice"}</h1>
        <div className="grid max-w-sm grid-cols-[110px_minmax(0,1fr)] sm:grid-cols-[140px_minmax(0,1fr)] items-center gap-x-4 gap-y-1 text-sm">
          <span className="text-muted-foreground">{quotation ? "Quotation no." : credit ? "Credit note no." : "Invoice no."}</span><span className="py-1 font-medium">{saved?.number || (quotation ? "Assigned on finalizing" : "Assigned on issue")}</span>{credit && <><span className="text-muted-foreground">Original invoice</span><span className="py-1">{original?.number || saved?.snapshot?.original_invoice_number || "—"}</span></>}
          <label htmlFor="invoice-date" className="text-muted-foreground">{quotation ? "Quotation date" : credit ? "Credit note date" : "Invoice date"}</label><InlineInput id="invoice-date" type="date" required disabled={disabled} value={value.invoice_date} onChange={e => onChange({ invoice_date: e.target.value })} />
          {!credit && !quotation && <><label htmlFor="invoice-due" className="text-muted-foreground">Due date</label><InlineInput id="invoice-due" aria-label="Due date (optional)" type="date" disabled={disabled} min={value.invoice_date} value={value.due_date || ""} onChange={e => onChange({ due_date: e.target.value })} /></>}
          {quotation && <><label htmlFor="quotation-valid-until" className="text-muted-foreground">Valid until</label><InlineInput id="quotation-valid-until" type="date" disabled={disabled} min={value.invoice_date} value={value.valid_until || ""} onChange={e => onChange({ valid_until: e.target.value })} /></>}
          {showReference && <><label htmlFor="invoice-reference" className="text-muted-foreground">Reference / PO no.</label><InlineInput id="invoice-reference" aria-label="Reference / PO number (optional)" disabled={disabled} maxLength={100} placeholder="Optional" value={value.purchase_order_number || ""} onChange={e => onChange({ purchase_order_number: e.target.value })} /><label htmlFor="invoice-reference-date" className="text-muted-foreground">Reference date</label><InlineInput id="invoice-reference-date" aria-label="Reference date (optional)" disabled={disabled} type="date" value={value.purchase_order_date || ""} onChange={e => onChange({ purchase_order_date: e.target.value })} /></>}
        </div>
        {!showReference && !issued && <Button type="button" variant="ghost" size="sm" disabled={disabled} className="-ml-2 mt-1 text-muted-foreground" onClick={() => setShowReference(true)}><Plus /> Add reference / PO</Button>}
      </div>
      <span className="pt-1 text-xs font-medium uppercase tracking-widest text-muted-foreground">{issued ? quotation ? saved?.status === "issued" ? "Ready" : saved?.status : "Issued" : "Draft"}</span>
    </div>

    <section aria-label={issued ? "Issued party details" : "Invoice parties"} className="mb-6 mt-9 grid grid-cols-1 gap-7 text-sm sm:grid-cols-2 sm:gap-12">
      <div className="space-y-2"><h2 className="text-muted-foreground">From</h2><p className="font-medium">{supplier?.name}</p><p className="whitespace-pre-line text-muted-foreground">{supplier?.address || "Business address not added"}</p>{supplier?.gstin && <p className="text-muted-foreground">GSTIN {supplier.gstin}</p>}{!issued && !supplier?.address && <Link to="/business/settings" className="inline-block underline underline-offset-4">Add business details</Link>}</div>
      <div className="space-y-2"><h2 className="text-muted-foreground">Bill to</h2>{issued || credit ? <p className="font-medium">{customer?.name}</p> : <CustomerPicker customers={business.customers} states={business.states} value={value.customer_id} onSelect={selected => onChange({ customer_id: selected.id })} disabled={disabled} />}{customer && <><p className="whitespace-pre-line text-muted-foreground">{customer.address}</p><p className="text-muted-foreground">{customer.gstin ? `GSTIN ${customer.gstin}` : "Unregistered customer"}</p></>}</div>
    </section>
    {showDelivery ? <div className="mb-5 max-w-sm"><label htmlFor="invoice-delivery" className="mb-1 block text-sm text-muted-foreground">Delivery address (optional)</label><InlineTextarea id="invoice-delivery" disabled={disabled} maxLength={2000} placeholder="Address, if different from billing" value={value.delivery_address || ""} onChange={e => onChange({ delivery_address: e.target.value })} /></div> : !issued && <Button type="button" variant="ghost" size="sm" disabled={disabled} className="-ml-2 mb-4 w-fit text-muted-foreground" onClick={() => setShowDelivery(true)}><Plus /> Add delivery address</Button>}

    <div className="mb-7 flex max-w-sm items-center gap-4 text-sm"><label htmlFor="invoice-pos" className="shrink-0 text-muted-foreground">Place of supply</label><InlineSelect id="invoice-pos" required disabled={disabled} value={value.place_of_supply} onChange={e => onChange({ place_of_supply: e.target.value })}><option value="">Choose state</option>{business.states.map(state => <option key={state.code} value={state.code}>{state.name}</option>)}</InlineSelect></div>

    <section aria-label="Services" className="space-y-3">
      <div className={`hidden gap-3 border-b pb-3 text-xs text-muted-foreground sm:grid ${columns}`}><span>Description</span><span>SAC</span><span className="text-right">Qty</span><span className="text-right">Rate (₹)</span><span className="text-right">GST %</span><span className="text-right">Amount</span><span /></div>
      {value.lines.map((line, index) => <div key={index} className={`group grid grid-cols-2 items-start gap-x-3 gap-y-2 border-b pb-3 text-sm ${columns}`}>
        <div className="col-span-2 min-w-0 sm:col-span-1"><label className="text-xs text-muted-foreground sm:sr-only" htmlFor={`line-${index}-description`}>Description</label><div className="flex min-w-0 items-start gap-1"><InlineTextarea id={`line-${index}-description`} required disabled={disabled} maxLength={1000} placeholder="Service description" value={line.description} onChange={e => lineChange(index, "description", e.target.value)} />{!issued && <ServicePicker index={index} disabled={disabled} services={business.services ?? []} onSelect={service => onChange({ lines: value.lines.map((entry, i) => i === index ? { ...entry, description: service.description, sac: service.sac, unit: service.unit, unit_price: service.unit_price, gst_rate: service.gst_rate } : entry) })} />}</div></div>
        <div className="min-w-0"><label className="text-xs text-muted-foreground sm:sr-only" htmlFor={`line-${index}-sac`}>SAC</label><InlineInput id={`line-${index}-sac`} required disabled={disabled} inputMode="numeric" pattern="99[0-9]{4}" maxLength={6} placeholder="998313" value={line.sac} onChange={e => lineChange(index, "sac", e.target.value)} /></div>
        <div className="min-w-0"><label className="text-xs text-muted-foreground sm:sr-only" htmlFor={`line-${index}-quantity`}>Quantity</label><InlineInput id={`line-${index}-quantity`} required disabled={disabled} type="number" min="0.0001" step="0.0001" value={line.quantity} className="tabular-nums sm:text-right" onChange={e => lineChange(index, "quantity", e.target.value)} />{(!issued || line.unit) && <><label className="sr-only" htmlFor={`line-${index}-unit`}>Unit (optional)</label><InlineInput id={`line-${index}-unit`} disabled={disabled} maxLength={30} placeholder="unit" value={line.unit ?? ""} className="h-6 text-xs text-muted-foreground sm:text-right" onChange={e => lineChange(index, "unit", e.target.value)} /></>}</div>
        <div className="min-w-0"><label className="text-xs text-muted-foreground sm:sr-only" htmlFor={`line-${index}-price`}>Rate (₹)</label><InlineInput id={`line-${index}-price`} required disabled={disabled} type="number" min="0.01" step="0.01" placeholder="0.00" value={line.unit_price} className="tabular-nums sm:text-right" onChange={e => lineChange(index, "unit_price", e.target.value)} /></div>
        <div className="min-w-0"><label className="text-xs text-muted-foreground sm:sr-only" htmlFor={`line-${index}-gst`}>GST %</label><InlineSelect id={`line-${index}-gst`} required disabled={disabled} value={rates.includes(String(Number(line.gst_rate))) ? String(Number(line.gst_rate)) : ""} className="sm:text-right" onChange={e => lineChange(index, "gst_rate", e.target.value)}>{rates.map(rate => <option key={rate} value={rate}>{rate}%</option>)}</InlineSelect></div>
        <div className="flex min-h-8 items-center justify-between sm:justify-end"><span className="text-xs text-muted-foreground sm:hidden">Amount</span><span className="whitespace-nowrap tabular-nums">{amount(calculation?.lines[index]?.taxable_paise)}</span></div>
        <div className="flex justify-end">{!issued && <Button type="button" variant="ghost" size="icon-sm" className="size-7" disabled={disabled || value.lines.length === 1} aria-label={`Remove service ${index + 1}`} onClick={() => onChange({ lines: value.lines.filter((_, i) => i !== index) })}><Trash2 className="size-3.5" /></Button>}</div>
      </div>)}
      {!issued && <Button variant="ghost" size="sm" type="button" disabled={disabled} className="-ml-2 text-muted-foreground" onClick={() => onChange({ lines: [...value.lines, { description: "", sac: "", quantity: "1", unit_price: "", gst_rate: "18" }] })}><Plus /> Add service</Button>}
    </section>

    <div className="mb-12 mt-9 flex justify-end">
      <dl aria-label="Invoice totals" aria-busy={calculating} className="grid w-full max-w-[290px] grid-cols-2 gap-x-6 gap-y-3 text-sm">
        <dt className="text-muted-foreground">Subtotal</dt><dd className="text-right tabular-nums">{amount(totals?.taxable_paise)}</dd>
        {totals ? ([["CGST", totals.cgst_paise], ["SGST", totals.sgst_paise], ["IGST", totals.igst_paise]] as const).filter(([, value]) => value > 0).map(([label, value]) => <div key={label} className="contents"><dt className="text-muted-foreground">{label}</dt><dd className="text-right tabular-nums">{amount(value)}</dd></div>) : <><dt className="text-muted-foreground">GST</dt><dd className="text-right">—</dd></>}
        <dt className="border-t pt-3 font-semibold">Total</dt><dd className="border-t pt-3 text-right font-semibold tabular-nums">{amount(totals?.total_paise)}</dd>
      </dl>
    </div>

    {calculation?.total_in_words && <p className="mb-7 text-sm text-muted-foreground">{calculation.total_in_words}</p>}
    <div className="mt-auto border-t pt-5"><label htmlFor="invoice-notes" className="mb-2 block text-sm text-muted-foreground">Notes (optional)</label><InlineTextarea id="invoice-notes" disabled={disabled} maxLength={2000} placeholder="Payment terms or a note for your customer" value={value.notes || ""} onChange={e => onChange({ notes: e.target.value })} /></div>
  </article>;
}
