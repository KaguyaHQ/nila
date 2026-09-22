import { useRef, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { ArrowLeft, ChevronRight, Plus, Search, X } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import {
  Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle,
} from '@/components/ui/dialog'
import {
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/components/ui/table'
import { invoices, money, monthLabel, type SalesInvoice } from '@/data/sales'

const filters = [
  { value: 'all', label: 'All invoices' },
  { value: 'needs_review', label: 'Needs review' },
  { value: 'ready', label: 'Ready' },
] as const

function invoiceDate(value: string) {
  return new Intl.DateTimeFormat('en-IN', {
    day: '2-digit', month: 'short', year: 'numeric', timeZone: 'UTC',
  }).format(new Date(`${value}T00:00:00Z`))
}

function InvoiceStatus({ status }: { status: SalesInvoice['status'] }) {
  return (
    <Badge variant="secondary" className={status === 'needs_review'
      ? 'whitespace-nowrap bg-amber-50 font-normal text-amber-800'
      : 'whitespace-nowrap bg-emerald-50 font-normal text-emerald-800'}>
      {status === 'needs_review' ? 'Needs review' : 'Ready'}
    </Badge>
  )
}

export default function SalesRegister() {
  const [params, setParams] = useSearchParams()
  const [selected, setSelected] = useState<SalesInvoice | null>(null)
  const dialogOpener = useRef<HTMLButtonElement | null>(null)
  const query = params.get('q') ?? ''
  const requestedFilter = params.get('filter')
  const filter = requestedFilter === 'needs_review' || requestedFilter === 'ready'
    ? requestedFilter : 'all'
  const needle = query.trim().toLocaleLowerCase()
  const visible = invoices.filter(invoice =>
    (filter === 'all' || invoice.status === filter) &&
    `${invoice.number} ${invoice.customer} ${invoice.gstin}`.toLocaleLowerCase().includes(needle),
  )
  const totals = visible.reduce((sum, invoice) => ({
    taxable: sum.taxable + invoice.taxablePaise,
    tax: sum.tax + invoice.taxPaise,
  }), { taxable: 0, tax: 0 })

  function openInvoice(invoice: SalesInvoice, opener: HTMLButtonElement) {
    dialogOpener.current = opener
    setSelected(invoice)
  }

  function changeQuery(value: string) {
    const next = new URLSearchParams(params)
    if (value) next.set('q', value)
    else next.delete('q')
    setParams(next, { replace: true })
  }

  function changeFilter(value: string) {
    const next = new URLSearchParams(params)
    if (value === 'all') next.delete('filter')
    else next.set('filter', value)
    setParams(next)
  }

  function resetFilters() {
    const next = new URLSearchParams(params)
    next.delete('q')
    next.delete('filter')
    setParams(next)
  }

  return <>
    <Link to="/sales" className="mb-5 inline-flex items-center gap-2 rounded-sm text-sm text-muted-foreground hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
      <ArrowLeft className="size-4" aria-hidden="true" /> Sales summary
    </Link>
    <div className="mb-7 flex flex-wrap items-center justify-between gap-4">
      <div>
        <h1 className="text-3xl font-semibold tracking-tight">Sales register</h1>
        <p className="mt-2 text-sm text-muted-foreground">{monthLabel} · {invoices.length} sample invoices</p>
      </div>
      <Button  nativeButton={false} role="link" render={<Link to="/sales/upload" />}> <Plus aria-hidden="true" /> Add invoices</Button>
    </div>

    <section aria-label="Sales invoices" className="overflow-hidden rounded-xl border bg-card">
      <div className="flex flex-wrap items-center justify-between gap-4 border-b p-4">
        <div role="group" aria-label="Filter invoices by status" className="flex flex-wrap items-center gap-1">
          {filters.map(item => <Button
            key={item.value}
            variant={filter === item.value ? 'secondary' : 'ghost'}
            size="sm"
            aria-pressed={filter === item.value}
            onClick={() => changeFilter(item.value)}
          >
            {item.label}
            <span className="ml-1 text-muted-foreground tabular-nums">
              {item.value === 'all' ? invoices.length : invoices.filter(invoice => invoice.status === item.value).length}
            </span>
          </Button>)}
        </div>
        <div className="relative w-full sm:w-72">
          <Search aria-hidden="true" className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground" />
          <Input id="sales-register-search" aria-label="Search customer, invoice or GSTIN" placeholder="Search customer, invoice or GSTIN" value={query} onChange={event => changeQuery(event.target.value)} className="pr-9 pl-9" />
          {query && <Button variant="ghost" size="icon" className="absolute top-1/2 right-1 size-7 -translate-y-1/2" aria-label="Clear search" onClick={() => changeQuery('')}><X className="size-3.5" /></Button>}
        </div>
      </div>

      <Table>
        <TableHeader>
          <TableRow className="bg-muted/40 hover:bg-muted/40">
            <TableHead className="pl-5">Invoice</TableHead>
            <TableHead>Date</TableHead>
            <TableHead>Customer</TableHead>
            <TableHead className="text-right">Taxable value</TableHead>
            <TableHead className="text-right">GST</TableHead>
            <TableHead className="pl-5">Status</TableHead>
            <TableHead className="w-12"><span className="sr-only">Details</span></TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {visible.map(invoice => <TableRow key={invoice.id}>
            <TableCell className="py-4 pl-5">
              <button className="rounded-sm font-medium whitespace-nowrap underline-offset-4 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring" onClick={event => openInvoice(invoice, event.currentTarget)} aria-label={`View sample invoice ${invoice.number}`}>{invoice.number}</button>
            </TableCell>
            <TableCell className="whitespace-nowrap text-muted-foreground">{invoiceDate(invoice.date)}</TableCell>
            <TableCell>
              <p className="font-medium">{invoice.customer}</p>
              <p className="mt-0.5 text-xs text-muted-foreground">{invoice.gstin || 'Unregistered customer'}</p>
            </TableCell>
            <TableCell className="text-right whitespace-nowrap tabular-nums">{money(invoice.taxablePaise)}</TableCell>
            <TableCell className="text-right whitespace-nowrap tabular-nums">{money(invoice.taxPaise)}</TableCell>
            <TableCell className="pl-5"><InvoiceStatus status={invoice.status} /></TableCell>
            <TableCell className="pr-4"><Button variant="ghost" size="icon" className="size-8" onClick={event => openInvoice(invoice, event.currentTarget)} aria-label={`Open details for ${invoice.number}`}><ChevronRight className="size-4 text-muted-foreground" /></Button></TableCell>
          </TableRow>)}
          {visible.length === 0 && <TableRow className="hover:bg-transparent"><TableCell colSpan={7} className="py-14 text-center">
            <p className="font-medium">No invoices match</p>
            <p className="mt-1 text-sm text-muted-foreground">Try another search or clear the filters.</p>
            <Button className="mt-4" variant="outline" size="sm" onClick={resetFilters}>Clear filters</Button>
          </TableCell></TableRow>}
        </TableBody>
      </Table>
      <div className="flex flex-wrap items-center justify-between gap-3 border-t bg-muted/20 px-5 py-3 text-sm">
        <p className="text-muted-foreground" role="status">Showing {visible.length} of {invoices.length} invoices</p>
        {visible.length > 0 && <p className="flex flex-wrap gap-x-6 gap-y-1 tabular-nums"><span><span className="mr-2 text-muted-foreground">Taxable</span>{money(totals.taxable)}</span><span><span className="mr-2 text-muted-foreground">GST</span>{money(totals.tax)}</span></p>}
      </div>
    </section>
    <p className="mt-4 text-xs text-muted-foreground">Sample data only. Invoice details show a preview; no client records are changed.</p>

    <Dialog open={selected !== null} onOpenChange={open => { if (!open) setSelected(null) }}>
      <DialogContent finalFocus={dialogOpener}>
        <DialogHeader>
          <DialogTitle>Invoice {selected?.number}</DialogTitle>
          <DialogDescription>Sample invoice details · {monthLabel}</DialogDescription>
        </DialogHeader>
        {selected && <>
          <div className="flex items-start justify-between gap-4 border-b pb-4">
            <div><p className="font-medium">{selected.customer}</p><p className="mt-1 text-sm text-muted-foreground">{selected.gstin || 'Unregistered customer'}</p></div>
            <InvoiceStatus status={selected.status} />
          </div>
          <dl className="space-y-3 text-sm">
            {[
              ['Invoice date', invoiceDate(selected.date)],
              ['Taxable value', money(selected.taxablePaise)],
              ['GST', money(selected.taxPaise)],
              ['Invoice total', money(selected.totalPaise)],
            ].map(([label, value]) => <div key={label} className="flex justify-between gap-4"><dt className="text-muted-foreground">{label}</dt><dd className="text-right font-medium tabular-nums">{value}</dd></div>)}
          </dl>
          {selected.issue && <p className="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-900">{selected.issue}</p>}
          <p className="text-sm leading-6 text-muted-foreground">Document review and corrections are not connected in this preview.</p>
        </>}
        <div className="flex justify-end"><Button variant="outline" onClick={() => setSelected(null)}>Close</Button></div>
      </DialogContent>
    </Dialog>
  </>
}
