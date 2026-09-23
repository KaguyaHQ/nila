import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { useLocation } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { components } from "@/lib/generated/workspace";

type ClientContext = components["schemas"]["WorkspaceNavigation"];
type Response = components["schemas"]["WorkspaceNavigationResponse"];
const Context = createContext<ClientContext | null>(null);
const queryKey = ["workspace-navigation"];
async function request(signal?: AbortSignal, workspace?: ClientContext): Promise<Response> {
  const response = await fetch("/api/workspace/navigation", {
    method: workspace ? "PUT" : "GET",
    credentials: "same-origin",
    signal,
    headers: {
      Accept: "application/json",
      ...(workspace
        ? {
            "Content-Type": "application/json",
            "X-CSRF-Token":
              document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "",
          }
        : {}),
    },
    ...(workspace ? { body: JSON.stringify(workspace) } : {}),
  });
  if (!response.ok) throw new Error("Could not remember this workspace.");
  return response.json();
}

export function ClientContextProvider({ children }: { children: ReactNode }) {
  const { pathname } = useLocation();
  const match = pathname.match(/^\/gst\/(\d+)\/(\d{4}-\d{2})\/(sales|purchases)(?:\/|$)/);
  const routeKey = match ? `${match[1]}/${match[2]}/${match[3]}` : null;
  const [selected, setSelected] = useState<ClientContext | null>(null);
  const latest = useRef<string | null>(null);
  const cache = useQueryClient();
  const restored = useQuery({
    queryKey,
    queryFn: ({ signal }) => request(signal),
    enabled: !routeKey,
    retry: false,
    staleTime: Infinity,
  });
  const mutation = useMutation({
    // Serial writes ensure an older response cannot overwrite a newer cookie.
    scope: { id: "workspace-navigation" },
    retry: false,
    networkMode: "always",
    mutationFn: async (workspace: ClientContext) => {
      await cache.cancelQueries({ queryKey });
      return request(undefined, workspace);
    },
    onSuccess: async (result, workspace) => {
      await cache.cancelQueries({ queryKey });
      const key = `${workspace.clientId}/${workspace.period}/${workspace.section}`;
      if (latest.current === key) {
        setSelected(result.workspace);
        cache.setQueryData(queryKey, result);
      }
    },
  });
  const { mutate } = mutation;
  useEffect(() => {
    if (!routeKey || latest.current === routeKey) return;
    latest.current = routeKey;
    const [id, period, section] = routeKey.split("/");
    mutate({ clientId: Number(id), period, section: section as ClientContext["section"] });
  }, [routeKey, mutate]);
  useEffect(() => {
    if (!routeKey && restored.data) setSelected(restored.data.workspace);
  }, [routeKey, restored.data]);
  return <Context.Provider value={selected}>{children}</Context.Provider>;
}

export function useClientContext() {
  const selected = useContext(Context);
  const { search } = useLocation();
  const period = new URLSearchParams(search).get("period");
  // An explicit directory period takes priority over remembered defaults.
  return selected && period && /^\d{4}-(0[1-9]|1[0-2])$/.test(period)
    ? { ...selected, period }
    : selected;
}
