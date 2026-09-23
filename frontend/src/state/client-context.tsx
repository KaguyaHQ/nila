import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { useLocation } from "react-router-dom";

type ClientContext = { clientId: number; period: string; section: "sales" | "purchases" };
const Context = createContext<ClientContext | null>(null);

// Navigation memory only; the directory still decides which clients are accessible.
export function ClientContextProvider({ children }: { children: ReactNode }) {
  const { pathname } = useLocation();
  const [selected, setSelected] = useState<ClientContext | null>(null);
  useEffect(() => {
    const match = pathname.match(/^\/gst\/(\d+)\/(\d{4}-\d{2})\/(sales|purchases)(?:\/|$)/);
    if (match)
      setSelected({
        clientId: Number(match[1]),
        period: match[2],
        section: match[3] as ClientContext["section"],
      });
  }, [pathname]);
  return <Context.Provider value={selected}>{children}</Context.Provider>;
}

export const useClientContext = () => useContext(Context);
