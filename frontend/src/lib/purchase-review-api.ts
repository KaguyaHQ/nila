import { ApiError } from "@/lib/sales-api";

export type TreatmentChoice = "claim" | "later" | "exclude" | "split";
export type TaxHead = "cgst" | "sgst" | "igst" | "cess";
export type TreatmentValues = {
  choice: string | null;
  later_reason: string;
  exclude_reason: string;
  note: string;
  split: Record<"claim" | "later" | "exclude", Record<TaxHead, string>>;
};
export type PurchaseReviewData = {
  client: { id: number; name: string; gstin: string | null };
  period: string;
  month_label: string;
  can_edit: boolean;
  lock_reason: string | null;
  filter: string;
  q: string;
  queue: { id: string; number: string; vendor: string; status: string; needs_review: boolean; case_ids: number[] }[];
  item: null | {
    id: string; number: string; vendor: string; document_type: string; status: string; reason: string | null; pairing_pending: boolean; case_ids: number[];
    comparisons: { id: string; facts: { label: string; books: string; portal: string; different: boolean }[]; original_url: string | null }[];
    images: string[];
    legacy_url: string;
  };
  cases: {
    id: number; basis: string; number: string; vendor: string; available: boolean; unavailable_reason: string | null;
    claimable: boolean; can_claim_split: boolean; claim_block_reason: string | null; cess_issue: string | null;
    can_record_document: boolean; document_state: string;
    heads: { id: TaxHead; label: string; amount: string; value: string }[];
    values: TreatmentValues;
  }[];
  reasons: { later: { id: string; label: string }[]; exclude: { id: string; label: string }[] };
  legacy_url: string;
};

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
export function savePurchaseTreatment(client: string, period: string, item: string, filter: string, q: string, body: { case_ids: number[]; basis: Record<string, string>; values: TreatmentValues }, signal: AbortSignal) {
  return request(`${base(client, period)}/${encodeURIComponent(item)}/treatment?${new URLSearchParams({ filter, q })}`, signal, body);
}
export function recordPurchaseDocument(client: string, period: string, item: string, filter: string, q: string, body: { case_ids: number[]; basis: Record<string, string> }, signal: AbortSignal) {
  return request(`${base(client, period)}/${encodeURIComponent(item)}/document?${new URLSearchParams({ filter, q })}`, signal, body);
}
