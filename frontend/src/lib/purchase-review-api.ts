import type { components } from "./generated/workspace";
import { ApiError } from "@/lib/sales-api";

export type TreatmentChoice = components["schemas"]["TreatmentChoice"];
export type TaxHead = components["schemas"]["TaxHead"];
export type TreatmentValues = components["schemas"]["TreatmentValues"];
export type PurchaseReviewData = components["schemas"]["PurchaseReviewData"];

export class PurchaseReviewError extends ApiError {
  constructor(status: number, message: string, public code?: string) { super(status, message); }
}
function base(client: string, period: string) {
  return `/api/workspace/purchases/${encodeURIComponent(client)}/${encodeURIComponent(period)}/review`;
}
async function request(path: string, signal: AbortSignal, body?: unknown): Promise<PurchaseReviewData> {
  const headers: Record<string, string> = { Accept: "application/json" };
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    headers["X-CSRF-Token"] = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "";
  }
  const response = await fetch(path, { method: body === undefined ? "GET" : "POST", credentials: "same-origin", signal, headers, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  if (!response.ok) {
    const problem = await response.json().catch(() => null);
    throw new PurchaseReviewError(response.status, problem?.error ?? "Purchase review could not be loaded or saved. Please try again.", problem?.code);
  }
  return response.json();
}
export function fetchPurchaseReview(client: string, period: string, item: string, filter: string, q: string, signal: AbortSignal) {
  return request(`${base(client, period)}${item ? `/${encodeURIComponent(item)}` : ""}?${new URLSearchParams({ filter, q })}`, signal);
}
export function savePurchaseTreatment(client: string, period: string, item: string, filter: string, q: string, body: components["schemas"]["PurchaseTreatment"], signal: AbortSignal) {
  return request(`${base(client, period)}/${encodeURIComponent(item)}/treatment?${new URLSearchParams({ filter, q })}`, signal, body);
}
export function recordPurchaseDocument(client: string, period: string, item: string, filter: string, q: string, body: components["schemas"]["PurchaseSelection"], signal: AbortSignal) {
  return request(`${base(client, period)}/${encodeURIComponent(item)}/document?${new URLSearchParams({ filter, q })}`, signal, body);
}
