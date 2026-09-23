import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import App from "./app";
import { UploadPreviewProvider } from "./state/upload-preview";
import { LiveUploadDraftProvider } from "./pages/live-sales-uploads";
import "./index.css";

const queryClient = new QueryClient();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter basename={location.pathname.startsWith("/app/") ? "/app" : undefined}>
        <UploadPreviewProvider>
          <LiveUploadDraftProvider>
            <App />
          </LiveUploadDraftProvider>
        </UploadPreviewProvider>
      </BrowserRouter>
    </QueryClientProvider>
  </StrictMode>,
);
