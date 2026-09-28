/**
 * Adapted from Midday invoice/form.tsx (paper composition), meta.tsx and
 * line-items.tsx (inline column grid and row/add controls).
 * Copyright (c) 2023-present Midday Labs AB. AGPL-3.0.
 * Source: https://github.com/midday-ai/midday/tree/51587319f26a0ffaa9dfccab1920373cb65689b7/apps/dashboard/src/components/invoice
 * Nila adaptation: controlled React state replaces RHF; GST/SAC fields replace
 * template settings, and every calculated amount comes from Phoenix.
 */

import { Link, useParams } from "@tanstack/react-router";
import { Plus, Trash2 } from "lucide-react";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { SelectFieldOption } from "@/components/ui/select-field";
import type {
  BusinessBootstrap,
  BusinessInvoice,
  BusinessLine,
  InvoiceInput,
} from "@/lib/business-api";
import { CustomerPicker } from "./customer-picker";
import { CustomerAddressPicker } from "./customer-address-picker";
import { BusinessDateField } from "./date-field";
import { FinalizedQuotationDocument } from "./finalized-quotation-document";
import { InlineInput, InlineSelect, InlineTextarea } from "./inline-input";
import { ServicePicker } from "./service-picker";
import { StateCombobox } from "./state-combobox";

export type InvoiceCalculation =
  import("@/lib/generated/workspace").components["schemas"]["InvoiceCalculation"];

const amount = (value?: number) =>
  typeof value === "number"
    ? new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR" }).format(value / 100)
    : "—";
const columns = "lg:grid-cols-[82px_minmax(180px,1fr)_92px_64px_84px_90px_84px_104px_32px]";
const rates = ["0.1", "0.25", "1", "1.5", "3", "5", "6", "7.5", "12", "18", "28", "40"];
const rateItems = rates.map((rate) => ({ label: `${rate}%`, value: rate }));

