import { useState } from "react";
import { Link, useParams } from "react-router-dom";
import { ArrowLeft, ArrowUpRight, ChevronRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { SalesExports } from "@/components/sales-exports";
import type { SalesSectionDetail, SalesSectionRow } from "@/lib/sales-api";
import { basePath, useSales } from "./live-sales";

type SectionGroup = SalesSectionDetail["groups"][number];

function hasSources(rows: SalesSectionRow[]): boolean {
  return rows.some(row => row.invoice_path || hasSources(row.children ?? []));
}

function SectionRow({ row, columns, showSources, depth = 0 }: { row: SalesSectionRow; columns: SectionGroup["columns"]; showSources: boolean; depth?: number }) {
  const [expanded, setExpanded] = useState(false);
  const children = row.children ?? [];
  const title = row.cells[columns[0]?.key] || row.id;
  return <>
    <TableRow className={depth ? "bg-muted/20" : undefined}>
      {columns.map((column, index) => <TableCell key={column.key} className={`${index === 0 ? depth ? "pl-10" : "pl-4" : ""} ${column.align === "right" ? "text-right whitespace-nowrap tabular-nums" : "max-w-sm whitespace-normal"} py-3`}>
        {index === 0 && children.length > 0 ? <div className="flex items-center gap-2"><Button variant="ghost" size="icon-xs" aria-expanded={expanded} aria-label={`${expanded ? "Hide" : "Show"} contributing invoices for ${title}`} onClick={() => setExpanded(value => !value)}><ChevronRight className={expanded ? "rotate-90" : ""} /></Button><span>{row.cells[column.key] ?? "—"}</span></div> : row.cells[column.key] ?? "—"}
      </TableCell>)}
      {showSources && <TableCell className="pr-4 text-right">{row.invoice_path && <Link to={row.invoice_path} className="inline-flex items-center gap-1 whitespace-nowrap text-sm underline-offset-4 hover:underline" aria-label={`Review source invoice ${title}`}>Review <ArrowUpRight className="size-3.5" /></Link>}</TableCell>}
    </TableRow>
    {expanded && children.map(child => <SectionRow key={child.id} row={child} columns={columns} showSources={showSources} depth={depth + 1} />)}
  </>;
}

function SectionTable({ group }: { group: SectionGroup }) {
  if (group.rows.length === 0) return <p className="text-sm text-muted-foreground">{group.label ? `${group.label}: no entries.` : "No entries in this section."}</p>;
  const showSources = hasSources(group.rows);
  return <section className="min-w-0 space-y-3" aria-label={group.label ?? "Section entries"}>
    {group.label && <h2 className="text-sm font-semibold">{group.label}</h2>}
    <div className="overflow-hidden rounded-xl border bg-card"><Table><TableHeader><TableRow className="bg-muted/30">{group.columns.map((column, index) => <TableHead key={column.key} className={`${index === 0 ? "pl-4" : ""} ${column.align === "right" ? "text-right" : ""}`}>{column.label}</TableHead>)}{showSources && <TableHead className="w-20 pr-4 text-right">Source</TableHead>}</TableRow></TableHeader><TableBody>
      {group.rows.map(row => <SectionRow key={row.id} row={row} columns={group.columns} showSources={showSources} />)}
    </TableBody></Table></div>
  </section>;
}

export default function SalesSection() {
  const data = useSales();
  const { section = "" } = useParams();
  const detail = data.details && Object.hasOwn(data.details, section) ? data.details[section] : undefined;
  const base = basePath(data);
  if (!detail) return <div className="space-y-4"><h1 className="text-2xl font-semibold">Section unavailable</h1><p className="text-sm text-muted-foreground">This section is not available for the selected month.</p><Button variant="outline" nativeButton={false} role="link" render={<Link to={base} />}><ArrowLeft /> Back to sales summary</Button></div>;
  return <>
    <Link to={base} className="mb-5 inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"><ArrowLeft className="size-4" /> Sales summary</Link>
    <div className="mb-7 space-y-2"><p className="text-sm text-muted-foreground">{data.client.name} · {data.month_label}</p><h1 className="text-2xl font-semibold tracking-tight">{detail.title}</h1>{detail.description && <p className="text-sm leading-6 text-muted-foreground">{detail.description}</p>}</div>
    <div className="grid items-start gap-7 xl:grid-cols-[minmax(0,1fr)_240px]">
      <div className="min-w-0 space-y-6">
        {section === "documents" && <Link to={`${base}/checks`} className="inline-flex text-sm font-medium underline underline-offset-4">Review month checks and recorded decisions</Link>}
        {detail.note && <p className="rounded-lg border bg-muted/30 px-4 py-3 text-sm leading-6 text-muted-foreground">{detail.note}</p>}
        {detail.groups.map(group => <SectionTable key={`${section}-${group.id}`} group={group} />)}
        {detail.groups.length === 0 && <p className="rounded-xl border bg-card px-5 py-12 text-center text-sm text-muted-foreground">No entries in this section.</p>}
      </div>
      {data.exports && <aside className="xl:border-l xl:pl-6"><SalesExports data={data} /></aside>}
    </div>
  </>;
}
