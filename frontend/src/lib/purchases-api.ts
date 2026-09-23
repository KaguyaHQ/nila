import type { components } from "./generated/workspace";
import { ApiError } from "@/lib/sales-api";

export type PurchasesWorkspace = components["schemas"]["PurchasesWorkspace"];

export async function fetchPurchases(client: string, period: string, filter: string, q: string, signal: AbortSignal): Promise<PurchasesWorkspace> {
  const params = new URLSearchParams({ filter, q });
  const response = await fetch(`/api/workspace/purchases/${encodeURIComponent(client)}/${encodeURIComponent(period)}?${params}`, {
    credentials: "same-origin", headers: { Accept: "application/json" }, signal,
  });
  if (!response.ok) {
    const body = await response.json().catch(() => null);
    throw new ApiError(response.status, body?.error ?? "We couldn't load purchases. Please try again.");
  }
  return response.json();
}
