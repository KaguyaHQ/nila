import { ArrowRight, FileSpreadsheet, MessageCircle, Upload, Search } from "lucide-react";
import { buttonVariants } from "../components/ui/button";
import { Input } from "../components/ui/input";
import { InvoiceStory } from "./invoice-story";
import { legalPages } from "./legal";

export const whatsapp =
  "https://wa.me/918148183716?text=" +
  encodeURIComponent("Hi, I’d like to try Nila free with one client’s sales bills.");
const action = buttonVariants({ size: "lg" });

export function PublicPage({ page }: { page: string }) {
  const legal = legalPages[page as keyof typeof legalPages];
  return (
    <div className={`public-site${page === "home" ? " public-home" : ""}`}>
      <a href="#main" className="public-skip">
        Skip to content
      </a>
      <header className="public-header public-wrap">
        <a href="/" aria-label="Nila home" className="public-logo">
          nila
        </a>
        <nav aria-label="Main navigation">
          <a href="/#how-it-works">How it works</a>
          <a href="/contact">Contact</a>
          <a href="/users/log_in">Log in</a>
          <a href="/contact" className={action}>
            Try one client free <ArrowRight />
          </a>
        </nav>
      </header>
      <div className="public-wrap">
        <p className="public-notice" role="status">
          __NILA_FLASH__
        </p>
      </div>
      {page === "home" ? (
        <Home />
      ) : page === "contact" ? (
        <Contact />
      ) : legal ? (
        <main id="main" className="public-legal public-wrap">
          <p className="public-eyebrow">Nila / {page === "terms" ? "Terms" : "Privacy"}</p>
          <h1>{legal.title}</h1>
          <p className="public-updated">Last updated {legal.updated}</p>
          <article>{legal.content}</article>
        </main>
      ) : null}
      <footer className="public-footer public-wrap">
        <div>
          <a href="/" className="public-logo" aria-label="Nila home">
            nila
          </a>
          <p>GST preparation. With the evidence attached.</p>
        </div>
        <nav aria-label="Footer">
          <a href="/contact">Contact</a>
          <a href="/privacy">Privacy</a>
          <a href="/terms">Terms</a>
          <a href="/data-deletion">Data deletion</a>
        </nav>
        <small>© 2026 Nila · Kaguya Media Private Limited</small>
      </footer>
    </div>
  );
}

function Home() {
  return (
    <main id="main">
      <InvoiceStory />
      <section id="how-it-works" className="public-process public-wrap">
        <div className="public-section-heading">
          <p className="public-eyebrow">The monthly workflow</p>
          <h2>
            From sales bills
            <br />
            <em>to GST workings.</em>
          </h2>
          <p>
            One place to work through a client’s sales, from the first PDF to the final working.
          </p>
        </div>
        <div className="public-steps">
          {[
            {
              number: "01",
              Icon: Upload,
              title: "Bring the sales bills",
              text: "Upload sales invoice PDFs. Nila reads the details and prepares the draft.",
            },
            {
              number: "02",
              Icon: Search,
              title: "Review what needs you",
              text: "Check flagged details beside the original bill. Your team confirms the corrections.",
            },
            {
              number: "03",
              Icon: FileSpreadsheet,
              title: "Take the working with you",
              text: "Keep the Excel working for review. Download GSTR-1 JSON once the required checks are clear.",
            },
          ].map(({ number, Icon, title, text }) => (
            <div key={number}>
              <div className="public-step-top">
                <Icon />
                <span>{number}</span>
              </div>
              <h3>{title}</h3>
              <p>{text}</p>
            </div>
          ))}
        </div>
      </section>
      <section className="public-cta public-wrap">
        <p className="public-eyebrow">Start small. Check the result.</p>
        <h2>
          Give Nila one client.
          <br />
          <em>Judge it by the working.</em>
        </h2>
        <p>
          We’ll help you try the workflow with your own sales bills.
          <br />
          Agree on a secure handoff before sharing client documents.
        </p>
        <a href="/contact" className={action}>
          Try one client free <ArrowRight />
        </a>
        <span className="public-small">
          No need to change your whole firm’s workflow to try it.
        </span>
      </section>
    </main>
  );
}

function Contact() {
  return (
    <main id="main" className="public-contact public-wrap">
      <section>
        <p className="public-eyebrow">Put Nila to the test</p>
        <h1>
          Try Nila on
          <br />
          <em>one client.</em>
        </h1>
        <p className="public-lead">
          Start with one client’s sales bills. Walk through the review and compare the Excel working
          with your own.
        </p>
        <p>We’ll agree on a secure handoff before you share any confidential client documents.</p>
        <div className="public-contact-links">
          <a href={whatsapp} className={buttonVariants({ variant: "outline", size: "lg" })}>
            <MessageCircle /> Continue on WhatsApp <ArrowRight />
          </a>
          <a href="mailto:hello@nila.tax">hello@nila.tax</a>
        </div>
      </section>
      <section className="public-contact-card">
        <h2>Prefer a call?</h2>
        <p>Leave your details and we’ll help you get started.</p>
        <form method="post" action="/contact/callback" id="callback-form">
          <input type="hidden" name="_csrf_token" value="__NILA_CSRF__" />
          <p className="public-form-errors" role="alert">
            __NILA_ERRORS__
          </p>
          {(
            [
              ["name", "Your name", "name", 100],
              ["firm", "Firm", "organization", 160],
              ["phone", "Phone", "tel", 30],
            ] as const
          ).map(([name, label, autoComplete, maxLength]) => (
            <div className="public-field" key={name}>
              <label htmlFor={`callback-${name}`}>{label}</label>
              <Input
                id={`callback-${name}`}
                name={`callback[${name}]`}
                defaultValue={`__NILA_${name.toUpperCase()}__`}
                type={name === "phone" ? "tel" : "text"}
                autoComplete={autoComplete}
                maxLength={maxLength}
                required
              />
            </div>
          ))}
          <div hidden aria-hidden="true">
            <label htmlFor="callback-website">Website</label>
            <input
              id="callback-website"
              name="callback[website]"
              autoComplete="off"
              tabIndex={-1}
            />
          </div>
          <button className={action} type="submit">
            Request a callback <ArrowRight size={16} />
          </button>
          <p className="public-small">
            We’ll use these details to respond to your request.
            <br />
            <a href="/privacy">Read our privacy policy.</a>
          </p>
        </form>
      </section>
    </main>
  );
}
