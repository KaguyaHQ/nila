import type { ApiBody, ApiResult } from "./api-contract";
import { ApiError } from "./sales-api";

export class NoticesError extends ApiError {
  constructor(
    status: number,
    message: string,
    public code?: string,
  ) {
    super(status, message);
  }
}
const operations = {
  getNotices: ["GET", ""],
  getNotice: ["GET", "/:id"],
  checkAllNotices: ["POST", "/check"],
  retryNotices: ["POST", "/retry"],
  checkClientNotices: ["POST", "/clients/:id/check"],
  requestNoticeOtp: ["POST", "/clients/:id/otp"],
  verifyNoticeOtp: ["POST", "/clients/:id/verify"],
} as const;
type Operation = keyof typeof operations;
type Options<K extends Operation> = { signal?: AbortSignal } & (K extends
  | "getNotice"
  | "checkClientNotices"
  | "requestNoticeOtp"
  | "verifyNoticeOtp"
  ? { id: number }
  : { id?: never }) &
  ([ApiBody<K>] extends [never] ? { body?: never } : { body: ApiBody<K> });
export async function noticesRequest<K extends Operation>(
  operation: K,
  options: Options<K>,
): Promise<ApiResult<K>> {
  const [method, path] = operations[operation];
  const response = await fetch(`/api/workspace/notices${path.replace(":id", String(options.id))}`, {
    method,
    credentials: "same-origin",
    signal: options.signal,
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "X-CSRF-Token":
        document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "",
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const body = await response.json().catch(() => null);
  if (!response.ok)
    throw new NoticesError(
      response.status,
      body?.error ?? "Notices could not be loaded. Please try again.",
      body?.code,
    );
  return body;
}
export type NoticesData = ApiResult<"getNotices">;
export type Notice = ApiResult<"getNotice">["notice"];
export type NoticeClient = NoticesData["clients"][number];
