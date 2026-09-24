import { useEffect, useRef } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useParams } from "@tanstack/react-router";
import { ArrowLeft, ArrowRight, FileText, RotateCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Progress } from "@/components/ui/progress";
import { Skeleton } from "@/components/ui/skeleton";
import { Spinner } from "@/components/ui/spinner";
import {
  Table,
  TableHeader,
  TableHead,
  TableBody,
  TableRow,
  TableCell,
} from "@/components/ui/table";
import { RecordTableRow, RecordTableLink } from "@/components/record-table-row";
import { fetchUploadResult, retryUploadRead, type UploadResult } from "@/lib/upload-api";
import { urlDestination } from "@/lib/route-url";
import { useSales } from "@/state/sales-workspace";

export function SalesUploadResult() {
  const { clientId, period, batchRef } = useParams({
    from: "/gst/$clientId/$period/sales/uploads/$batchRef",
  });
  const workspace = useSales();
  const cache = useQueryClient();
  const query = useQuery({
    queryKey: ["sales-upload-result", clientId, period, batchRef],
    queryFn: ({ signal }) => fetchUploadResult(Number(clientId), period, batchRef, signal),
    refetchInterval: (query) => (query.state.data?.processing ? 2000 : false),
    retry: false,
  });
  useEffect(() => {
    if (query.data && !query.data.processing) {
      void cache.invalidateQueries({ queryKey: ["sales", clientId, period] });
    }
  }, [query.data?.processing, clientId, period, cache]);
  const files = query.data?.files ?? [];
  const completed = files.reduce((sum, file) => sum + file.completed, 0);
  const knownTotal = files.length > 0 && files.every((file) => file.total !== null);
  const total = files.reduce((sum, file) => sum + (file.total ?? 0), 0);
  const failed = files.some((file) => file.state === "failed");
  const first = files.flatMap((file) => file.rows).find((row) => row.review_url);
  return (
    <div className="space-y-8">
      <Link
        to="/gst/$clientId/$period/sales/uploads"
        params={{ clientId, period }}
        className="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"
      >
        <ArrowLeft className="size-4" /> All uploads
      </Link>
      <header className="flex items-start justify-between gap-6">
        <div className="space-y-2">
          <h1 className="text-2xl font-semibold tracking-tight">
            {files.length === 1 ? files[0].name : "Upload results"}
          </h1>
          <p className="text-sm text-muted-foreground">
            {workspace.client.name} ·{" "}
            {new Date(`${period}-01T12:00:00`).toLocaleDateString("en-IN", {
              month: "long",
              year: "numeric",
            })}
          </p>
        </div>
        {first?.review_url && (
          <Button nativeButton={false} render={<Link {...urlDestination(first.review_url)} />}>
            Review invoices <ArrowRight />
          </Button>
        )}
      </header>
      {query.isPending ? (
        <Skeleton className="h-48 w-full" />
      ) : query.isError ? (
        <div role="alert" className="space-y-3">
          <p>{query.error.message}</p>
          <Button variant="outline" onClick={() => query.refetch()}>
            Try again
          </Button>
        </div>
      ) : (
        <>
          <section className="space-y-3" aria-label="Reading progress">
            <div className="flex items-center gap-3">
              {query.data.processing && <Spinner aria-hidden="true" />}
              <p role="status" className="text-lg font-medium">
                {knownTotal
                  ? `${completed} of ${total} invoices read`
                  : completed
                    ? `${completed} invoices read`
                    : query.data.processing
                      ? "Finding invoices…"
                      : "No invoices read"}
              </p>
              {failed && <Badge variant="secondary">Reading stopped</Badge>}
            </div>
            {query.data.processing && (
              <Progress
                aria-label="Invoices read"
                value={knownTotal && total > 0 ? (completed / total) * 100 : null}
              />
            )}
            <p className="text-sm text-muted-foreground">
              {failed
                ? "Your completed results are saved. Retry the failed file below to finish reading."
                : query.data.processing
                  ? "Start reviewing now. More invoices will appear here as they are read."
                  : "Reading is finished. Check the invoices against their source PDFs."}
            </p>
          </section>
          <div className="space-y-6">
            {files.map((file) => (
              <UploadFile
                key={file.id}
                file={file}
                clientId={clientId}
                period={period}
                batchRef={batchRef}
                canRetry={workspace.can_upload}
              />
            ))}
          </div>
        </>
      )}
    </div>
  );
}

