export type SalesSectionRow = {
  id: string;
  cells: Record<string, string>;
  invoice_path: string | null;
  children?: SalesSectionRow[];
};

export type SalesSectionDetail = {
  title: string;
  description: string;
  note: string | null;
  groups: {
    id: string;
    label: string | null;
    columns: { key: string; label: string; align: "left" | "right" }[];
    rows: SalesSectionRow[];
  }[];
};

export type SalesExportItem = {
  id: "workings" | "json";
  label: string;
  format: "XLSX" | "JSON";
  url: string;
  enabled: boolean;
  reason: string | null;
};

export type SalesWorkspace = {
  client: { id: number; name: string };
  clients: { id: number; name: string }[];
  user: { name: string; org: string };
  period: string;
  month_label: string;
  can_upload: boolean;
  deadline: string;
  invoice_count: number;
  review_count: number;
  month_issue_count: number;
  taxable: string | null;
  tax: string | null;
  uploads: { files: number; unfinished: boolean };
  rows: {
    id: string;
    number: string;
    date: string | null;
    customer: string;
    gstin: string | null;
    status: "ready" | "needs_review" | "excluded";
    taxable: string | null;
    tax: string | null;
    reason: string | null;
    path: string | null;
  }[];
  sections: {
    id: string;
    label: string;
    count: string;
    value: string | null;
    status: string;
    variant: string;
    path: string | null;
  }[];
  details?: Record<string, SalesSectionDetail>;
  exports?: {
    items: SalesExportItem[];
    blockers: { id: string; message: string; path: string | null; external: boolean }[];
    status: string;
  };
  links: {
    upload: string;
    uploads: string;
    working: string;
    purchases: string;
  };
};

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
