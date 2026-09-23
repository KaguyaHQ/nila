import { ArrowRight, FileQuestion, Mail, Unplug } from "lucide-react";
import { buttonVariants } from "../components/ui/button";

export function ErrorPage({ status }: { status: 404 | 500 }) {
  const missing = status === 404;
  const Icon = missing ? FileQuestion : Unplug;
  return (
    <div className="public-site error-page">
      <header className="error-header">
        <a href="/" className="public-logo" aria-label="Nila home">
          nila
        </a>
        <span>
          {status} / {missing ? "PAGE NOT FOUND" : "SERVER ERROR"}
        </span>
      </header>
      <main className="error-main">
        <div className="error-symbol" aria-hidden="true">
          <Icon size={26} strokeWidth={1.5} />
        </div>
        <p className="public-eyebrow">{missing ? "A wrong turn." : "A pause on our side."}</p>
        <h1>{missing ? "This page isn’t here." : "We couldn’t load this page."}</h1>
        <p className="error-description">
          {missing
            ? "The link may be incorrect, or the page may have moved. You can return to Nila and pick up from there."
            : "Something went wrong on our server. Please try again in a moment. If you were saving changes, check whether they saved before repeating the action."}
        </p>
        <div className="error-actions">
          <a href="/app" className={buttonVariants({ size: "lg" })}>
            Go to Nila <ArrowRight />
          </a>
          {!missing && (
            <a
              href="mailto:hello@nila.tax"
              className={buttonVariants({ variant: "outline", size: "lg" })}
            >
              <Mail /> Contact support
            </a>
          )}
        </div>
      </main>
      <footer className="error-footer">
        <span>Nila · GST preparation</span>
        <a href="/">
          Back to homepage <ArrowRight size={14} />
        </a>
      </footer>
    </div>
  );
}