export function InvoiceDocument({
  value,
  saved,
  original,
  business,
  calculation,
  calculating,
  onChange,
  onShippingInteraction,
  nextQuotationNumber,
  onChangeQuotationNumbering,
  disabled,
}: {
  value: InvoiceInput;
  saved?: BusinessInvoice;
  original?: BusinessInvoice;
  business: BusinessBootstrap;
  calculation: InvoiceCalculation | null;
  calculating: boolean;
  onChange: (next: Partial<InvoiceInput>) => void;
  onShippingInteraction: (interacted: boolean) => void;
  nextQuotationNumber?: string;
  onChangeQuotationNumbering?: () => void;
  disabled: boolean;
}) {
  const { businessId } = useParams({ strict: false }) as { businessId: string };
  const quotation = value.document_type === "quotation";
  const [showReference, setShowReference] = useState(
    Boolean(value.purchase_order_number || (!quotation && value.purchase_order_date)),
  );
  const [showDelivery, setShowDelivery] = useState(Boolean(value.delivery_address));
  const issued = Boolean(saved && saved.status !== "draft");
  const showSubject = quotation || Boolean(saved?.subject || original?.subject);
  const credit = value.document_type === "credit_note";
  const supplier = issued
    ? saved?.snapshot?.supplier
    : {
        name: business.profile?.legal_name || business.business.name,
        address: business.profile?.address,
        gstin: business.business.gstin,
        phone: business.profile?.phone,
        email: business.profile?.email,
      };
  const customer = issued
    ? saved?.snapshot?.customer
    : credit
      ? original?.snapshot?.customer
      : business.customers.find((item) => item.id === Number(value.customer_id));
  const customerAddresses = business.customer_addresses.filter(
    (address) => address.customer_id === Number(value.customer_id),
  );
  const billingAddress = customerAddresses.find(
    (address) => address.id === Number(value.billing_address_id),
  );
  const shippingAddress = customerAddresses.find(
    (address) => address.id === Number(value.shipping_address_id),
  );
  const displayBilling = issued ? customer : (billingAddress ?? customer);
  const issuedShipping = saved?.snapshot?.delivery_address ?? original?.snapshot?.delivery_address;
  const issuedShippingName = saved?.snapshot?.shipping_name ?? original?.snapshot?.shipping_name;
  const issuedShippingState =
    saved?.snapshot?.delivery_state_code ?? original?.snapshot?.delivery_state_code;
  const frozenShippingGstin = saved?.snapshot?.shipping_gstin ?? original?.snapshot?.shipping_gstin;
  const shippingState = shippingAddress?.state_code || value.delivery_state_code;
  const placeOfSupplySource =
    shippingState && value.place_of_supply === shippingState
      ? "From ship-to state"
      : !shippingState && displayBilling?.state_code === value.place_of_supply
        ? "From billing state"
        : "Chosen manually";
  const incompleteManualShipping = Boolean(
    value.delivery_address?.trim() && !value.delivery_state_code,
  );
  const totals = calculation?.totals;
  if (quotation && issued && saved) {
    return (
      <FinalizedQuotationDocument
        value={value}
        saved={saved}
        business={business}
        calculation={calculation}
        businessId={businessId}
      />
    );
  }
  function lineChange(index: number, field: keyof BusinessLine, next: string) {
    onChange({
      lines: value.lines.map((line, i) => (i === index ? { ...line, [field]: next } : line)),
    });
  }
  return (
    <article
      aria-label="Editable invoice"
      className="relative mx-auto flex min-h-[900px] w-full max-w-[1080px] flex-col border bg-background px-5 py-7 sm:px-10 sm:py-8"
    >
      <div>
        <div className="min-w-0 flex-1">
          <div className="mb-3 flex items-center gap-3">
            <h1 className="text-2xl font-semibold tracking-tight">
              {quotation ? "Quotation" : credit ? "Credit note" : "Tax invoice"}
            </h1>
          </div>
          <div className="grid grid-cols-[110px_minmax(0,1fr)] items-center gap-x-4 gap-y-1 text-sm sm:grid-cols-[120px_minmax(130px,1fr)_100px_minmax(130px,1fr)]">
            <span className="text-muted-foreground">
              {quotation ? "Quotation no." : credit ? "Credit note no." : "Invoice no."}
            </span>
            <span className="flex flex-wrap items-center gap-x-3 gap-y-1 py-1 font-medium">
              {saved?.number ||
                (quotation && nextQuotationNumber
                  ? nextQuotationNumber
                  : quotation
                    ? "Assigned on finalizing"
                    : "Assigned on issue")}
              {quotation && !issued && onChangeQuotationNumbering && (
                <Button
                  type="button"
                  variant="link"
                  size="sm"
                  className="h-auto p-0 font-normal"
                  disabled={disabled}
                  onClick={onChangeQuotationNumbering}
                >
                  Edit
                </Button>
              )}
            </span>
            {saved?.revised_from_id && (
              <>
                <span className="text-muted-foreground">Revised from</span>
                <Link
                  to="/business/$businessId/quotations/$invoiceId"
                  params={{ businessId, invoiceId: String(saved.revised_from_id) }}
                  className="py-1 underline underline-offset-4"
                >
                  {business.invoices.find((item) => item.id === saved.revised_from_id)?.number ??
                    "Earlier quotation"}
                </Link>
              </>
            )}
            {credit && (
              <>
                <span className="text-muted-foreground">Original invoice</span>
                <span className="py-1">
                  {original?.number || saved?.snapshot?.original_invoice_number || "—"}
                </span>
              </>
            )}
            <label htmlFor="invoice-date" className="text-muted-foreground">
              {quotation ? "Quotation date" : credit ? "Credit note date" : "Invoice date"}
            </label>
            <BusinessDateField
              id="invoice-date"
              label={quotation ? "Quotation date" : credit ? "Credit note date" : "Invoice date"}
              required
              disabled={disabled}
              value={value.invoice_date}
              onChange={(date) => onChange({ invoice_date: date })}
            />
            {!credit && !quotation && (
              <>
                <label htmlFor="invoice-due" className="text-muted-foreground">
                  Due date
                </label>
                <BusinessDateField
                  id="invoice-due"
                  label="Due date"
                  disabled={disabled}
                  min={value.invoice_date}
                  value={value.due_date || ""}
                  onChange={(date) => onChange({ due_date: date })}
                />
              </>
            )}
            {quotation && (
              <>
                <label htmlFor="quotation-valid-until" className="text-muted-foreground">
                  Valid until
                </label>
                <BusinessDateField
                  id="quotation-valid-until"
                  label="Valid until"
                  disabled={disabled}
                  min={value.invoice_date}
                  value={value.valid_until || ""}
                  onChange={(date) => onChange({ valid_until: date })}
                />
              </>
            )}
            {showReference && (
              <>
                <label htmlFor="invoice-reference" className="text-muted-foreground">
                  {quotation ? "Customer reference" : "Customer PO number"}
                </label>
                <InlineInput
                  id="invoice-reference"
                  aria-label={
                    quotation ? "Customer reference (optional)" : "Customer PO number (optional)"
                  }
                  disabled={disabled}
                  maxLength={100}
                  placeholder="Optional"
                  value={value.purchase_order_number || ""}
                  onChange={(e) => onChange({ purchase_order_number: e.target.value })}
                />
                {!quotation && (
                  <>
                    <label htmlFor="invoice-reference-date" className="text-muted-foreground">
                      PO date
                    </label>
                    <BusinessDateField
                      id="invoice-reference-date"
                      label="PO date"
                      disabled={disabled}
                      value={value.purchase_order_date || ""}
                      onChange={(date) => onChange({ purchase_order_date: date })}
                    />
                  </>
                )}
              </>
            )}
          </div>
          {!showReference && !issued && (
            <Button
              type="button"
              variant="ghost"
              size="sm"
              disabled={disabled}
              className="-ml-2 mt-1 text-muted-foreground"
              onClick={() => setShowReference(true)}
            >
              <Plus /> {quotation ? "Add customer reference" : "Add customer PO"}
            </Button>
          )}
        </div>
      </div>

      <div className="mt-5 flex flex-wrap items-baseline gap-x-2 gap-y-1 border-y py-3 text-sm">
        <span className="text-muted-foreground">From</span>
        <span className="font-medium">{supplier?.name}</span>
        {supplier?.gstin && <span className="text-muted-foreground">· GSTIN {supplier.gstin}</span>}
        {supplier?.address && (
          <span className="max-w-full truncate text-muted-foreground">· {supplier.address}</span>
        )}
        {!issued && (
          <Link
            to="/business/$businessId/settings/$section"
            params={{ businessId, section: "business" }}
            className="ml-auto underline underline-offset-4"
          >
            Edit business details
          </Link>
        )}
      </div>

      <section
        aria-label={issued ? "Issued party details" : "Invoice parties"}
        className="my-5 grid grid-cols-1 gap-6 text-sm sm:grid-cols-2 sm:gap-10"
      >
        <div className="space-y-2">
          <h2 className="text-muted-foreground">Bill to</h2>
          {issued || credit ? (
            <p className="font-medium">{customer?.name}</p>
          ) : (
            <CustomerPicker
              customers={business.customers}
              states={business.states}
              value={value.customer_id}
              onSelect={(selected) => {
                const addresses = business.customer_addresses.filter(
                  (address) => address.customer_id === selected.id,
                );
                const primaryBilling = addresses.find((address) => address.is_primary_billing);
                const primaryShipping = addresses.find((address) => address.is_primary_shipping);
                const billingId = primaryBilling?.id ?? null;
                onChange({
                  customer_id: selected.id,
                  billing_address_id: billingId,
                  shipping_address_id:
                    value.delivery_address || primaryShipping?.id === billingId
                      ? null
                      : (primaryShipping?.id ?? null),
                  delivery_address: "",
                  delivery_state_code: "",
                });
                onShippingInteraction(false);
                setShowDelivery(false);
              }}
              disabled={disabled}
            />
          )}
          {customer && (
            <>
              {!issued && !credit && (
                <CustomerAddressPicker
                  customerId={Number(value.customer_id)}
                  addresses={customerAddresses}
                  type="billing"
                  value={value.billing_address_id}
                  states={business.states}
                  disabled={disabled}
                  onSelect={(address) => {
                    const billingId = address?.id ?? null;
                    onChange({
                      billing_address_id: billingId,
                      ...(Number(value.shipping_address_id) === billingId
                        ? { shipping_address_id: null }
                        : {}),
                    });
                  }}
                />
              )}
              <p className="whitespace-pre-line text-muted-foreground">
                {displayBilling?.address || "Billing address not added"}
              </p>
              <p className="text-muted-foreground">
                {business.states.find((state) => state.code === displayBilling?.state_code)?.name ??
                  displayBilling?.state_code}{" "}
                {displayBilling?.state_code && `· ${displayBilling.state_code}`}
              </p>
              <p className="text-muted-foreground">
                {displayBilling?.gstin ? `GSTIN ${displayBilling.gstin}` : "Unregistered customer"}
              </p>
            </>
          )}
        </div>
        <div className="space-y-2">
          <h2 className="text-muted-foreground">Ship to (optional)</h2>
          {customer && !issued && !credit && (
            <div className="space-y-2">
              <CustomerAddressPicker
                customerId={Number(value.customer_id)}
                addresses={customerAddresses}
                type="shipping"
                value={value.shipping_address_id}
                states={business.states}
                disabled={disabled}
                onSelect={(address) => {
                  onShippingInteraction(true);
                  onChange({
                    shipping_address_id: address?.id ?? null,
                    delivery_address: address ? "" : value.delivery_address,
                    delivery_state_code: address ? "" : value.delivery_state_code,
                  });
                  setShowDelivery(!address);
                }}
              />
              {!shippingAddress && !showDelivery && !value.delivery_address && (
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  disabled={disabled}
                  className="-ml-2 w-fit text-muted-foreground"
                  onClick={() => {
                    onShippingInteraction(true);
                    onChange({
                      shipping_address_id: null,
                      delivery_address: "",
                      delivery_state_code: "",
                    });
                    setShowDelivery(true);
                  }}
                >
                  <Plus /> Add ship-to address
                </Button>
              )}
              {shippingAddress ? (
                <>
                  <p className="whitespace-pre-line text-muted-foreground">
                    {shippingAddress.address}
                  </p>
                  <p className="text-muted-foreground">
                    {business.states.find((state) => state.code === shippingAddress.state_code)
                      ?.name ?? shippingAddress.state_code}
                  </p>
                </>
              ) : showDelivery || value.delivery_address ? (
                <div className="space-y-2">
                  <label htmlFor="invoice-delivery" className="block text-xs text-muted-foreground">
                    Site / address
                  </label>
                  <InlineTextarea
                    id="invoice-delivery"
                    disabled={disabled}
                    maxLength={2000}
                    placeholder="Hospital, site, or one-off delivery address"
                    value={value.delivery_address || ""}
                    onChange={(e) => onChange({ delivery_address: e.target.value })}
                  />
                  <StateCombobox
                    id="invoice-delivery-state"
                    states={business.states}
                    value={value.delivery_state_code || ""}
                    onChange={(state) => onChange({ delivery_state_code: state })}
                    disabled={disabled}
                    label="Ship-to state"
                  />
                  {incompleteManualShipping && (
                    <p className="rounded-md border border-border bg-muted/30 p-2 text-xs text-muted-foreground">
                      This ship-to has no state. Add it before finalizing, or confirm that the state
                      is unavailable.
                    </p>
                  )}
                </div>
              ) : null}
            </div>
          )}
          {(issued || credit) &&
          (issuedShipping || issuedShippingName || issuedShippingState || frozenShippingGstin) ? (
            <div className="space-y-1 pt-2">
              {issuedShippingName && <p className="font-medium">{issuedShippingName}</p>}
              {issuedShipping && (
                <p className="whitespace-pre-line text-muted-foreground">{issuedShipping}</p>
              )}
              {issuedShippingState && (
                <p className="text-muted-foreground">
                  {business.states.find((state) => state.code === issuedShippingState)?.name ??
                    issuedShippingState}
                </p>
              )}
              {frozenShippingGstin && (
                <p className="text-muted-foreground">GSTIN {frozenShippingGstin}</p>
              )}
            </div>
          ) : null}
          {showDelivery && !customer && !issued && !credit ? (
            <div className="pt-3">
              <label
                htmlFor="invoice-delivery"
                className="mb-1 block text-sm text-muted-foreground"
              >
                Site / address
              </label>
              <InlineTextarea
                id="invoice-delivery"
                disabled={disabled}
                maxLength={2000}
                placeholder="Hospital, site, or one-off delivery address"
                value={value.delivery_address || ""}
                onChange={(e) => onChange({ delivery_address: e.target.value })}
              />
              <label
                htmlFor="invoice-delivery-state"
                className="mt-2 mb-1 block text-sm text-muted-foreground"
              >
                Ship-to state (optional)
              </label>
              <StateCombobox
                id="invoice-delivery-state"
                states={business.states}
                value={value.delivery_state_code || ""}
                onChange={(state) => onChange({ delivery_state_code: state })}
                disabled={disabled}
                label="Ship-to state"
              />
              {incompleteManualShipping && (
                <p className="mt-2 rounded-md border border-border bg-muted/30 p-2 text-xs text-muted-foreground">
                  This ship-to has no state. Add it before finalizing, or confirm that the state is
                  unavailable.
                </p>
              )}
            </div>
          ) : null}
        </div>
      </section>

      <div className="mb-5 grid gap-5 sm:grid-cols-[minmax(0,1fr)_280px]">
        {showSubject && (
          <div>
            <label htmlFor="invoice-subject" className="mb-1 block text-sm text-muted-foreground">
              Work / subject (optional)
            </label>
            <InlineInput
              id="invoice-subject"
              disabled={disabled}
              maxLength={200}
              placeholder="What is this quotation for?"
              value={value.subject || ""}
              onChange={(e) => onChange({ subject: e.target.value })}
            />
          </div>
        )}

        <div className="text-sm">
          <label htmlFor="invoice-pos" className="mb-1 block text-muted-foreground">
            Place of supply
          </label>
          <StateCombobox
            id="invoice-pos"
            states={business.states}
            disabled={disabled}
            value={value.place_of_supply}
            onChange={(state) => onChange({ place_of_supply: state })}
            label="Place of supply"
            inline
            required
          />
          <span className="mt-1 block text-xs text-muted-foreground">{placeOfSupplySource}</span>
        </div>
      </div>
      {customer &&
        (shippingAddress?.state_code || value.delivery_state_code) &&
        displayBilling?.state_code !==
          (shippingAddress?.state_code || value.delivery_state_code) && (
          <p className="mb-6 rounded-md border border-border bg-muted/30 p-3 text-sm">
            Bill to:{" "}
            {business.states.find((state) => state.code === displayBilling?.state_code)?.name ??
              displayBilling?.state_code}
            {" · "}Ship to:{" "}
            {business.states.find(
              (state) => state.code === (shippingAddress?.state_code || value.delivery_state_code),
            )?.name ??
              (shippingAddress?.state_code || value.delivery_state_code)}
            {" · "}Place of supply:{" "}
            {business.states.find((state) => state.code === value.place_of_supply)?.name ??
              "choose state"}
            {value.place_of_supply && (
              <>
                {" "}
                · {value.place_of_supply === supplier?.gstin?.slice(0, 2) ? "CGST + SGST" : "IGST"}
              </>
            )}
            <span className="mt-1 block text-muted-foreground">
              Billing and delivery states differ. Confirm the place of supply with your CA before
              finalizing.
            </span>
          </p>
        )}

      <section aria-label="Items" className="space-y-3">
        <div
          className={`hidden gap-2 border-b pb-3 text-xs text-muted-foreground lg:grid ${columns}`}
        >
          <span>Type</span>
          <span>Item / description</span>
          <span>HSN/SAC</span>
          <span className="text-right">Qty</span>
          <span>Unit</span>
          <span className="text-right">Rate (₹)</span>
          <span className="text-right">GST %</span>
          <span className="text-right">Amount</span>
          <span />
        </div>
        {value.lines.map((line, index) => (
          <div
            key={index}
            className={`group grid grid-cols-2 items-start gap-x-2 gap-y-2 border-b pb-3 text-sm ${columns}`}
          >
            <div className="col-span-2 min-w-0 lg:col-span-1">
              <label
                className="text-xs text-muted-foreground lg:sr-only"
                htmlFor={`line-${index}-kind`}
              >
                Type
              </label>
              {issued ? (
                <span className="flex min-h-8 items-center text-xs text-muted-foreground">
                  {line.kind === "goods" ? "Goods" : "Service"}
                </span>
              ) : (
                <InlineSelect
                  id={`line-${index}-kind`}
                  aria-label={`Item type ${index + 1}`}
                  disabled={disabled}
                  value={line.kind ?? "service"}
                  className="w-full text-xs"
                  onValueChange={(nextValue) =>
                    onChange({
                      lines: value.lines.map((entry, i) =>
                        i === index
                          ? { ...entry, kind: nextValue as "goods" | "service", sac: "", unit: "" }
                          : entry,
                      ),
                    })
                  }
                >
                  <SelectFieldOption value="service">Service</SelectFieldOption>
                  <SelectFieldOption value="goods">Goods</SelectFieldOption>
                </InlineSelect>
              )}
            </div>
            <div className="col-span-2 min-w-0 lg:col-span-1">
              <label
                className="text-xs text-muted-foreground lg:sr-only"
                htmlFor={`line-${index}-description`}
              >
                Description
              </label>
              <div className="relative min-w-0">
                <InlineTextarea
                  id={`line-${index}-description`}
                  required
                  disabled={disabled}
                  maxLength={1000}
                  placeholder="What are you selling?"
                  className={!issued ? "pr-9" : undefined}
                  value={line.description}
                  onChange={(e) => lineChange(index, "description", e.target.value)}
                />
                {!issued && (
                  <span className="absolute right-1 top-1">
                    <ServicePicker
                      index={index}
                      disabled={disabled}
                      services={business.services ?? []}
                      onSelect={(service) =>
                        onChange({
                          lines: value.lines.map((entry, i) =>
                            i === index
                              ? {
                                  ...entry,
                                  description: service.description,
                                  kind: service.kind,
                                  sac: service.sac,
                                  unit: service.unit,
                                  unit_price: service.unit_price,
                                  gst_rate: service.gst_rate,
                                }
                              : entry,
                          ),
                        })
                      }
                    />
                  </span>
                )}
              </div>
            </div>
            <div className="min-w-0">
              <label
                className="text-xs text-muted-foreground lg:sr-only"
                htmlFor={`line-${index}-sac`}
              >
                HSN/SAC
              </label>
              <InlineInput
                id={`line-${index}-sac`}
                required
                disabled={disabled}
                inputMode="numeric"
                pattern={line.kind === "goods" ? "(?!99)[0-9]{6}([0-9]{2})?" : "99[0-9]{4}"}
                maxLength={line.kind === "goods" ? 8 : 6}
                placeholder={line.kind === "goods" ? "6 or 8 digits" : "998313"}
                value={line.sac}
                onChange={(e) => lineChange(index, "sac", e.target.value)}
              />
            </div>
            <div className="min-w-0">
              <label
                className="text-xs text-muted-foreground lg:sr-only"
                htmlFor={`line-${index}-quantity`}
              >
                Quantity
              </label>
              <div className="flex min-w-0 items-center">
                <InlineInput
                  id={`line-${index}-quantity`}
                  required
                  disabled={disabled}
                  type="number"
                  min="0.0001"
                  step="0.0001"
                  value={line.quantity}
                  className="w-full tabular-nums text-right"
                  onChange={(e) => lineChange(index, "quantity", e.target.value)}
                />
              </div>
            </div>
            <div className="min-w-0">
              <label
                className="text-xs text-muted-foreground lg:sr-only"
                htmlFor={`line-${index}-unit`}
              >
                Unit
              </label>
              {(!issued || line.unit) &&
                (line.kind === "goods" ? (
                  <InlineSelect
                    id={`line-${index}-unit`}
                    required
                    disabled={disabled}
                    value={line.unit ?? ""}
                    className="w-full text-xs"
                    onValueChange={(nextValue) => lineChange(index, "unit", nextValue)}
                  >
                    <SelectFieldOption value="">Unit</SelectFieldOption>
                    {["NOS", "KGS", "LTR", "MTR", "BOX", "SET"].map((unit) => (
                      <SelectFieldOption key={unit} value={unit}>
                        {unit}
                      </SelectFieldOption>
                    ))}
                  </InlineSelect>
                ) : (
                  <InlineInput
                    id={`line-${index}-unit`}
                    disabled={disabled}
                    maxLength={30}
                    placeholder="unit"
                    value={line.unit ?? ""}
                    className="w-full text-xs text-muted-foreground"
                    onChange={(e) => lineChange(index, "unit", e.target.value)}
                  />
                ))}
            </div>
            <div className="min-w-0">
              <label
                className="text-xs text-muted-foreground lg:sr-only"
                htmlFor={`line-${index}-price`}
              >
                Rate (₹)
              </label>
              <InlineInput
                id={`line-${index}-price`}
                required
                disabled={disabled}
                type="number"
                min="0.01"
                step="0.01"
                placeholder="0.00"
                value={line.unit_price}
                className="tabular-nums sm:text-right"
                onChange={(e) => lineChange(index, "unit_price", e.target.value)}
              />
            </div>
            <div className="min-w-0">
              <label
                className="text-xs text-muted-foreground lg:sr-only"
                htmlFor={`line-${index}-gst`}
              >
                GST %
              </label>
              <Select
                items={rateItems}
                required
                disabled={disabled}
                value={
                  rates.includes(String(Number(line.gst_rate))) ? String(Number(line.gst_rate)) : ""
                }
                onValueChange={(rate) => lineChange(index, "gst_rate", rate ?? "")}
              >
                <SelectTrigger
                  id={`line-${index}-gst`}
                  aria-label={`GST % for item ${index + 1}`}
                  className="h-8 w-full min-w-0 rounded-sm border-border/70 bg-muted/30 px-2 shadow-none hover:border-ring/60 hover:bg-accent/50 focus-visible:bg-background focus-visible:ring-2 focus-visible:ring-ring/30 disabled:border-transparent disabled:bg-transparent disabled:opacity-100"
                >
                  <SelectValue className="justify-end text-right tabular-nums" />
                </SelectTrigger>
                <SelectContent align="end" alignItemWithTrigger={false}>
                  {rateItems.map((item) => (
                    <SelectItem key={item.value} value={item.value}>
                      {item.label}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
            <div className="flex min-h-8 items-center justify-between lg:justify-end">
              <span className="text-xs text-muted-foreground lg:hidden">Amount</span>
              <span className="whitespace-nowrap tabular-nums">
                {amount(calculation?.lines[index]?.taxable_paise)}
              </span>
            </div>
            <div className="flex justify-end">
              {!issued && (
                <Button
                  type="button"
                  variant="ghost"
                  size="icon-sm"
                  className="size-7"
                  disabled={disabled || value.lines.length === 1}
                  aria-label={`Remove item ${index + 1}`}
                  onClick={() => onChange({ lines: value.lines.filter((_, i) => i !== index) })}
                >
                  <Trash2 className="size-3.5" />
                </Button>
              )}
            </div>
          </div>
        ))}
        {!issued && (
          <Button
            variant="ghost"
            size="sm"
            type="button"
            disabled={disabled}
            className="-ml-2 text-muted-foreground"
            onClick={() =>
              onChange({
                lines: [
                  ...value.lines,
                  {
                    description: "",
                    kind: "service",
                    sac: "",
                    quantity: "1",
                    unit_price: "",
                    gst_rate: "18",
                  },
                ],
              })
            }
          >
            <Plus /> Add item
          </Button>
        )}
      </section>

      <div className="mb-12 mt-9 flex justify-end">
        <dl
          aria-label="Invoice totals"
          aria-busy={calculating}
          className="grid w-full max-w-[290px] grid-cols-2 gap-x-6 gap-y-3 text-sm"
        >
          <dt className="text-muted-foreground">Subtotal</dt>
          <dd className="text-right tabular-nums">{amount(totals?.taxable_paise)}</dd>
          {totals ? (
            (
              [
                ["CGST", totals.cgst_paise],
                ["SGST", totals.sgst_paise],
                ["IGST", totals.igst_paise],
              ] as const
            )
              .filter(([, value]) => value > 0)
              .map(([label, value]) => (
                <div key={label} className="contents">
                  <dt className="text-muted-foreground">{label}</dt>
                  <dd className="text-right tabular-nums">{amount(value)}</dd>
                </div>
              ))
          ) : (
            <>
              <dt className="text-muted-foreground">GST</dt>
              <dd className="text-right">—</dd>
            </>
          )}
          <dt className="border-t pt-3 font-semibold">Total</dt>
          <dd className="border-t pt-3 text-right font-semibold tabular-nums">
            {amount(totals?.total_paise)}
          </dd>
        </dl>
      </div>

      {calculation?.total_in_words && (
        <p className="mb-7 text-sm text-muted-foreground">{calculation.total_in_words}</p>
      )}
      <div className="mt-auto border-t pt-5">
        <label htmlFor="invoice-notes" className="mb-2 block text-sm text-muted-foreground">
          Notes (optional)
        </label>
        <InlineTextarea
          id="invoice-notes"
          disabled={disabled}
          maxLength={2000}
          placeholder="Payment terms or a note for your customer"
          value={value.notes || ""}
          onChange={(e) => onChange({ notes: e.target.value })}
        />
      </div>
    </article>
  );
}
