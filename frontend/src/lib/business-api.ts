import type { ApiBody, ApiResult } from "./api-contract";
import type { components } from "./generated/workspace";
export type BusinessCustomer = components["schemas"]["BusinessCustomer"];
export type BusinessService = components["schemas"]["BusinessService"];
export type BusinessLine = components["schemas"]["BusinessLine"];
export type InvoiceInput = components["schemas"]["InvoiceInput"];
export type BusinessInvoice = components["schemas"]["BusinessInvoice"];
export type BusinessProfile = components["schemas"]["BusinessProfile"];
export type BusinessBootstrap = components["schemas"]["BusinessBootstrap"];
export class BusinessApiError extends Error {
  constructor(
    public status: number,
    message: string,
    public fields: Record<string, unknown> = {},
  ) {
    super(message);
  }
}
const businessOperations = {
  getBusiness: ["GET", ""],
  getBusinessServices: ["GET", "/services"],
  updateBusinessProfile: ["PATCH", "/profile"],
  configureBusinessQuotationNumbering: ["PATCH", "/quotation-numbering"],
  removeBusinessBrandAsset: ["DELETE", "/profile/assets/{kind}"],
  createBusinessService: ["POST", "/services"],
  updateBusinessService: ["PATCH", "/services/{id}"],
  deleteBusinessService: ["DELETE", "/services/{id}"],
  createBusinessCustomer: ["POST", "/customers"],
  updateBusinessCustomer: ["PATCH", "/customers/{id}"],
  createBusinessInvoice: ["POST", "/invoices"],
  finalizeBusinessQuotation: ["POST", "/quotations/finalize"],
  getBusinessInvoice: ["GET", "/invoices/{id}"],
  updateBusinessInvoice: ["PATCH", "/invoices/{id}"],
  issueBusinessInvoice: ["POST", "/invoices/{id}/issue"],
  setQuotationStatus: ["POST", "/invoices/{id}/quotation-status"],
  convertQuotation: ["POST", "/invoices/{id}/convert"],
  reviseBusinessQuotation: ["POST", "/invoices/{id}/revise"],
  calculateBusinessInvoice: ["POST", "/invoices/calculate"],
} as const;
type BusinessOperation = keyof typeof businessOperations;
type BusinessOptions<K extends BusinessOperation> = K extends BusinessOperation
  ? { signal?: AbortSignal } & ((typeof businessOperations)[K][1] extends
      | `${string}{id}`
      | `${string}{id}/${string}`
      ? { id: string | number }
      : (typeof businessOperations)[K][1] extends `${string}{kind}`
        ? { kind: "logo" | "signature" }
        : { id?: never; kind?: never }) &
      ([ApiBody<K>] extends [never] ? { body?: never } : { body: ApiBody<K> })
  : never;

export async function businessRequest<K extends BusinessOperation>(
  operation: K,
  options: BusinessOptions<K>,
): Promise<ApiResult<K>> {
  const [method, template] = businessOperations[operation];
  const id = "id" in options ? options.id : undefined;
  const path = template
    .replace("{id}", encodeURIComponent(id ?? ""))
    .replace("{kind}", "kind" in options ? encodeURIComponent(options.kind ?? "") : "");
  const response = await fetch(`/api/business${path}`, {
    method,
    credentials: "same-origin",
    signal: options.signal,
    headers: {
      Accept: "application/json",
      ...(method !== "GET"
        ? {
            "Content-Type": "application/json",
            "X-CSRF-Token":
              document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "",
          }
        : {}),
    },
    ...(options.body === undefined ? {} : { body: JSON.stringify(options.body) }),
  });
  if (!response.ok) {
    const data = await response.json().catch(() => null);
    throw new BusinessApiError(
      response.status,
      typeof data?.error === "string"
        ? data.error
        : "We couldn't complete this request. Please try again.",
      data?.errors ?? {},
    );
  }
  return response.json();
}

export async function uploadBusinessBrandAsset(kind: "logo" | "signature", file: File) {
  const body = new FormData();
  body.set("image", file);
  const response = await fetch(`/api/business/profile/assets/${kind}`, {
    method: "POST",
    credentials: "same-origin",
    headers: {
      Accept: "application/json",
      "X-CSRF-Token":
        document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "",
    },
    body,
  });
  const data = await response.json().catch(() => null);
  if (!response.ok)
    throw new BusinessApiError(response.status, data?.error ?? "Image upload failed.");
  return data as { profile: BusinessProfile };
}
export async function fetchInvoicePdf(
  invoice: InvoiceInput | number,
  signal?: AbortSignal,
): Promise<Blob> {
  const issued = typeof invoice === "number";
  const response = await fetch(
    issued ? `/api/business/invoices/${invoice}/pdf` : "/api/business/invoices/preview",
    {
      method: issued ? "GET" : "POST",
      credentials: "same-origin",
      signal,
      headers: {
        Accept: "application/pdf",
        ...(!issued
          ? {
              "Content-Type": "application/json",
              "X-CSRF-Token":
                document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "",
            }
          : {}),
      },
      ...(!issued
        ? { body: JSON.stringify({ invoice } satisfies ApiBody<"previewBusinessInvoice">) }
        : {}),
    },
  );
  if (!response.ok) {
    const data = await response.json().catch(() => null);
    throw new BusinessApiError(
      response.status,
      typeof data?.error === "string"
        ? data.error
        : "The PDF could not be prepared. Please try again.",
      data?.errors ?? {},
    );
  }
  const blob = await response.blob();
  if (!blob.type.includes("pdf"))
    throw new Error("The PDF could not be opened. Please sign in and try again.");
  return blob;
}

export async function downloadInvoice(id: number, filename = `invoice-${id}.pdf`) {
  const blob = await fetchInvoicePdf(id);
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
