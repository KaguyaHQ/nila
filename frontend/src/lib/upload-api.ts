import { ApiError } from "./sales-api";

import type { components } from "./generated/workspace";

export type UploadHistory = components["schemas"]["UploadHistory"];
export type PreparedUpload = components["schemas"]["PreparedUpload"];
export type PrepareUpload = components["schemas"]["PrepareUpload"];
export type UploadToken = components["schemas"]["UploadToken"];
export type CommittedUpload = components["schemas"]["CommittedUpload"];

function uploadPath(client: number, period: string) {
  return `/api/workspace/sales/${encodeURIComponent(client)}/${encodeURIComponent(period)}/uploads`;
}

async function request<T>(url: string, signal: AbortSignal, body?: unknown): Promise<T> {
  const headers: Record<string, string> = { Accept: "application/json" };
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    headers["X-CSRF-Token"] =
      document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "";
  }
  const response = await fetch(url, {
    method: body === undefined ? "GET" : "POST",
    credentials: "same-origin",
    headers,
    signal,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  if (!response.ok) {
    const data = await response.json().catch(() => null);
    throw new ApiError(
      response.status,
      typeof data?.error === "string"
        ? data.error
        : "We couldn't complete this request. Please try again.",
    );
  }
  return response.json();
}

export function fetchUploads(client: number, period: string, signal: AbortSignal) {
  return request<UploadHistory>(uploadPath(client, period), signal);
}

export function prepareUpload(client: number, period: string, files: File[], signal: AbortSignal) {
  return request<PreparedUpload>(`${uploadPath(client, period)}/prepare`, signal, {
    files: files.map(({ name, size }) => ({ name, size })),
  } satisfies PrepareUpload);
}

export function commitUpload(client: number, period: string, token: string, signal: AbortSignal) {
  return request<CommittedUpload>(uploadPath(client, period), signal, {
    token,
  } satisfies UploadToken);
}

export function refreshUpload(client: number, period: string, token: string, signal: AbortSignal) {
  return request<PreparedUpload>(`${uploadPath(client, period)}/prepare`, signal, {
    token,
  } satisfies UploadToken);
}

export function uploadPdf(
  url: string,
  file: File,
  signal: AbortSignal,
  onProgress: (percent: number) => void,
): Promise<void> {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    const abort = () => xhr.abort();
    const finish = (error?: Error) => {
      signal.removeEventListener("abort", abort);
      if (error) reject(error);
      else resolve();
    };
    if (signal.aborted) {
      reject(new DOMException("Upload cancelled", "AbortError"));
      return;
    }
    xhr.open("PUT", url);
    xhr.setRequestHeader("Content-Type", "application/pdf");
    xhr.timeout = 10 * 60 * 1000;
    xhr.upload.onprogress = (event) => {
      if (event.lengthComputable)
        onProgress(Math.min(99, Math.round((event.loaded / event.total) * 100)));
    };
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        onProgress(100);
        finish();
      } else finish(new ApiError(xhr.status, `Couldn't upload ${file.name}. Please retry.`));
    };
    xhr.onerror = () =>
      finish(new Error(`Connection lost while uploading ${file.name}. Please retry.`));
    xhr.ontimeout = () => finish(new Error(`Upload timed out for ${file.name}. Please retry.`));
    xhr.onabort = () => finish(new DOMException("Upload cancelled", "AbortError"));
    signal.addEventListener("abort", abort, { once: true });
    xhr.send(file);
  });
}
