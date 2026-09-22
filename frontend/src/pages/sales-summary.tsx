import { Link } from "react-router-dom";
import { ArrowRight, ArrowUpRight, ChevronDown, ChevronLeft, ChevronRight, FileJson, FileSpreadsheet, Plus, Upload } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Card } from "@/components/ui/card";
import { Table, TableHeader, TableHead, TableBody, TableRow, TableCell } from "@/components/ui/table";
import { invoices, monthLabel, money, totals } from "@/data/sales";

const sections = [
  { label: "B2B — sales to registered persons", count: `${invoices.length} invoices`, amount: money(totals.taxablePaise), to: "/sales/register" },
  ...["B2CL — inter-state consumers", "Exports", "SEZ supplies", "B2C (others)", "Exempt / non-taxable supplies", "Credit notes / debit notes", "Advances received / adjusted", "Supplies through e-commerce operator"].map(label => ({ label, count: "—", amount: "—", to: null })),
  { label: "HSN-wise summary of outward supplies", count: "7 HSN/SAC", amount: money(totals.taxablePaise), to: null },
  { label: "Documents issued", count: `${invoices.length} documents`, amount: "—", to: null },
];

export default function SalesSummary() {
  return <>
    <div className="mb-8 flex flex-wrap items-center justify-between gap-4">
      <div><p className="mb-2 text-sm text-muted-foreground">Sales & GSTR-1</p><div className="flex items-center gap-4"><h1 className="text-3xl font-semibold tracking-tight">{monthLabel}</h1><Button disabled variant="ghost" size="icon-xs" aria-label="Choose month" title="Only June 2026 is available in this preview"><ChevronDown /></Button><div className="flex gap-1"><Button disabled variant="ghost" size="icon-sm" aria-label="Previous month" title="Only June 2026 is available in this preview"><ChevronLeft /></Button><Button disabled variant="ghost" size="icon-sm" aria-label="Next month" title="Only June 2026 is available in this preview"><ChevronRight /></Button></div></div></div>
      <p className="text-xs text-muted-foreground">GSTR-1 due <span className="ml-1 font-medium text-foreground">11 Jul 2026</span></p>
    </div>
    <Card className="gap-0 overflow-hidden py-0 shadow-none">
      <div className="flex flex-wrap items-center justify-between gap-4 px-6 pt-5"><div><h2 className="text-sm font-semibold">Sales invoices</h2><p className="mt-1 text-sm text-muted-foreground">Review the GST working before exporting.</p></div><div className="flex flex-wrap items-center gap-2"><Button variant="outline"  nativeButton={false} role="link" render={<Link to="/sales/upload" />}> <Plus /> Add invoices</Button><Button  nativeButton={false} role="link" render={<Link to="/sales/register?filter=needs_review" />}> Review invoices <ArrowRight /></Button></div></div>
      <div className="grid gap-5 px-6 py-6 sm:grid-cols-[.75fr_1fr_1fr]">
        {[["Invoices in working", String(invoices.length)], ["Taxable value", money(totals.taxablePaise)], ["Output tax", money(totals.taxPaise)]].map(([label, value], i) => <div key={label} className={i ? "sm:border-l sm:pl-6" : ""}><p className="text-xs text-muted-foreground">{label}</p><p className="mt-1.5 text-2xl font-semibold tracking-tight tabular-nums">{value}</p></div>)}
      </div>
      <div className="flex flex-wrap items-center justify-between gap-2 border-t bg-neutral-50/40 px-4 py-2"><Button variant="ghost" size="sm"  nativeButton={false} role="link" render={<Link to="/sales/register" />}> View sales register <ArrowUpRight className="text-muted-foreground" /></Button><Button variant="ghost" size="sm" className="text-muted-foreground"  nativeButton={false} role="link" render={<Link to="/sales/uploads" />}> <Upload /> Uploads <span className="mx-1 text-neutral-300">·</span> 1 batch · 1 file</Button></div>
    </Card>
    <div className="mt-8 grid items-start gap-7 xl:grid-cols-[minmax(0,1fr)_220px]">
      <section aria-labelledby="sales-summary" className="min-w-0">
        <h2 id="sales-summary" className="mb-3 text-sm font-semibold">GSTR-1 summary</h2>
        <div className="overflow-hidden rounded-xl border bg-white"><Table><TableHeader><TableRow className="bg-neutral-50/70 hover:bg-neutral-50/70"><TableHead className="pl-4">Section</TableHead><TableHead className="text-right">Entries</TableHead><TableHead className="text-right">Taxable value</TableHead><TableHead className="pl-5">Status</TableHead><TableHead className="w-8"><span className="sr-only">Open</span></TableHead></TableRow></TableHeader><TableBody>
          {sections.map(({ label, count, amount, to }) => <TableRow key={label} className={to ? "" : "hover:bg-transparent"}>
            <TableCell className="py-3 pl-4">{to ? <Link to={to} className="text-sm font-medium underline-offset-4 hover:underline">{label}</Link> : <span className={count === "—" ? "text-sm text-neutral-600" : "text-sm font-medium"}>{label}</span>}</TableCell>
            <TableCell className="text-right whitespace-nowrap tabular-nums">{count}</TableCell><TableCell className="text-right whitespace-nowrap tabular-nums">{amount}</TableCell><TableCell className="pl-5 whitespace-nowrap">{count !== "—" ? <Badge variant="secondary" className="bg-amber-50 font-normal text-amber-800">Draft</Badge> : <span className="text-xs text-muted-foreground">No entries</span>}</TableCell><TableCell>{to && <Button variant="ghost" size="icon-xs"  nativeButton={false} role="link" render={<Link to={to} aria-label={`Open ${label}`} />}> <ChevronRight className="text-muted-foreground" /></Button>}</TableCell>
          </TableRow>)}
        </TableBody></Table></div>
      </section>
      <aside aria-labelledby="sales-exports" className="xl:border-l xl:pl-6"><h2 id="sales-exports" className="mb-4 text-sm font-semibold">Exports</h2><p id="export-reason" className="mb-4 text-sm leading-6 text-muted-foreground">Exports are not connected in this UI preview.</p><div className="divide-y">{[{ Icon: FileSpreadsheet, label: "GST sales working", format: "XLSX" }, { Icon: FileSpreadsheet, label: "Winman GSTR-1", format: "XLSM" }, { Icon: FileJson, label: "GSTR-1", format: "JSON" }].map(({ Icon, label, format }) => <div key={label} className="py-3 first:pt-0"><button disabled aria-describedby="export-reason" className="flex w-full cursor-not-allowed items-start gap-3 text-left"><Icon className="mt-0.5 size-4 shrink-0 text-muted-foreground" /><span><span className="block text-sm text-muted-foreground">{label}</span><span className="mt-1 block text-xs text-muted-foreground">{format}</span></span></button></div>)}</div></aside>
    </div>
  </>;
}
