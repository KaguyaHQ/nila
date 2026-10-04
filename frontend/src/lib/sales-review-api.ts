import { ApiError } from "./sales-api";

import type { components } from "./generated/workspace";

export type ReviewValues = components["schemas"]["ReviewValues"];
export type SalesInvoiceReviewData = components["schemas"]["SalesInvoiceReviewData"];
export type ReviewChange = components["schemas"]["ReviewChange"];

export class ReviewApiError extends ApiError {
  constructor(
    status: number,
    message: string,
    public fields: Record<string, string[]> = {},
  ) {
    super(status, message);
  }
}

function reviewPath(client: string, period: string, invoice: string) {
  return `/api/workspace/sales/${encodeURIComponent(client)}/${encodeURIComponent(period)}/invoices/${encodeURIComponent(invoice)}`;
}
function reviewBasis(path: string, tallyMode: boolean) {
  return tallyMode ? `${path}?tally=entries` : path;
}
export function salesReviewKey(client: string, period: string, invoice: string, tallyMode = false) {
  return tallyMode ? ["sales-review", client, period, invoice, "documents"] : ["sales-review", client, period, invoice];
}
async function request(
  path: string,
  signal: AbortSignal,
  method = "GET",
  body?: unknown,
): Promise<SalesInvoiceReviewData> {
  const headers: Record<string, string> = { Accept: "application/json" };
  if (method !== "GET") {
    headers["Content-Type"] = "application/json";
    headers["X-CSRF-Token"] =
      document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "";
  }
  const response = await fetch(path, {
    method,
    headers,
    credentials: "same-origin",
    signal,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  if (!response.ok) {
    const data = await response.json().catch(() => null);
    throw new ReviewApiError(
      response.status,
      typeof data?.error === "string"
        ? data.error
        : "We couldn't load or save this invoice. Please try again.",
      data?.errors ?? {},
    );
  }
  return response.json();
}
export function fetchSalesInvoice(
  client: string,
  period: string,
  invoice: string,
  signal: AbortSignal,
  tallyMode = false,
) {
  return request(reviewBasis(reviewPath(client, period, invoice), tallyMode), signal);
}
export function updateSalesInvoice(
  client: string,
  period: string,
  invoice: string,
  changes: ReviewChange,
  signal: AbortSignal,
  tallyMode = false,
) {
  return request(reviewBasis(reviewPath(client, period, invoice), tallyMode), signal, "PATCH", changes);
}
export function confirmSalesInvoiceIssue(
  client: string,
  period: string,
  invoice: string,
  target: string,
  signal: AbortSignal,
  tallyMode = false,
) {
  return request(reviewBasis(`${reviewPath(client, period, invoice)}/confirm`, tallyMode), signal, "POST", {
    target,
  } satisfies components["schemas"]["ConfirmInvoiceIssue"]);
}
