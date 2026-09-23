import type { ApiBody, ApiResult } from "./api-contract";
import { ApiError } from "./sales-api";

export class SettingsError extends ApiError {
  constructor(
    status: number,
    message: string,
    public fields: Record<string, string[]> = {},
  ) {
    super(status, message);
  }
}

const operations = {
  getSettings: ["GET", ""],
  updateSettingsName: ["PATCH", "/name"],
  updateSettingsEmail: ["POST", "/email"],
  updateSettingsPassword: ["POST", "/password"],
  deleteSettingsSessions: ["POST", "/sessions"],
  updateSettingsFirm: ["PATCH", "/firm"],
  inviteSettingsUser: ["POST", "/invitations"],
  updateSettingsMember: ["PATCH", "/members/"],
} as const;
type Operation = keyof typeof operations;
type Options<K extends Operation> = { signal?: AbortSignal } & (K extends "updateSettingsMember"
  ? { id: number }
  : { id?: never }) &
  ([ApiBody<K>] extends [never] ? { body?: never } : { body: ApiBody<K> });

export async function settingsRequest<K extends Operation>(
  operation: K,
  options: Options<K>,
): Promise<ApiResult<K>> {
  const [method, path] = operations[operation];
  const response = await fetch(`/api/workspace/settings${path}${options.id ?? ""}`, {
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
    throw new SettingsError(
      response.status,
      body?.error ?? "Could not save settings. Please try again.",
      body?.fields,
    );
  return body;
}

export type SettingsData = ApiResult<"getSettings">;
export type SettingsResult = ApiResult<"updateSettingsName">;
