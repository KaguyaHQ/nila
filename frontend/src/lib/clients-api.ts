import { ApiError } from "./sales-api";

export type ClientIdentity = { id: number; name: string; gstin: string | null };
export type ClientsDirectory = {
  clients: (ClientIdentity & { sales_path: string })[];
  user: { name: string; org: string };
  can_edit: boolean;
  period: string;
};
export type ClientDetail = { client: ClientIdentity; can_edit: boolean };
export type ImportRow = {
  row: number;
  name: string | null;
  gstin: string | null;
  gst_username?: string | null;
  status: "ready" | "skip" | "invalid" | "added";
  message: string;
};
export type ImportPreview = { rows: ImportRow[]; token: string; ready_count: number };
export type ImportResult = { rows: ImportRow[]; added_count: number; skipped_count: number; invalid_count: number };

export class ClientApiError extends ApiError {
  constructor(status: number, message: string, public fields: Record<string, string[]> = {}) {
    super(status, message);
  }
}

async function request<T>(path: string, signal: AbortSignal, method = "GET", body?: unknown): Promise<T> {
  const multipart = body instanceof FormData;
  const headers: Record<string, string> = { Accept: "application/json" };
  if (method !== "GET") {
    headers["X-CSRF-Token"] = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "";
    if (!multipart) headers["Content-Type"] = "application/json";
  }
  const response = await fetch(`/api/workspace/clients${path}`, {
    method, credentials: "same-origin", headers, signal,
    ...(body === undefined ? {} : { body: multipart ? body : JSON.stringify(body) }),
  });
  if (!response.ok) {
    const data = await response.json().catch(() => null);
    throw new ClientApiError(response.status, typeof data?.error === "string" ? data.error : "We couldn't complete this request. Please try again.", data?.errors ?? {});
  }
  return response.json();
}

export function fetchClients(period: string | null, signal: AbortSignal) {
  return request<ClientsDirectory>(period ? `?period=${encodeURIComponent(period)}` : "", signal);
}
export function fetchClient(id: string, signal: AbortSignal) {
  return request<ClientDetail>(`/${encodeURIComponent(id)}`, signal);
}
export function saveClient(id: number | undefined, client: { name: string; gstin: string }, signal: AbortSignal) {
  return request<ClientDetail>(id === undefined ? "" : `/${id}`, signal, id === undefined ? "POST" : "PATCH", { client });
}
export function previewClients(file: File, signal: AbortSignal) {
  const body = new FormData();
  body.append("file", file);
  return request<ImportPreview>("/import/preview", signal, "POST", body);
}
export function importClients(token: string, signal: AbortSignal) {
  return request<ImportResult>("/import", signal, "POST", { token });
}