function UploadFile({
  file,
  clientId,
  period,
  batchRef,
  canRetry,
}: {
  file: UploadResult["files"][number];
  clientId: string;
  period: string;
  batchRef: string;
  canRetry: boolean;
}) {
  const cache = useQueryClient();
  const request = useRef<AbortController | null>(null);
  useEffect(() => () => request.current?.abort(), []);
  const retry = useMutation({
    mutationFn: (controller: AbortController) =>
      retryUploadRead(Number(clientId), period, batchRef, file.id, controller.signal),
    retry: false,
    networkMode: "always",
    onSuccess: async () => {
      await Promise.all([
        cache.invalidateQueries({ queryKey: ["sales-upload-result", clientId, period, batchRef] }),
        cache.invalidateQueries({ queryKey: ["sales-uploads", Number(clientId), period] }),
      ]);
    },
    onSettled: () => {
      request.current = null;
    },
  });
  return (
    <section className="overflow-hidden rounded-xl border bg-card">
      <div className="flex items-center justify-between gap-4 border-b px-5 py-4">
        <div className="flex min-w-0 items-center gap-3">
          <FileText className="size-4 shrink-0 text-muted-foreground" />
          <h2 className="truncate text-sm font-medium">{file.name}</h2>
        </div>
        {file.original_url && (
          <a
            href={file.original_url}
            target="_blank"
            rel="noreferrer"
            className="shrink-0 text-sm underline underline-offset-4"
          >
            Open source PDF
          </a>
        )}
      </div>
      {file.state === "failed" && (
        <div className="flex items-center justify-between gap-5 border-b bg-muted/40 px-5 py-4">
          <p className="text-sm">{file.message}</p>
          {canRetry && (
            <Button
              variant="outline"
              disabled={retry.isPending}
              onClick={() => {
                if (request.current) return;
                const controller = new AbortController();
                request.current = controller;
                retry.mutate(controller);
              }}
            >
              {retry.isPending ? <Spinner aria-hidden="true" /> : <RotateCw />}
              {retry.isPending ? "Starting…" : "Retry reading"}
            </Button>
          )}
        </div>
      )}
      {retry.isError && (
        <p role="alert" className="px-5 py-3 text-sm text-destructive">
          {retry.error.message}
        </p>
      )}
      {file.rows.length > 0 ? (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="pl-5">Invoice</TableHead>
              <TableHead>Customer</TableHead>
              <TableHead>PDF page</TableHead>
              <TableHead>Reading status</TableHead>
              <TableHead>
                <span className="sr-only">Review</span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {file.rows.map((row) => {
              const Row = row.review_url ? RecordTableRow : TableRow;
              return (
                <Row key={row.id}>
                  <TableCell className="pl-5 font-medium">
                    {row.number || "Invoice number pending"}
                  </TableCell>
                  <TableCell>{row.buyer || "—"}</TableCell>
                  <TableCell className="tabular-nums">{row.pages.join(", ") || "—"}</TableCell>
                  <TableCell>
                    {row.state === "reading" ? (
                      <span className="inline-flex items-center gap-2 text-muted-foreground">
                        <Spinner aria-hidden="true" />
                        Reading…
                      </span>
                    ) : row.state === "failed" ? (
                      <Badge variant="secondary">Could not read</Badge>
                    ) : row.state === "removed" ? (
                      "Removed from working"
                    ) : (
                      "Read"
                    )}
                  </TableCell>
                  <TableCell className="pr-5 text-right">
                    {row.review_url && (
                      <RecordTableLink
                        {...urlDestination(row.review_url)}
                        className="inline-flex items-center gap-1 text-sm font-medium"
                      >
                        Review <ArrowRight className="size-3.5" />
                      </RecordTableLink>
                    )}
                  </TableCell>
                </Row>
              );
            })}
          </TableBody>
        </Table>
      ) : (
        <div className="px-5 py-10 text-center text-sm text-muted-foreground">
          {file.state === "received" || file.state === "extracting"
            ? "Finding the invoices in this PDF…"
            : "No invoice results available yet."}
        </div>
      )}
    </section>
  );
}
