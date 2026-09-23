import type { components, paths } from "./generated/workspace";

export type SalesSectionRow = components["schemas"]["SalesSectionRow"];
export type SalesSectionDetail = components["schemas"]["SalesSectionDetail"];
export type SalesExportItem = components["schemas"]["SalesExportItem"];
export type SalesWorkspace = paths["/api/workspace/sales/{client_id}/{period}"]["get"]["responses"][200]["content"]["application/json"];

export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}

export async function fetchSales(
  client: string,
  period: string,
  signal: AbortSignal,
): Promise<SalesWorkspace> {
  const response = await fetch(
    `/api/workspace/sales/${encodeURIComponent(client)}/${encodeURIComponent(period)}`,
    {
      credentials: "same-origin",
      headers: { Accept: "application/json" },
      signal,
    },
  );
  if (!response.ok) {
    const body = await response.json().catch(() => null);
    throw new ApiError(
      response.status,
      body?.error ?? "We couldn't load this month. Please try again.",
    );
  }
  return response.json();
}
