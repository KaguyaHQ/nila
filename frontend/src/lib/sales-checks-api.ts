import { ApiError } from "./sales-api";

import type { components } from "./generated/sales-workspace";

export type MonthlySalesCheck = components["schemas"]["MonthlySalesCheck"];
export type MonthlySalesChecks = components["schemas"]["MonthlySalesChecks"];
export type MonthlySalesDecision = components["schemas"]["MonthlySalesDecision"];

function checksPath(client: string, period: string) {
  return `/api/workspace/sales/${encodeURIComponent(client)}/${encodeURIComponent(period)}/checks`;
}
async function request(url: string, signal: AbortSignal, decision?: MonthlySalesDecision): Promise<MonthlySalesChecks> {
  const headers: Record<string, string> = { Accept: "application/json" };
  if (decision) {
    headers["Content-Type"] = "application/json";
    headers["X-CSRF-Token"] = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "";
  }
  const response = await fetch(url, {
    method: decision ? "POST" : "GET", credentials: "same-origin", signal, headers,
    ...(decision ? { body: JSON.stringify(decision) } : {}),
  });
  if (!response.ok) {
    const problem = await response.json().catch(() => null);
    throw new ApiError(response.status, typeof problem?.error === "string" ? problem.error : "This check could not be loaded or saved. Please try again.");
  }
  return response.json();
}
export function fetchSalesChecks(client: string, period: string, signal: AbortSignal) {
  return request(checksPath(client, period), signal);
}
export function decideSalesCheck(client: string, period: string, decision: MonthlySalesDecision, signal: AbortSignal) {
  return request(`${checksPath(client, period)}/decision`, signal, decision);
}
