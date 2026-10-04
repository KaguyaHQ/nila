import { ApiError } from "./sales-api";

import type { components } from "./generated/workspace";

export type TallySalesProposal = components["schemas"]["SalesTallyProposal"];
export type TallySalesData = components["schemas"]["SalesTallyWorkspace"];
export type EnabledTallySalesData = Extract<TallySalesData, { enabled: true }>;
export type TallyMappingChanges = Omit<components["schemas"]["SalesTallyUpdate"], "preview_token">;

function base(client: string, period: string) {
  return `/api/workspace/sales/${encodeURIComponent(client)}/${encodeURIComponent(period)}`;
}
async function request<T>(
  path: string,
  signal: AbortSignal,
  method = "GET",
  body?: unknown,
): Promise<T> {
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
    throw new ApiError(
      response.status,
      typeof data?.error === "string"
        ? data.error
        : "We couldn't load or save these Tally entries. Please try again.",
    );
  }
  return response.json();
}
export const tallyQueryKey = (client: string, period: string) => ["sales-tally", client, period];
export function fetchSalesTally(client: string, period: string, signal: AbortSignal) {
  return request<TallySalesData>(`${base(client, period)}/tally`, signal);
}
export function updateSalesTally(
  client: string,
  period: string,
  invoice: string,
  changes: TallyMappingChanges,
  signal: AbortSignal,
  previewToken: string,
) {
  return request<TallySalesData>(
    `${base(client, period)}/invoices/${encodeURIComponent(invoice)}/tally`,
    signal,
    "PATCH",
    { ...changes, preview_token: previewToken },
  );
}
export function postSalesTally(
  client: string,
  period: string,
  body: { company_id: number; invoice_ids: string[]; preview_token: string },
  signal: AbortSignal,
) {
  return request<components["schemas"]["SalesTallyPostResult"]>(
    `${base(client, period)}/tally`,
    signal,
    "POST",
    body,
  );
}
export function verifySalesTally(client: string, period: string, signal: AbortSignal) {
  return request<components["schemas"]["SalesTallyPostResult"]>(
    `${base(client, period)}/tally/verify`,
    signal,
    "POST",
  );
}
export function refreshSalesTally(client: string, period: string, signal: AbortSignal) {
  return request<TallySalesData>(`${base(client, period)}/tally/sync`, signal, "POST");
}
export function tallyMoney(value: string | undefined) {
  if (value === undefined) return "—";
  const amount = Number(value);
  return Number.isFinite(amount)
    ? new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR" }).format(amount)
    : value;
}
export function tallyStatus(status: TallySalesProposal["status"]) {
  return {
    ready: "Ready to post",
    needs_input: "Needs input",
    pending: "Posting",
    posted: "Posted",
    failed: "Post failed",
    unknown: "Check posting result",
  }[status];
}
