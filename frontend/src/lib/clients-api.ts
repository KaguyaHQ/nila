import type { components } from "./generated/workspace";
import { ApiError } from "./sales-api";

export type ClientIdentity = components["schemas"]["ClientIdentity"];
export type ClientsDirectory = components["schemas"]["ClientsDirectory"];
export type ClientDetail = components["schemas"]["ClientDetail"];
export type GstConnection = components["schemas"]["GstConnection"];
export function fetchGstConnection(id: number, signal: AbortSignal) {
  return request<GstConnection>(`/${id}/gst-connection`, signal);
}
export function requestGstOtp(id: number, username: string, signal: AbortSignal) {
  return request<components["schemas"]["Gstr2bChallenge"]>(
    `/${id}/gst-connection/otp`,
    signal,
    "POST",
    { username },
  );
}
export function verifyGstConnection(
  id: number,
  challenge: string,
  otp: string,
  signal: AbortSignal,
) {
  return request<GstConnection>(`/${id}/gst-connection/verify`, signal, "POST", { challenge, otp });
}
export type ImportRow = components["schemas"]["ImportRow"];
export type ImportPreview = components["schemas"]["ImportPreview"];
export type ImportResult = components["schemas"]["ImportResult"];

export class ClientApiError extends ApiError {
  constructor(
    status: number,
    message: string,
    public fields: Record<string, string[]> = {},
    public code?: string,
  ) {
    super(status, message);
  }
}

async function request<T>(
  path: string,
  signal: AbortSignal,
  method = "GET",
  body?: unknown,
): Promise<T> {
  const multipart = body instanceof FormData;
  const headers: Record<string, string> = { Accept: "application/json" };
  if (method !== "GET") {
    headers["X-CSRF-Token"] =
      document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "";
    if (!multipart) headers["Content-Type"] = "application/json";
  }
  const response = await fetch(`/api/workspace/clients${path}`, {
    method,
    credentials: "same-origin",
    headers,
    signal,
    ...(body === undefined ? {} : { body: multipart ? body : JSON.stringify(body) }),
  });
  if (!response.ok) {
    const data = await response.json().catch(() => null);
    throw new ClientApiError(
      response.status,
      typeof data?.error === "string"
        ? data.error
        : "We couldn't complete this request. Please try again.",
      data?.errors ?? {},
      data?.code,
    );
  }
  return response.json();
}

export function fetchClients(period: string | null, signal: AbortSignal) {
  return request<ClientsDirectory>(period ? `?period=${encodeURIComponent(period)}` : "", signal);
}
export function fetchClient(id: string, signal: AbortSignal) {
  return request<ClientDetail>(`/${encodeURIComponent(id)}`, signal);
}
export function saveClient(
  id: number | undefined,
  client: components["schemas"]["ClientInput"],
  signal: AbortSignal,
) {
  return request<ClientDetail>(
    id === undefined ? "" : `/${id}`,
    signal,
    id === undefined ? "POST" : "PATCH",
    { client } satisfies components["schemas"]["ClientWrite"],
  );
}
export function previewClients(file: File, signal: AbortSignal) {
  const body = new FormData();
  body.append("file", file);
  return request<ImportPreview>("/import/preview", signal, "POST", body);
}
export function importClients(token: string, signal: AbortSignal) {
  return request<ImportResult>("/import", signal, "POST", {
    token,
  } satisfies components["schemas"]["ImportClients"]);
}
