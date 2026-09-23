import { useMemo } from "react";
import {
  createColumnHelper,
  createSortedRowModel,
  rowSortingFeature,
  sortFn_basic,
  sortFn_text,
  tableFeatures,
  useTable,
} from "@tanstack/react-table";
import { ArrowDown, ArrowUp, ArrowUpDown } from "lucide-react";
import { Link } from "react-router-dom";
import { Button } from "@/components/ui/button";
import {
  Table,
  TableHeader,
  TableHead,
  TableBody,
  TableRow,
  TableCell,
} from "@/components/ui/table";
import { Tooltip, TooltipTrigger, TooltipContent } from "@/components/ui/tooltip";
import type { PurchasesWorkspace } from "@/lib/purchases-api";

type Entry = PurchasesWorkspace["rows"][number];
const features = tableFeatures({
  rowSortingFeature,
  sortedRowModel: createSortedRowModel(),
  sortFns: { basic: sortFn_basic, text: sortFn_text },
});
const helper = createColumnHelper<typeof features, Entry>();
const makeColumns = (comparisonAvailable: boolean) =>
  helper.columns([
    helper.accessor("number", {
      header: "Invoice",
      enableSorting: false,
      cell: ({ row }) => <span className="font-medium">{row.original.number}</span>,
    }),
    helper.accessor((row) => row.date ?? undefined, {
      id: "date",
      header: "Date",
      sortFn: "basic",
      sortDescFirst: true,
      sortUndefined: "last",
      cell: ({ row }) => row.original.date ?? "—",
    }),
    helper.accessor("vendor", {
      header: "Vendor",
      sortFn: "text",
      sortDescFirst: false,
      cell: ({ row }) => (
        <div>
          <div>{row.original.vendor}</div>
          <div className="text-xs text-muted-foreground">
            {row.original.gstin ?? "GSTIN not provided"}
          </div>
        </div>
      ),
    }),
    helper.accessor("document_type", {
      header: "Type",
      enableSorting: false,
      cell: ({ getValue }) =>
        ({ invoice: "Invoice", credit_note: "Credit note", debit_note: "Debit note" })[
          getValue()
        ] ?? getValue(),
    }),
    helper.accessor("tax_paise", {
      header: "GST",
      sortFn: "basic",
      sortDescFirst: true,
      cell: ({ row }) => row.original.tax,
    }),
    helper.display({
      id: "status",
      header: "Status",
      cell: ({ row }) => {
        const entry = row.original;
        if (!comparisonAvailable)
          return <span className="text-muted-foreground">Not compared</span>;
        return entry.reason ? (
          <Tooltip>
            <TooltipTrigger
              render={
                <Button
                  variant="ghost"
                  size="sm"
                  className="h-auto justify-start p-0 font-normal"
                />
              }
            >
              {entry.status}
            </TooltipTrigger>
            <TooltipContent className="max-w-72">{entry.reason}</TooltipContent>
          </Tooltip>
        ) : (
          entry.status
        );
      },
    }),
    helper.display({
      id: "review",
      header: () => <span className="sr-only">Review</span>,
      cell: ({ row }) =>
        row.original.review_url ? (
          <Link
            to={row.original.review_url}
            className="text-sm underline underline-offset-4"
            aria-label={`Review ${row.original.number}`}
          >
            Review
          </Link>
        ) : null,
    }),
  ]);

export function PurchaseRegisterTable({
  rows,
  comparisonAvailable,
}: {
  rows: Entry[];
  comparisonAvailable: boolean;
}) {
  const columns = useMemo(() => makeColumns(comparisonAvailable), [comparisonAvailable]);
  const table = useTable({
    features,
    columns,
    data: rows,
    getRowId: (row) => row.id,
    enableMultiSort: false,
  });
  return (
    <Table>
      <TableHeader>
        {table.getHeaderGroups().map((group) => (
          <TableRow key={group.id}>
            {group.headers.map((header) => {
              const direction = header.column.getIsSorted();
              const numeric = header.column.id === "tax_paise";
              const Icon =
                direction === "asc" ? ArrowUp : direction === "desc" ? ArrowDown : ArrowUpDown;
              return (
                <TableHead
                  key={header.id}
                  className={numeric ? "text-right" : undefined}
                  aria-sort={
                    header.column.getCanSort()
                      ? direction === "asc"
                        ? "ascending"
                        : direction === "desc"
                          ? "descending"
                          : "none"
                      : undefined
                  }
                >
                  {header.column.getCanSort() ? (
                    <Button
                      variant="ghost"
                      size="sm"
                      className={`h-8 px-1 ${numeric ? "-mr-1" : "-ml-1"}`}
                      onClick={header.column.getToggleSortingHandler()}
                      aria-label={`Sort by ${header.column.columnDef.header}`}
                    >
                      <table.FlexRender header={header} />
                      <Icon className="size-3.5 text-muted-foreground" />
                    </Button>
                  ) : (
                    <table.FlexRender header={header} />
                  )}
                </TableHead>
              );
            })}
          </TableRow>
        ))}
      </TableHeader>
      <TableBody>
        {table.getRowModel().rows.map((row) => (
          <TableRow key={row.id}>
            {row.getAllCells().map((cell) => (
              <TableCell
                key={cell.id}
                className={`py-2 ${cell.column.id === "tax_paise" ? "text-right tabular-nums whitespace-nowrap" : cell.column.id === "vendor" ? "max-w-96" : "whitespace-nowrap"}`}
              >
                <table.FlexRender cell={cell} />
              </TableCell>
            ))}
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}
