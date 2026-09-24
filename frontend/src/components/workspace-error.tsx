import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Link } from "@tanstack/react-router";
import { CircleAlert } from "lucide-react";

export function WorkspaceError({
  title,
  message,
  needsSignIn = false,
  retry,
  backToClients = false,
}: {
  title: string;
  message: string;
  needsSignIn?: boolean;
  retry: () => void;
  backToClients?: boolean;
}) {
  return (
    <main className="mx-auto max-w-xl space-y-6 px-6 py-24">
      <h1 className="text-2xl font-semibold">{title}</h1>
      <Alert variant="destructive">
        <CircleAlert aria-hidden="true" />
        <AlertDescription>{message}</AlertDescription>
      </Alert>
      <div className="flex items-center gap-3">
        {needsSignIn ? (
          <Button nativeButton={false} role="link" render={<a href="/users/log_in" />}>
            Sign in
          </Button>
        ) : (
          <Button onClick={retry}>Try again</Button>
        )}
        {backToClients && (
          <Button
            variant="outline"
            nativeButton={false}
            role="link"
            render={<Link to="/clients" />}
          >
            Back to clients
          </Button>
        )}
      </div>
    </main>
  );
}
