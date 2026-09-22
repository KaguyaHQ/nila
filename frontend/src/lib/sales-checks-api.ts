import { ApiError } from "./sales-api";

export type MonthlySalesCheck = {
  target: string;
  code: string;
  title: string;
  message: string;
  status: "open" | "resolved";
  basis: string | null;
  confirm_label: string;
  confirmation_text: string;
  sources: { id: number; name: string; url: string }[];
  action_paths: { label: string; path: string }[];
};

export type MonthlySalesChecks = {
  client: { id: number; name: string; gstin: string | null };
  period: string;
  can_edit: boolean;
  lock_reason: string | null;
  checks: MonthlySalesCheck[];
};

function checksPath(client: string, period: string) {
  return `/api/workspace/sales/${encodeURIComponent(client)}/${encodeURIComponent(period)}/checks`;
}
async function request(url: string, signal: AbortSignal, decision?: { target: string; basis: string; action: "confirm" | "reopen" }): Promise<MonthlySalesChecks> {
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
export function decideSalesCheck(client: string, period: string, decision: { target: string; basis: string; action: "confirm" | "reopen" }, signal: AbortSignal) {
  return request(`${checksPath(client, period)}/decision`, signal, decision);
}
