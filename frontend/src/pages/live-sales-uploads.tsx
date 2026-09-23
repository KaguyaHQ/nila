import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { urlDestination } from "@/lib/route-url";
import { ApiError } from "@/lib/sales-api";
import {
  commitUpload,
  fetchUploads,
  prepareUpload,
  refreshUpload,
  uploadPdf,
  type PreparedUpload,
  type UploadHistory,
} from "@/lib/upload-api";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate } from "@tanstack/react-router";
import { ArrowLeft, ArrowRight, FileText, Plus, Upload, X } from "lucide-react";
import {
  createContext,
  useContext,
  useEffect,
  useReducer,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { useSales } from "./live-sales";

type UploadDraft = {
  files: File[];
  prepared: { current: PreparedUpload | null };
  completed: { current: Set<number> };
  progress: Record<number, number>;
  stage: string;
};
const UploadDrafts = createContext<Map<string, UploadDraft> | null>(null);

export function LiveUploadDraftProvider({ children }: { children: ReactNode }) {
  const [drafts] = useState(() => new Map<string, UploadDraft>());
  useEffect(() => {
    const warn = (event: BeforeUnloadEvent) => {
      if (![...drafts.values()].some((draft) => draft.prepared.current)) return;
      event.preventDefault();
      event.returnValue = "";
    };
    window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [drafts]);
  return <UploadDrafts.Provider value={drafts}>{children}</UploadDrafts.Provider>;
}

export function LiveSalesUpload() {
  const data = useSales();
  return <UploadForm key={`${data.client.id}/${data.period}`} />;
}

function UploadForm() {
  const data = useSales();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const draftContext = useContext(UploadDrafts);
  if (!draftContext) throw new Error("Upload draft provider is missing");
  const drafts = draftContext;
  const draftKey = `${data.client.id}/${data.period}`;
  const [draft] = useState(() => {
    const saved = drafts.get(draftKey);
    if (saved) return saved;
    const created: UploadDraft = {
      files: [],
      prepared: { current: null },
      completed: { current: new Set() },
      progress: {},
      stage: "",
    };
    drafts.set(draftKey, created);
    return created;
  });
  const [, redraw] = useReducer((value) => value + 1, 0);
  const picker = useRef<HTMLInputElement>(null);
  const controller = useRef<AbortController | null>(null);
  const { files, progress, stage, prepared, completed } = draft;
  const locked = prepared.current !== null;
  const [errors, setErrors] = useState<string[]>([]);
  const [dragging, setDragging] = useState(false);

  function setFiles(next: File[] | ((previous: File[]) => File[])) {
    draft.files = typeof next === "function" ? next(draft.files) : next;
    redraw();
  }
  function setProgress(
    next: Record<number, number> | ((previous: Record<number, number>) => Record<number, number>),
  ) {
    draft.progress = typeof next === "function" ? next(draft.progress) : next;
    redraw();
  }
  function setStage(next: string) {
    draft.stage = next;
    redraw();
  }

  useEffect(
    () => () => {
      if (!controller.current) return;
      controller.current.abort();
      draft.stage =
        draft.completed.current.size === draft.files.length
          ? "Your PDFs were sent. Retry to confirm the saved upload."
          : "Upload paused. Retry to continue with the remaining files.";
    },
    [draft],
  );

  function selectFiles(incoming: File[]) {
    if (locked || busy || !data.can_upload) return;
    const selected = [...files];
    const rejected: string[] = [];
    for (const file of incoming) {
      if (!/\.pdf$/i.test(file.name) || (file.type && file.type !== "application/pdf"))
        rejected.push(`${file.name}: choose a PDF file.`);
      else if (!file.size) rejected.push(`${file.name}: this file is empty.`);
      else if (file.size > 50_000_000) rejected.push(`${file.name}: the limit is 50 MB per PDF.`);
      else if (
        selected.some(
          (existing) =>
            existing.name === file.name &&
            existing.size === file.size &&
            existing.lastModified === file.lastModified,
        )
      )
        continue;
      else if (selected.length >= 50) rejected.push("Choose up to 50 PDFs at a time.");
      else selected.push(file);
    }
    upload.reset();
    setFiles(selected);
    setErrors([...new Set(rejected)]);
  }

  const upload = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: async (current: AbortController) => {
      try {
        if (!prepared.current) {
          setStage("Preparing upload…");
          const result = await prepareUpload(data.client.id, data.period, files, current.signal);
          if (
            result.files.length !== files.length ||
            result.files.some((file, index) => file.name !== files[index].name)
          )
            throw new Error("The upload couldn't be prepared. Please try again.");
          prepared.current = result;
        }
        let ticket = prepared.current;
        for (let index = 0; index < files.length; index++) {
          if (completed.current.has(index)) continue;
          setStage(`Uploading file ${index + 1} of ${files.length}…`);
          const sendFile = () =>
            uploadPdf(ticket.files[index].url, files[index], current.signal, (percent) =>
              setProgress((values) => ({ ...values, [index]: percent })),
            );
          try {
            await sendFile();
          } catch (error) {
            if (!(error instanceof ApiError && error.status === 403)) throw error;
            ticket = await refreshUpload(data.client.id, data.period, ticket.token, current.signal);
            prepared.current = ticket;
            await sendFile();
          }
          completed.current.add(index);
        }
        if (current.signal.aborted) return;
        setStage("Saving upload…");
        await commitUpload(data.client.id, data.period, ticket.token, current.signal);
        if (current.signal.aborted) return;
      } catch (error) {
        if (!current.signal.aborted) {
          if (error instanceof ApiError && error.status === 422 && prepared.current) {
            prepared.current = null;
            completed.current.clear();
            setProgress({});
            setStage(
              "This upload could not be saved. Remove or replace any rejected PDF, then upload again.",
            );
          } else
            setStage(
              completed.current.size === files.length
                ? "Your PDFs were sent. Retry to confirm the saved upload."
                : "Upload stopped. Retry to continue with the remaining files.",
            );
        }
        throw error;
      } finally {
        controller.current = null;
      }
    },
    onSuccess: (_result, current) => {
      if (current.signal.aborted) return;
      drafts.delete(draftKey);
      void queryClient.invalidateQueries({
        queryKey: ["sales", String(data.client.id), data.period],
      });
      void queryClient.invalidateQueries({
        queryKey: ["sales-uploads", data.client.id, data.period],
      });
      navigate({
        to: "/gst/$clientId/$period/sales/uploads",
        params: { clientId: String(data.client.id), period: data.period },
      });
    },
  });
  const busy = upload.isPending;
  const displayedErrors = upload.error ? [...errors, upload.error.message] : errors;
  function submit() {
    if (controller.current || busy || !files.length || !data.can_upload) return;
    const current = new AbortController();
    controller.current = current;
    setErrors([]);
    upload.mutate(current);
  }

  return (
    <div className="mx-auto max-w-3xl space-y-6">
      <div>
        <Button
          variant="ghost"
          size="sm"
          className="mb-4 -ml-3"
          nativeButton={false}
          role="link"
          render={
            <Link
              to="/gst/$clientId/$period/sales"
              params={{ clientId: String(data.client.id), period: data.period }}
            />
          }
        >
          <ArrowLeft /> Sales &amp; GSTR-1
        </Button>
        <h1 className="text-2xl font-semibold tracking-tight">Add sales bills</h1>
        <p className="mt-2 text-sm text-muted-foreground">
          {data.client.name} · {data.month_label}
        </p>
      </div>
      {!data.can_upload && (
        <p role="status" className="rounded-lg border bg-muted/40 px-4 py-3 text-sm">
          Your role allows viewing, not uploading.
        </p>
      )}
      <Card className="gap-0 overflow-hidden py-0 shadow-none">
        <div
          className={`m-6 flex flex-col items-center rounded-lg border border-dashed px-6 py-12 text-center ${dragging ? "bg-muted" : ""}`}
          onDragOver={(event) => {
            event.preventDefault();
            if (!locked && !busy && data.can_upload) setDragging(true);
          }}
          onDragLeave={(event) => {
            if (!event.currentTarget.contains(event.relatedTarget as Node | null))
              setDragging(false);
          }}
          onDrop={(event) => {
            event.preventDefault();
            setDragging(false);
            selectFiles(Array.from(event.dataTransfer.files));
          }}
        >
          <Upload className="mb-4 size-6 text-muted-foreground" aria-hidden="true" />
          <h2 className="text-sm font-medium">Drop your sales PDFs here</h2>
          <p className="mt-2 text-sm text-muted-foreground">
            One bill or a combined PDF of several bills.
          </p>
          <Button
            className="mt-5"
            disabled={busy || locked || !data.can_upload}
            onClick={() => picker.current?.click()}
          >
            Choose PDFs
          </Button>
          <Input
            ref={picker}
            className="hidden"
            type="file"
            multiple
            accept=".pdf,application/pdf"
            aria-label="Choose sales PDF files"
            disabled={busy || locked || !data.can_upload}
            onChange={(event) => {
              selectFiles(Array.from(event.currentTarget.files ?? []));
              event.currentTarget.value = "";
            }}
          />
        </div>
        <p className="border-t bg-muted/40 px-6 py-4 text-sm text-muted-foreground">
          Up to 50 PDFs, 50 MB each. Nila reads the bills after upload.
        </p>
      </Card>
      {displayedErrors.length > 0 && (
        <div
          role="alert"
          className="space-y-1 rounded-lg border border-destructive/30 px-4 py-3 text-sm text-destructive"
        >
          {displayedErrors.map((error) => (
            <p key={error}>{error}</p>
          ))}
        </div>
      )}
      {files.length > 0 && (
        <section aria-labelledby="selected-pdfs" className="space-y-3">
          <h2 id="selected-pdfs" className="text-sm font-semibold">
            {files.length} {files.length === 1 ? "file" : "files"} selected
          </h2>
          <ul className="divide-y rounded-lg border bg-card">
            {files.map((file, index) => (
              <li
                key={`${file.name}-${file.size}-${file.lastModified}`}
                className="flex items-center gap-3 px-4 py-3"
              >
                <FileText className="size-5 shrink-0 text-muted-foreground" aria-hidden="true" />
                <div className="min-w-0 flex-1">
                  <p className="break-words text-sm font-medium">{file.name}</p>
                  <p className="mt-1 text-xs text-muted-foreground">
                    {(file.size / 1024 / 1024).toFixed(2)} MB
                    {progress[index] !== undefined && ` · ${progress[index]}% transferred`}
                  </p>
                  {progress[index] !== undefined && (
                    <progress
                      aria-label={`Upload progress for ${file.name}`}
                      value={progress[index]}
                      max={100}
                      className="mt-2 h-1.5 w-full accent-foreground"
                    />
                  )}
                </div>
                {!locked && !busy && (
                  <Button
                    variant="ghost"
                    size="icon"
                    aria-label={`Remove ${file.name}`}
                    onClick={() =>
                      setFiles((values) => values.filter((_, position) => position !== index))
                    }
                  >
                    <X />
                  </Button>
                )}
              </li>
            ))}
          </ul>
        </section>
      )}
      {stage && (
        <p role="status" className="text-sm text-muted-foreground">
          {stage}
        </p>
      )}
      <div className="flex flex-wrap justify-between gap-3">
        <Button
          variant="outline"
          nativeButton={false}
          role="link"
          render={
            <Link
              to="/gst/$clientId/$period/sales/uploads"
              params={{ clientId: String(data.client.id), period: data.period }}
            />
          }
        >
          View uploads <ArrowRight />
        </Button>
        <Button disabled={busy || !files.length || !data.can_upload} onClick={submit}>
          {busy ? "Uploading…" : locked ? "Retry upload" : "Upload PDFs"}
          <Upload />
        </Button>
      </div>
    </div>
  );
}

