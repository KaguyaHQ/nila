import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useRef, useState } from "react";
import { Link } from "@tanstack/react-router";
import { ArrowRight, FileSpreadsheet, Upload, X } from "lucide-react";
import {
  Attachment,
  AttachmentMedia,
  AttachmentContent,
  AttachmentTitle,
  AttachmentDescription,
  AttachmentActions,
  AttachmentAction,
} from "@/components/ui/attachment";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

import { Card } from "@/components/ui/card";

import { ApiError, type SalesWorkspace } from "@/lib/sales-api";

const path = (data: SalesWorkspace) =>
  `/api/workspace/sales/${data.client.id}/${data.period}/reports`;
const csrf = () =>
  document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "";
async function response<T>(result: Response): Promise<T> {
  const body = await result.json();
  if (!result.ok) throw new ApiError(result.status, body.error ?? "The report could not be saved.");
  return body;
}

export function SalesReportUpload({
  data,
  onImported,
  onBusyChange,
}: {
  data: SalesWorkspace;
  onImported: () => void;
  onBusyChange: (busy: boolean) => void;
}) {
  const picker = useRef<HTMLInputElement>(null);
  const [selectedFiles, setFiles] = useState<File[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);
  const cache = useQueryClient();
  const upload = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: async () => {
      if (!selectedFiles.length || !data.can_upload) throw new Error("Choose Excel reports.");
      onBusyChange(true);
      const body = new FormData();
      selectedFiles.forEach((file) => body.append("files[]", file));
      return response(
        await fetch(path(data), {
          method: "POST",
          credentials: "same-origin",
          headers: { "X-CSRF-Token": csrf() },
          body,
        }),
      );
    },
    onSuccess: async () => {
      await cache.invalidateQueries({ queryKey: ["sales"] });
      await cache.invalidateQueries({ queryKey: ["sales-reports"] });
      onImported();
    },
    onSettled: () => onBusyChange(false),
  });
  const busy = upload.isPending;
  function selectFiles(files: File[]) {
    if (busy || !data.can_upload || !files.length) return;
    upload.reset();
    if (files.some((file) => !/\.(?:xls|xlsx|csv)$/i.test(file.name) || file.size === 0 || file.size > 5_000_000)) {
      setError("Choose non-empty .xls, .xlsx or .csv files no larger than 5 MB each.");
      return;
    }
    const added = files.filter((file) => !selectedFiles.some((selected) =>
      selected.name === file.name && selected.size === file.size && selected.lastModified === file.lastModified,
    ));
    if (selectedFiles.length + added.length > 20) {
      setError("Choose no more than 20 Excel reports.");
      return;
    }
    if ([...selectedFiles, ...added].reduce((total, file) => total + file.size, 0) > 25_000_000) {
      setError("Choose no more than 25 MB of Excel reports in total.");
      return;
    }
    setFiles((current) => [...current, ...added]);
    setError(null);
  }
  function submit() {
    if (selectedFiles.length && !busy && data.can_upload) {
      setError(null);
      upload.mutate();
    }
  }
  return (
    <div className="space-y-5">
      {!data.can_upload && (
        <p role="status" className="rounded-lg border bg-muted/40 px-4 py-3 text-sm">
          Your role allows viewing, not uploading.
        </p>
      )}
      <Card className="gap-0 overflow-hidden py-0 shadow-none">
        <div
          className={`${selectedFiles.length ? "flex flex-wrap items-center justify-between gap-3 p-4" : "m-6 flex flex-col items-center rounded-lg border border-dashed px-6 py-12 text-center"} ${dragging ? "bg-muted" : ""}`}
          onDragOver={(event) => {
            event.preventDefault();
            if (!busy && data.can_upload) setDragging(true);
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
          {selectedFiles.length ? (
            <h2 className="text-sm font-semibold">{selectedFiles.length} {selectedFiles.length === 1 ? "file" : "files"} selected</h2>
          ) : (
            <>
              <Upload className="mb-4 size-6 text-muted-foreground" aria-hidden="true" />
              <h2 className="text-sm font-medium">Drop your Excel reports here</h2>
              <p className="mt-2 text-sm text-muted-foreground">
                Sales reports from your client’s software.
              </p>
            </>
          )}
          <div className={selectedFiles.length ? "flex items-center gap-2" : "mt-5"}>
            <Button
              variant={selectedFiles.length ? "outline" : "default"}
              disabled={busy || !data.can_upload}
              onClick={() => picker.current?.click()}
            >
              {selectedFiles.length ? "Add more reports" : "Choose Excel reports"}
            </Button>
            {selectedFiles.length > 0 && (
              <Button disabled={busy || !data.can_upload} onClick={submit}>
                {busy ? "Reading reports…" : "Upload reports"}
                <Upload />
              </Button>
            )}
          </div>
          <Input
            ref={picker}
            className="hidden"
            type="file"
            multiple
            accept=".xls,.xlsx,.csv"
            aria-label="Choose sales Excel reports"
            disabled={busy || !data.can_upload}
            onChange={(event) => {
              selectFiles(Array.from(event.currentTarget.files ?? []));
              event.currentTarget.value = "";
            }}
          />
        </div>
        <p className="border-t bg-muted/40 px-6 py-4 text-sm text-muted-foreground">
          Up to 20 Excel reports (.xls, .xlsx or .csv), 5 MB each and 25 MB total.
        </p>
      </Card>
      {(error || upload.error) && (
        <p
          role="alert"
          className="rounded-lg border border-destructive/30 px-4 py-3 text-sm text-destructive"
        >
          {error ?? upload.error?.message}
        </p>
      )}
      {selectedFiles.map((file, index) => (
        <Attachment key={`${file.name}-${file.size}-${file.lastModified}-${index}`} className="w-full" state={busy ? "uploading" : "idle"}>
          <AttachmentMedia>
            <FileSpreadsheet aria-hidden="true" />
          </AttachmentMedia>
          <AttachmentContent>
            <AttachmentTitle className="whitespace-normal break-words">{file.name}</AttachmentTitle>
            <AttachmentDescription>{(file.size / 1024 / 1024).toFixed(2)} MB</AttachmentDescription>
          </AttachmentContent>
          {!busy && (
            <AttachmentActions>
              <AttachmentAction
                size="icon-sm"
                aria-label={`Remove ${file.name}`}
                onClick={() => {
                  setFiles((current) => current.filter((_, item) => item !== index));
                  setError(null);
                  upload.reset();
                }}
              >
                <X />
              </AttachmentAction>
            </AttachmentActions>
          )}
        </Attachment>
      ))}
      <div className="flex flex-wrap justify-between gap-3">
        <Button
          variant="outline"
          nativeButton={false}
          role="link"
          disabled={busy}
          render={
            <Link
              to="/gst/$clientId/$period/sales/uploads"
              params={{ clientId: String(data.client.id), period: data.period }}
            />
          }
        >
          View uploads <ArrowRight />
        </Button>
        {!selectedFiles.length && (
          <Button disabled>
            Upload reports <Upload />
          </Button>
        )}
      </div>
    </div>
  );
}
