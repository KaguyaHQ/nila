import { parseSearch } from "@/lib/route-search";

// Phoenix returns some destinations as URLs, and workspace navigation preserves
// the current subpage. Split those runtime URLs at this boundary; authored links
// should use TanStack's typed `to`, `params` and `search` directly.
export function urlDestination(url: string) {
  const parsed = new URL(url, window.location.origin);
  return { to: parsed.pathname, search: parseSearch(parsed.search), hash: parsed.hash.slice(1) };
}