export function LiveSalesUploads() {
  const data = useSales();
  function reviewLink(batch: UploadHistory["batches"][number]) {
    const invoice = data.rows.find((row) => row.path && batch.invoice_ids?.includes(row.id));
    const content = (
      <>
        Review upload <ArrowRight className="ml-1 inline size-4" />
      </>
    );
    const className = "text-sm font-medium underline-offset-4 hover:underline";
    return invoice?.path ? (
      <Link {...urlDestination(`${invoice.path}?filter=all`)} className={className}>
        {content}
      </Link>
    ) : (
      <a href={batch.review_url} className={className}>
        {content}
      </a>
    );
  }
  const query = useQuery({
    queryKey: ["sales-uploads", data.client.id, data.period],
    queryFn: ({ signal }) => fetchUploads(data.client.id, data.period, signal),
    refetchInterval: (query) => (query.state.data?.processing ? 3000 : false),
    retry: (count, error) => !(error instanceof ApiError && error.status < 500) && count < 1,
  });
  return (
    <>
      <Button
        variant="ghost"
        size="sm"
        className="mb-4 -ml-3"
        nativeButton={false}
        role="link"
        render={
          <Link
            to="/gst/$clientId/$period/sales"
            params={{ clientId: String(data.client.id), period: data.period }}
          />
        }
      >
        <ArrowLeft /> Sales &amp; GSTR-1
      </Button>
      <div className="mb-7 flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Uploads</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            {data.client.name} · {data.month_label}
          </p>
        </div>
        <Button
          nativeButton={false}
          role="link"
          render={
            <Link
              to="/gst/$clientId/$period/sales/upload"
              params={{ clientId: String(data.client.id), period: data.period }}
            />
          }
        >
          <Plus /> Add invoices
        </Button>
      </div>
      {query.isPending ? (
        <p role="status" className="text-sm text-muted-foreground">
          Loading uploads…
        </p>
      ) : query.isError ? (
        <div className="space-y-4">
          <p role="alert">{query.error.message}</p>
          <Button variant="outline" onClick={() => query.refetch()}>
            Try again
          </Button>
        </div>
      ) : (
        <>
          {query.data.processing && (
            <p role="status" className="mb-5 rounded-lg border bg-muted/40 px-4 py-3 text-sm">
              Nila is reading your PDFs. This list updates automatically.
            </p>
          )}
          {query.data.batches.length === 0 ? (
            <div className="rounded-xl border bg-card px-6 py-14 text-center">
              <FileText className="mx-auto mb-4 size-6 text-muted-foreground" />
              <h2 className="font-medium">No uploads yet</h2>
              <p className="mt-2 text-sm text-muted-foreground">
                Add sales bills to start this month's working.
              </p>
            </div>
          ) : (
            <div className="space-y-5">
              {query.data.batches.map((batch) => (
                <section
                  key={batch.id}
                  className="overflow-hidden rounded-xl border bg-card"
                  aria-label={`Upload from ${new Date(batch.created_at).toLocaleString("en-IN")}`}
                >
                  <div className="flex flex-wrap items-center justify-between gap-3 border-b bg-muted/20 px-5 py-3">
                    <p className="text-sm text-muted-foreground">
                      {new Date(batch.created_at).toLocaleString("en-IN", {
                        dateStyle: "medium",
                        timeStyle: "short",
                      })}
                    </p>
                    {reviewLink(batch)}
                  </div>
                  <ul className="divide-y">
                    {batch.files.map((file) => (
                      <li
                        key={file.id}
                        className="flex flex-wrap items-start justify-between gap-4 px-5 py-4"
                      >
                        <div className="flex min-w-0 flex-1 items-start gap-3">
                          <FileText className="mt-0.5 size-5 shrink-0 text-muted-foreground" />
                          <div className="min-w-0">
                            <p className="break-words text-sm font-medium">{file.name}</p>
                            <p className="mt-1 text-sm text-muted-foreground">
                              {file.invoice_count}{" "}
                              {file.invoice_count === 1 ? "invoice" : "invoices"}
                            </p>
                            {file.error && (
                              <p className="mt-2 text-sm text-destructive">{file.error}</p>
                            )}
                            {file.original_url && (
                              <a
                                href={file.original_url}
                                target="_blank"
                                rel="noopener noreferrer"
                                className="mt-2 inline-block text-sm underline underline-offset-4"
                              >
                                Open source PDF
                                <span className="sr-only"> for {file.name} (new tab)</span>
                              </a>
                            )}
                          </div>
                        </div>
                        <Badge
                          variant="secondary"
                          className={file.error ? "bg-amber-50 text-amber-800" : ""}
                        >
                          {file.label}
                        </Badge>
                      </li>
                    ))}
                  </ul>
                </section>
              ))}
            </div>
          )}
          <div className="mt-6 flex justify-end">
            <Button
              variant="outline"
              nativeButton={false}
              role="link"
              render={
                <Link
                  to="/gst/$clientId/$period/sales/register"
                  params={{ clientId: String(data.client.id), period: data.period }}
                />
              }
            >
              View sales register <ArrowRight />
            </Button>
          </div>
        </>
      )}
    </>
  );
}
