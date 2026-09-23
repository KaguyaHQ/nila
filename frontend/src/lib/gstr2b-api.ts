import type { components } from "./generated/workspace";
import { ApiError } from "@/lib/sales-api";

export type Gstr2bState = components["schemas"]["Gstr2bState"];
export type Gstr2bChallenge = components["schemas"]["Gstr2bChallenge"];
export class Gstr2bError extends ApiError {
  constructor(
    status: number,
    message: string,
    public code?: string,
  ) {
    super(status, message);
  }
}
export type Gstr2bWrite =
  | { action: "fetch" | "import"; body: components["schemas"]["EmptyRequest"] }
  | { action: "otp"; body: components["schemas"]["Gstr2bOtp"] }
  | { action: "verify"; body: components["schemas"]["Gstr2bVerify"] };

export function gstr2bRequest(
  client: number,
  period: string,
  signal: AbortSignal,
): Promise<Gstr2bState>;
export function gstr2bRequest(
  client: number,
  period: string,
  signal: AbortSignal,
  write: Gstr2bWrite,
): Promise<Gstr2bState | Gstr2bChallenge>;
export async function gstr2bRequest(
  client: number,
  period: string,
  signal: AbortSignal,
  write?: Gstr2bWrite,
): Promise<Gstr2bState | Gstr2bChallenge> {
  const action = write?.action;
  const body = write?.body;
  const headers: Record<string, string> = { Accept: "application/json" };
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    headers["X-CSRF-Token"] =
      document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "";
  }
  const response = await fetch(
    `/api/workspace/purchases/${client}/${encodeURIComponent(period)}/gstr2b${action ? `/${action}` : ""}`,
    {
      credentials: "same-origin",
      signal,
      headers,
      method: body === undefined ? "GET" : "POST",
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    },
  );
  const result = await response.json().catch(() => null);
  if (!response.ok)
    throw new Gstr2bError(
      response.status,
      result?.error ?? "GSTR-2B is unavailable. Please try again.",
      result?.code,
    );
  if (!result || typeof result !== "object")
    throw new Gstr2bError(502, "GSTR-2B returned an unexpected response. Please try again.");
  return result;
}
