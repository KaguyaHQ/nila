import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import App from "./app";
import "./index.css";
import AuthPage from "./pages/auth";
import { LiveUploadDraftProvider } from "./pages/live-sales-uploads";
import { UploadPreviewProvider } from "./state/upload-preview";

const queryClient = new QueryClient();
const authData = document.getElementById("auth-page")?.textContent;

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    {authData ? (
      <AuthPage data={JSON.parse(authData)} />
    ) : (
      <QueryClientProvider client={queryClient}>
        <UploadPreviewProvider>
          <LiveUploadDraftProvider>
            <App />
          </LiveUploadDraftProvider>
        </UploadPreviewProvider>
      </QueryClientProvider>
    )}
  </StrictMode>,
);
