import { Link } from "@tanstack/react-router";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { BusinessBootstrap, BusinessInvoice, InvoiceInput } from "@/lib/business-api";

type InvoiceCalculation =
  import("@/lib/generated/workspace").components["schemas"]["InvoiceCalculation"];

const amount = (value?: number) =>
  typeof value === "number"
    ? new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR" }).format(value / 100)
    : "—";

const monthNames = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec",
];
const displayDate = (value?: string | null) => {
  if (!value) return null;
  const [year, month, day] = value.split("-");
  return `${Number(day)} ${monthNames[Number(month) - 1]} ${year}`;
};

const cleanTotalInWords = (value?: string) => value?.replace(/ and zero paise only$/i, " only");

export function FinalizedQuotationDocument({
  value,
  saved,
  business,
  calculation,
  businessId,
}: {
  value: InvoiceInput;
  saved: BusinessInvoice;
  business: BusinessBootstrap;
  calculation: InvoiceCalculation | null;
  businessId: string;
}) {
  const supplier = saved.snapshot.supplier ?? {
    name: business.profile?.legal_name || business.business.name,
    address: business.profile?.address || business.business.address || "",
    gstin: business.business.gstin,
    state_code: business.profile?.state_code || "",
    phone: business.profile?.phone,
    email: business.profile?.email,
  };
  const savedCustomer = business.customers.find((customer) => customer.id === saved.customer_id);
  const billingAddress = business.customer_addresses.find(
    (address) => address.id === saved.billing_address_id,
  );
  const customer =
    saved.snapshot.customer ??
    (savedCustomer
      ? {
          name: savedCustomer.name,
          address: billingAddress?.address || savedCustomer.address,
          gstin: billingAddress?.gstin || savedCustomer.gstin,
          state_code: billingAddress?.state_code || savedCustomer.state_code,
        }
      : undefined);
  const shippingAddress = business.customer_addresses.find(
    (address) => address.id === saved.shipping_address_id,
  );
  const shipping =
    saved.snapshot.delivery_address || value.delivery_address || shippingAddress?.address;
  const shippingName = saved.snapshot.shipping_name || shippingAddress?.label;
  const shippingStateCode =
    saved.snapshot.delivery_state_code || value.delivery_state_code || shippingAddress?.state_code;
  const shippingGstin = saved.snapshot.shipping_gstin || shippingAddress?.gstin;
  const stateName = (code?: string | null) =>
    business.states.find((state) => state.code === code)?.name ?? code;
  const totals = calculation?.totals;
  const totalInWords = cleanTotalInWords(calculation?.total_in_words);

  return (
    <article
      aria-label="Finalized quotation"
      className="relative mx-auto flex min-h-[760px] w-full max-w-[960px] flex-col border bg-background px-5 py-7 sm:px-10 sm:py-9"
    >
      <header className="flex items-start justify-between gap-8">
        <div>
          <p className="text-sm font-medium text-muted-foreground">Quotation</p>
          <h1 className="mt-1 text-2xl font-semibold tracking-tight">{saved.number}</h1>
        </div>
        <dl className="grid grid-cols-[auto_auto] gap-x-5 gap-y-2 text-sm">
          <dt className="text-muted-foreground">Quotation date</dt>
          <dd className="text-right font-medium">
            <time dateTime={value.invoice_date}>{displayDate(value.invoice_date)}</time>
          </dd>
          {value.valid_until && (
            <>
              <dt className="text-muted-foreground">Valid until</dt>
              <dd className="text-right font-medium">
                <time dateTime={value.valid_until}>{displayDate(value.valid_until)}</time>
              </dd>
            </>
          )}
          {value.purchase_order_number && (
            <>
              <dt className="text-muted-foreground">Customer reference</dt>
              <dd className="text-right font-medium">{value.purchase_order_number}</dd>
            </>
          )}
          {saved.revised_from_id && (
            <>
              <dt className="text-muted-foreground">Revised from</dt>
              <dd className="text-right font-medium">
                <Link
                  to="/business/$businessId/quotations/$invoiceId"
                  params={{ businessId, invoiceId: String(saved.revised_from_id) }}
                  className="underline underline-offset-4"
                >
                  {business.invoices.find((item) => item.id === saved.revised_from_id)?.number ??
                    "Earlier quotation"}
                </Link>
              </dd>
            </>
          )}
        </dl>
      </header>

      <section
        aria-label="Quotation parties"
        className="mt-10 grid grid-cols-1 gap-8 border-t pt-7 text-sm sm:grid-cols-2 sm:gap-14"
      >
        <div className="space-y-2">
          <h2 className="text-muted-foreground">From</h2>
          <p className="font-medium">{supplier.name}</p>
          <p className="whitespace-pre-line text-muted-foreground">{supplier.address}</p>
          {supplier.gstin && <p className="text-muted-foreground">GSTIN {supplier.gstin}</p>}
          {supplier.phone && <p className="text-muted-foreground">{supplier.phone}</p>}
          {supplier.email && <p className="text-muted-foreground">{supplier.email}</p>}
        </div>
        <div className="space-y-2">
          <h2 className="text-muted-foreground">Bill to</h2>
          <p className="font-medium">{customer?.name}</p>
          <p className="whitespace-pre-line text-muted-foreground">{customer?.address}</p>
          {customer?.state_code && (
            <p className="text-muted-foreground">
              {stateName(customer.state_code)} · {customer.state_code}
            </p>
          )}
          <p className="text-muted-foreground">
            {customer?.gstin ? `GSTIN ${customer.gstin}` : "Unregistered customer"}
          </p>
          {shipping && (
            <div className="space-y-1 pt-3">
              <h3 className="text-muted-foreground">
                Ship to{shippingName ? ` · ${shippingName}` : ""}
              </h3>
              <p className="whitespace-pre-line text-muted-foreground">{shipping}</p>
              {shippingStateCode && (
                <p className="text-muted-foreground">{stateName(shippingStateCode)}</p>
              )}
              {shippingGstin && <p className="text-muted-foreground">GSTIN {shippingGstin}</p>}
            </div>
          )}
        </div>
      </section>

      {(value.subject || value.place_of_supply) && (
        <section className="mt-8 grid gap-5 border-t pt-6 text-sm sm:grid-cols-2">
          {value.subject && (
            <div>
              <h2 className="text-muted-foreground">Work / subject</h2>
              <p className="mt-1 font-medium">{value.subject}</p>
            </div>
          )}
          {value.place_of_supply && (
            <div>
              <h2 className="text-muted-foreground">Place of supply</h2>
              <p className="mt-1 font-medium">
                {stateName(value.place_of_supply)} · {value.place_of_supply}
              </p>
            </div>
          )}
        </section>
      )}

      <section aria-label="Items" className="mt-8">
        <Table className="table-fixed">
          <TableHeader>
            <TableRow className="hover:bg-transparent">
              <TableHead className="w-[38%] pl-0">Description</TableHead>
              <TableHead className="w-[14%]">HSN/SAC</TableHead>
              <TableHead className="w-[14%]">Qty / unit</TableHead>
              <TableHead className="w-[12%] text-right">Rate</TableHead>
              <TableHead className="w-[8%] text-right">GST</TableHead>
              <TableHead className="w-[14%] pr-0 text-right">Amount</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {value.lines.map((line, index) => (
              <TableRow key={`${line.description}-${index}`} className="hover:bg-transparent">
                <TableCell className="whitespace-normal pl-0 font-medium">
                  {line.description}
                </TableCell>
                <TableCell className="tabular-nums">{line.sac}</TableCell>
                <TableCell>
                  <span className="tabular-nums">{line.quantity}</span>
                  {line.unit ? ` ${line.unit}` : ""}
                </TableCell>
                <TableCell className="text-right tabular-nums">
                  {amount(Number(line.unit_price) * 100)}
                </TableCell>
                <TableCell className="text-right tabular-nums">{line.gst_rate}%</TableCell>
                <TableCell className="pr-0 text-right font-medium tabular-nums">
                  {amount(
                    calculation?.lines[index]?.taxable_paise ??
                      Math.round(Number(line.quantity) * Number(line.unit_price) * 100),
                  )}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </section>

      <div className="mt-8 flex justify-end">
        <dl
          aria-label="Quotation totals"
          className="grid w-full max-w-[300px] grid-cols-2 gap-x-8 gap-y-3 text-sm"
        >
          <dt className="text-muted-foreground">Subtotal</dt>
          <dd className="text-right tabular-nums">{amount(totals?.taxable_paise)}</dd>
          {totals &&
            (
              [
                ["CGST", totals.cgst_paise],
                ["SGST", totals.sgst_paise],
                ["IGST", totals.igst_paise],
              ] as const
            )
              .filter(([, tax]) => tax > 0)
              .map(([label, tax]) => (
                <div key={label} className="contents">
                  <dt className="text-muted-foreground">{label}</dt>
                  <dd className="text-right tabular-nums">{amount(tax)}</dd>
                </div>
              ))}
          <dt className="border-t pt-3 font-semibold">Total</dt>
          <dd className="border-t pt-3 text-right font-semibold tabular-nums">
            {amount(totals?.total_paise)}
          </dd>
        </dl>
      </div>

      {totalInWords && <p className="mt-8 text-sm text-muted-foreground">{totalInWords}</p>}
      {value.notes && (
        <section className="mt-auto border-t pt-6 text-sm">
          <h2 className="text-muted-foreground">Notes</h2>
          <p className="mt-2 whitespace-pre-line">{value.notes}</p>
        </section>
      )}
    </article>
  );
}
