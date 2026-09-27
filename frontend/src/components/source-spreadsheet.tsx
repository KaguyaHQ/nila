import { useQuery } from "@tanstack/react-query";
import { FileSpreadsheet, Search } from "lucide-react";
import { type RefObject, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { RecordTableLink, RecordTableRow } from "@/components/record-table-row";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { SelectField, SelectFieldOption } from "@/components/ui/select-field";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { components } from "@/lib/generated/workspace";
import { ApiError } from "@/lib/sales-api";
import type { SalesInvoiceReviewData } from "@/lib/sales-review-api";

// These are source cells, not the corrected invoice's fields.
type SourceSheet = components["schemas"]["SalesSpreadsheetData"];
export type SpreadsheetPreferences = { allColumns: boolean };
type Props = {
  source: NonNullable<NonNullable<SalesInvoiceReviewData["source"]>["spreadsheet"]>;
  clientId: string;
  period: string;
  invoiceId: string;
  uploadRef: string;
  preferences: RefObject<SpreadsheetPreferences>;
  disabled: boolean;
};
const rowHeight = 40;
const visibleRowCount = 100;

export function SourceSpreadsheet(props: Props) {
  const first = props.source.selected[0];
  const [location, setLocation] = useState({ file: first?.file ?? "", sheet: first?.sheet ?? "" });
  const query = useQuery({
    queryKey: [
      "sales-spreadsheet",
      props.clientId,
      props.period,
      props.uploadRef,
      location.file,
      location.sheet,
    ],
    queryFn: async ({ signal }): Promise<SourceSheet> => {
      const params = new URLSearchParams(location);
      if (!location.file) params.delete("file");
      if (!location.sheet) params.delete("sheet");
      const response = await fetch(`${props.source.url}?${params}`, {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
        signal,
      });
      if (!response.ok) {
        const body = await response.json().catch(() => null);
        throw new ApiError(response.status, body?.error ?? "We couldn't load the spreadsheet.");
      }
      return response.json();
    },
    staleTime: 5 * 60 * 1000,
    retry: false,
  });
  if (!query.data)
    return (
      <section aria-label="Source spreadsheet" className="flex h-full flex-col gap-4 p-6">
        <p className="text-sm font-medium">{location.file || "Source spreadsheet"}</p>
        {query.isError ? (
          <>
            <p role="alert">{query.error.message}</p>
            <Button className="self-start" variant="outline" onClick={() => query.refetch()}>
              Try again
            </Button>
          </>
        ) : (
          <p role="status" className="text-sm text-muted-foreground">
            Loading spreadsheet…
          </p>
        )}
      </section>
    );
  return (
    <SheetView
      key={`${query.data.file}/${query.data.sheet}`}
      {...props}
      data={query.data}
      onLocation={setLocation}
    />
  );
}

function SheetView({
  data,
  onLocation,
  ...props
}: Props & { data: SourceSheet; onLocation: (value: { file: string; sheet: string }) => void }) {
  const [allColumns, setAllColumns] = useState(props.preferences.current.allColumns);
  const [search, setSearch] = useState("");
  const [message, setMessage] = useState("");
  const [scrollTop, setScrollTop] = useState(0);
  const [foundRow, setFoundRow] = useState<number | null>(null);
  const scroll = useRef<HTMLElement>(null);
  const selected = useMemo(
    () =>
      new Set(
        props.source.selected
          .filter((ref) => ref.file === data.file && ref.sheet === data.sheet)
          .flatMap((ref) => ref.rows),
      ),
    [props.source, data.file, data.sheet],
  );
  const headerNumbers = useMemo(() => new Set(data.header_rows), [data.header_rows]);
  const headers = useMemo(
    () => data.rows.filter((row) => headerNumbers.has(row.row)),
    [data.rows, headerNumbers],
  );
  const rows = useMemo(
    () => data.rows.filter((row) => !headerNumbers.has(row.row)),
    [data.rows, headerNumbers],
  );
  const columns =
    allColumns || !data.relevant_columns.length
      ? data.columns
      : data.columns.filter((col) => data.relevant_columns.includes(col));
  const start = Math.max(
    0,
    Math.min(rows.length - visibleRowCount, Math.floor(scrollTop / rowHeight) - 15),
  );
  const end = Math.min(rows.length, start + visibleRowCount);
  const firstSelected = rows.findIndex((row) => selected.has(row.row));
  const jump = useCallback((index: number) => {
    if (!scroll.current || index < 0) return;
    const top = Math.max(0, index * rowHeight - rowHeight * 2);
    scroll.current.scrollTop = top;
    setScrollTop(top);
  }, []);
  useEffect(() => {
    jump(firstSelected);
  }, [firstSelected, jump]);
  function find() {
    const text = search.trim().toLocaleLowerCase();
    if (!text) return;
    const matches = rows
      .map((row, index) => ({ row, index }))
      .filter(({ row }) =>
        Object.values(row.cells).some((value) => value.toLocaleLowerCase().includes(text)),
      );
    if (!matches.length) {
      setMessage("No matching cells in this sheet.");
      return;
    }
    const next =
      matches[(matches.findIndex((match) => match.row.row === foundRow) + 1) % matches.length];
    setFoundRow(next.row.row);
    jump(next.index);
    // Search covers original columns even when they were outside the initial excerpt.
    setAllColumns(true);
    props.preferences.current.allColumns = true;
    setMessage(
      `${matches.length} matching ${matches.length === 1 ? "row" : "rows"} · at row ${next.row.row}`,
    );
  }
  const rowClass =
    "h-10 max-w-80 overflow-hidden text-ellipsis border-r px-3 py-0 text-xs tabular-nums";
  return (
    <section
      aria-label="Source spreadsheet"
      className="flex h-full min-h-0 min-w-0 flex-col bg-background"
    >
      <div className="flex shrink-0 flex-wrap items-center justify-between gap-3 border-b p-3">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <FileSpreadsheet className="size-4 shrink-0 text-muted-foreground" />
            <span className="truncate text-sm font-medium" title={data.file}>
              {data.file}
            </span>
          </div>
          <a
            href={data.download_url}
            target="_blank"
            rel="noreferrer"
            className="text-xs text-muted-foreground underline"
          >
            Open original file<span className="sr-only"> (new tab)</span>
          </a>
        </div>
        <form
          className="flex flex-wrap items-center gap-2"
          onSubmit={(event) => {
            event.preventDefault();
            find();
          }}
        >
          <Input
            aria-label="Find in spreadsheet"
            placeholder="Find invoice or customer"
            className="h-8 w-48"
            value={search}
            onChange={(event) => {
              setSearch(event.target.value);
              setFoundRow(null);
            }}
          />
          <Button type="submit" variant="outline" size="sm">
            <Search /> Find next
          </Button>
          <Button
            type="button"
            variant="outline"
            size="sm"
            aria-pressed={allColumns}
            onClick={() => {
              setAllColumns(!allColumns);
              props.preferences.current.allColumns = !allColumns;
            }}
          >
            {allColumns ? "Relevant columns" : `All ${data.columns.length} columns`}
          </Button>
        </form>
      </div>
      <div className="flex shrink-0 flex-wrap items-center justify-between gap-2 border-b bg-muted/30 px-3 py-2 text-xs text-muted-foreground">
        <span>
          {rows.length.toLocaleString()} source rows · {columns.length} of {data.columns.length}{" "}
          columns
        </span>
        <Button
          size="xs"
          variant="ghost"
          disabled={firstSelected < 0}
          onClick={() => jump(firstSelected)}
        >
          Jump to invoice rows
        </Button>
      </div>
      <section
        ref={scroll}
        // biome-ignore lint/a11y/noNoninteractiveTabindex: Allow keyboard scrolling through source rows.
        tabIndex={0}
        aria-label="Scrollable source rows"
        onScroll={(event) => setScrollTop(event.currentTarget.scrollTop)}
        className="min-h-0 flex-1 overflow-auto overscroll-contain [&_[data-slot=table-container]]:overflow-visible"
      >
        <Table className="border-separate border-spacing-0 whitespace-nowrap text-xs">
          <TableHeader className="sticky top-0 z-20 bg-muted">
            <TableRow className="h-7 bg-muted/70">
              <TableHead className="sticky left-0 z-10 h-7 min-w-12 border-r bg-muted p-1 text-center text-xs text-muted-foreground">
                Row
              </TableHead>
              {columns.map((col) => (
                <TableHead
                  key={col}
                  className="h-7 border-r p-1 text-center text-xs text-muted-foreground"
                >
                  {col}
                </TableHead>
              ))}
            </TableRow>
            {headers.map((row) => (
              <TableRow key={row.row}>
                <TableHead className="sticky left-0 z-10 border-r bg-muted text-center text-xs text-muted-foreground">
                  {row.row}
                </TableHead>
                {columns.map((col) => (
                  <TableHead
                    key={col}
                    className="max-w-80 overflow-hidden border-r px-3 text-xs text-ellipsis"
                    title={row.cells[col]}
                  >
                    {row.cells[col] ?? ""}
                  </TableHead>
                ))}
              </TableRow>
            ))}
          </TableHeader>
          <TableBody>
            {start > 0 && (
              <TableRow aria-hidden="true">
                <TableCell
                  colSpan={columns.length + 1}
                  className="border-0 p-0"
                  style={{ height: start * rowHeight }}
                />
              </TableRow>
            )}
            {rows.slice(start, end).map((row) => {
              const isSelected = selected.has(row.row);
              const invoiceId = row.invoice_ids.length === 1 ? row.invoice_ids[0] : null;
              const linkColumn =
                data.invoice_column && columns.includes(data.invoice_column)
                  ? data.invoice_column
                  : (columns.find((col) => row.cells[col]) ?? columns[0]);
              return (
                <RecordTableRow
                  key={row.row}
                  data-source-row={row.row}
                  data-selected={isSelected}
                  aria-current={isSelected ? "true" : undefined}
                  className={
                    isSelected
                      ? "bg-accent hover:bg-accent"
                      : foundRow === row.row
                        ? "bg-muted/60"
                        : ""
                  }
                >
                  <TableCell
                    className={`sticky left-0 z-10 h-10 border-r px-3 py-0 text-center text-xs tabular-nums ${isSelected ? "border-l-2 border-l-primary bg-accent font-semibold" : "bg-background text-muted-foreground"}`}
                  >
                    {row.row}
                  </TableCell>
                  {columns.map((col) => (
                    <TableCell key={col} className={rowClass} title={row.cells[col]}>
                      {invoiceId && col === linkColumn && !props.disabled ? (
                        <RecordTableLink
                          to="/gst/$clientId/$period/sales/invoices/$invoiceId"
                          params={{ clientId: props.clientId, period: props.period, invoiceId }}
                          search={{}}
                          aria-label={`Open invoice from row ${row.row}`}
                          className="underline decoration-border underline-offset-4"
                        >
                          {row.cells[col]}
                        </RecordTableLink>
                      ) : (
                        (row.cells[col] ?? "")
                      )}
                    </TableCell>
                  ))}
                </RecordTableRow>
              );
            })}
            {end < rows.length && (
              <TableRow aria-hidden="true">
                <TableCell
                  colSpan={columns.length + 1}
                  className="border-0 p-0"
                  style={{ height: (rows.length - end) * rowHeight }}
                />
              </TableRow>
            )}
          </TableBody>
        </Table>
        {rows.length === 0 && (
          <p className="p-6 text-sm text-muted-foreground">No data rows in this sheet.</p>
        )}
      </section>
      <footer className="flex shrink-0 flex-wrap items-center justify-between gap-2 border-t bg-muted/30 p-2">
        <div className="flex min-w-0 items-center gap-2">
          {data.files.length > 1 && (
            <SelectField
              aria-label="Source file"
              value={data.file}
              className="max-w-52"
              onValueChange={(nextValue) => {
                const file = data.files.find((file) => file.name === nextValue);
                if (file) onLocation({ file: file.name, sheet: file.sheets[0] ?? "" });
              }}
            >
              {data.files.map((file) => (
                <SelectFieldOption key={file.name} value={file.name}>
                  {file.name}
                </SelectFieldOption>
              ))}
            </SelectField>
          )}
          <SelectField
            aria-label="Source sheet"
            value={data.sheet}
            className="max-w-44"
            onValueChange={(nextValue) => onLocation({ file: data.file, sheet: nextValue })}
          >
            {data.files
              .find((file) => file.name === data.file)
              ?.sheets.map((sheet) => (
                <SelectFieldOption key={sheet} value={sheet}>
                  {sheet}
                </SelectFieldOption>
              ))}
          </SelectField>
        </div>
        <span role="status" className="text-xs text-muted-foreground">
          {message || "Source cells · scroll to browse the whole sheet"}
        </span>
      </footer>
    </section>
  );
}
