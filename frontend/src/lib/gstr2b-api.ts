import { ApiError } from "@/lib/sales-api";

export type Gstr2bState = {
  client: { id: number; name: string; gstin: string | null };
  period: string;
  connection: { state: "connected" | "expired" | "not_connected" | "missing_gstin"; username: string | null };
  permissions: { fetch: boolean; connect: boolean; export: boolean };
  statement: null | { id: number; status: string; fetched_at: string | null; last_error: string | null; failure_reason: string | null; download_url: string | null };
  fetching: boolean;
  import: { needed: boolean; status: string | null; error: string | null };
  availability_hint: string | null;
};
export type Gstr2bChallenge = { challenge: string; username: string; expires_in: number };
export class Gstr2bError extends ApiError {
  constructor(status: number, message: string, public code?: string) { super(status, message); }
}
export async function gstr2bRequest<T = Gstr2bState>(client: number, period: string, signal: AbortSignal, action = "", body?: unknown): Promise<T> {
  const headers: Record<string, string> = { Accept: "application/json" };
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    headers["X-CSRF-Token"] = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "";
  }
  const response = await fetch(`/api/workspace/purchases/${client}/${encodeURIComponent(period)}/gstr2b${action ? `/${action}` : ""}`, {
    credentials: "same-origin", signal, headers, method: body === undefined ? "GET" : "POST", ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const result = await response.json().catch(() => null);
  if (!response.ok) throw new Gstr2bError(response.status, result?.error ?? "GSTR-2B is unavailable. Please try again.", result?.code);
  if (!result || typeof result !== "object") throw new Gstr2bError(502, "GSTR-2B returned an unexpected response. Please try again.");
  return result;
}
