// Keep existing Phoenix/shareable URLs as ordinary strings (including numeric
// searches and references with leading zeros), rather than JSON-coercing them.
export function parseSearch(value: string): Record<string, string> {
  return Object.fromEntries(new URLSearchParams(value));
}
export function stringifySearch(value: Record<string, unknown>) {
  const params = new URLSearchParams();
  for (const [key, entry] of Object.entries(value)) {
    if (entry !== undefined && entry !== null) params.set(key, String(entry));
  }
  return params.size ? `?${params}` : "";
}
function optional<T extends object>(value: T): Partial<T> {
  return value;
}
function text(value: unknown) {
  return typeof value === "string" ? value : undefined;
}
function choice<const T extends readonly string[]>(
  value: unknown,
  choices: T,
): T[number] | undefined {
  return typeof value === "string" && choices.includes(value) ? (value as T[number]) : undefined;
}
export function salesSearch(search: Record<string, unknown>) {
  return optional({
    q: text(search.q),
    filter: choice(search.filter, ["all", "needs_review", "ready", "excluded"] as const),
    upload: choice(search.upload, ["invoices"] as const),
  });
}
export function purchaseSearch(search: Record<string, unknown>) {
  return optional({
    q: text(search.q)?.slice(0, 200),
    source: choice(search.source, ["purchases", "gstr2b"] as const),
    work: choice(search.work, ["all", "undecided", "missing", "differences"] as const),
  });
}
export function reviewSearch(search: Record<string, unknown>) {
  return optional({
    q: text(search.q)?.slice(0, 200),
    filter: choice(search.filter, [
      "needs_review",
      "all",
      "treatment",
      "matched",
      "mismatch",
      "books_only",
      "2b_only",
      "possible",
      "itc",
      "carried",
      "register",
      "gstr2b",
    ] as const),
    return_to: text(search.return_to),
  });
}
export function clientsSearch(search: Record<string, unknown>) {
  const period = text(search.period);
  return optional({
    q: text(search.q),
    period: period && /^\d{4}-(0[1-9]|1[0-2])$/.test(period) ? period : undefined,
  });
}
export function noticesSearch(search: Record<string, unknown>) {
  const document = text(search.document);
  return optional({
    client_id: text(search.client_id),
    document: document && /^\d+$/.test(document) ? document : undefined,
  });
}
export function settingsSearch(search: Record<string, unknown>) {
  return optional({
    email: choice(search.email, ["confirmed", "invalid"] as const),
    updated: choice(search.updated, ["password"] as const),
  });
}
export function businessSearch(search: Record<string, unknown>) {
  return optional({ credit_for: text(search.credit_for) });
}
