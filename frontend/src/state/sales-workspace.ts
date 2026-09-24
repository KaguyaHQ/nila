import { createContext, useContext } from "react";
import type { SalesWorkspace } from "@/lib/sales-api";

export const SalesWorkspaceContext = createContext<SalesWorkspace | null>(null);

export function useSales() {
  const data = useContext(SalesWorkspaceContext);
  if (!data) throw new Error("Sales workspace is missing");
  return data;
}
