import { useEffect, useRef, useState } from "react";
import { Link } from "react-router-dom";
import { Download, FileJson, FileSpreadsheet, LoaderCircle } from "lucide-react";
import { Button } from "@/components/ui/button";
import type { SalesExportItem, SalesWorkspace } from "@/lib/sales-api";

function downloadName(disposition: string | null) {
  if (!disposition) return null;
  const encoded = disposition.match(/filename\*\s*=\s*UTF-8''([^;]+)/i);
  if (encoded) {
    try {
      return decodeURIComponent(encoded[1].trim().replace(/^"|"$/g, ""));
    } catch {
      /* Fall back to the ordinary filename. */
    }
  }
  const quoted = disposition.match(/filename\s*=\s*"((?:\\.|[^"\\])*)"/i);
  if (quoted) return quoted[1].replace(/\\(.)/g, "$1");
  return disposition.match(/filename\s*=\s*([^;]+)/i)?.[1].trim() || null;
}

export function SalesExports({ data }: { data: SalesWorkspace }) {
  return <ExportList key={`${data.client.id}/${data.period}`} data={data} />;
}

function ExportList({ data }: { data: SalesWorkspace }) {
  const [busy, setBusy] = useState<SalesExportItem["id"] | null>(null);
  const [error, setError] = useState<{ id: string; message: string } | null>(null);
  const operation = useRef<AbortController | null>(null);
  useEffect(() => () => operation.current?.abort(), []);
  if (!data.exports) return null;
  const { items, blockers, status } = data.exports;

  async function download(item: SalesExportItem) {
    if (!item.enabled || operation.current) return;
    const controller = new AbortController();
    operation.current = controller;
    setBusy(item.id);
    setError(null);
    try {
      const response = await fetch(item.url, {
        credentials: "same-origin",
        signal: controller.signal,
      });
      if (!response.ok) {
        const type = response.headers.get("content-type") ?? "";
        const problem = type.includes("json") ? await response.json().catch(() => null) : null;
        const plainText = type.includes("text/plain") ? (await response.text()).trim() : "";
        throw new Error(
          typeof problem?.error === "string"
            ? problem.error
            : plainText ||
                (response.status === 401
                  ? "Sign in again to download this file."
                  : "This file could not be downloaded. Please try again."),
        );
      }
      if (response.redirected || response.headers.get("content-type")?.includes("text/html"))
        throw new Error("Your session may have expired. Sign in again before downloading.");
      const filename = downloadName(response.headers.get("content-disposition"));
      if (!filename) throw new Error("The server did not return a download. Please try again.");
      const blob = await response.blob();
      if (controller.signal.aborted) return;
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = filename;
      document.body.append(link);
      link.click();
      link.remove();
      window.setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (failure) {
      if (!controller.signal.aborted)
        setError({
          id: item.id,
          message:
            failure instanceof Error
              ? failure.message
              : "This file could not be downloaded. Please try again.",
        });
    } finally {
      operation.current = null;
      if (!controller.signal.aborted) setBusy(null);
    }
  }

  return (
    <section aria-labelledby="sales-exports-heading" className="space-y-4">
      <h2 id="sales-exports-heading" className="text-sm font-semibold">
        Exports
      </h2>
      {status && <p className="text-sm leading-6 text-muted-foreground">{status}</p>}
      <div className="divide-y">
        {items.map((item) => {
          const Icon = item.format === "JSON" ? FileJson : FileSpreadsheet;
          const reasonId = item.reason ? `export-reason-${item.id}` : undefined;
          return (
            <div key={item.id} className="py-3 first:pt-0">
              <Button
                variant="ghost"
                className="h-auto w-full justify-start gap-3 px-0 py-1 text-left whitespace-normal hover:bg-transparent"
                disabled={!item.enabled || busy !== null}
                aria-describedby={reasonId}
                onClick={() => download(item)}
              >
                <Icon className="size-4 shrink-0 text-muted-foreground" />
                <span className="min-w-0 flex-1">
                  <span className="block text-sm font-medium">{item.label}</span>
                  <span className="mt-1 block text-xs font-normal text-muted-foreground">
                    {busy === item.id ? "Preparing download…" : item.format}
                  </span>
                </span>
                {busy === item.id ? (
                  <LoaderCircle
                    className="size-4 animate-spin motion-reduce:animate-none"
                    aria-hidden="true"
                  />
                ) : (
                  <Download className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
                )}
              </Button>
              {item.reason && (
                <p id={reasonId} className="mt-2 text-sm leading-6 text-muted-foreground">
                  {item.reason}
                </p>
              )}
              {error?.id === item.id && (
                <p role="alert" className="mt-2 text-sm leading-6 text-destructive">
                  {error.message}
                </p>
              )}
            </div>
          );
        })}
      </div>
      {blockers.length > 0 && (
        <details className="border-t pt-3 text-sm">
          <summary className="cursor-pointer font-medium">
            Before GSTR-1 JSON ({blockers.length})
          </summary>
          <ul className="mt-3 space-y-3 leading-6 text-muted-foreground">
            {blockers.map((blocker) => (
              <li key={blocker.id}>
                {blocker.path ? (
                  blocker.external ? (
                    <a href={blocker.path} className="underline underline-offset-4">
                      {blocker.message}
                    </a>
                  ) : (
                    <Link to={blocker.path} className="underline underline-offset-4">
                      {blocker.message}
                    </Link>
                  )
                ) : (
                  blocker.message
                )}
              </li>
            ))}
          </ul>
        </details>
      )}
    </section>
  );
}
