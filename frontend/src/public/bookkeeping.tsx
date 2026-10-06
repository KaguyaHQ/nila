import { ArrowRight, Check, FileCheck2, Files, Search } from "lucide-react";
import { buttonVariants } from "../components/ui/button";

const action = buttonVariants({ size: "lg" });
export const benchmarkEmail =
  "mailto:vasanth@nilahq.com?subject=" +
  encodeURIComponent("Free QBO bookkeeping test") +
  "&body=" +
  encodeURIComponent("Hi Vasanth,\n\nOur firm:\nBookkeeping work we’d like help with:\n");

export function BookkeepingHome() {
  return (
    <main id="main">
      <section className="benchmark-hero public-wrap">
        <div className="benchmark-hero-copy">
          <p className="public-eyebrow">
            <span /> For accounting firms
          </p>
          <h1>
            Test our bookkeeping.
            <br />
            <em>On a closed month.</em>
          </h1>
          <p className="benchmark-lead">
            Choose one completed QBO client month. We’ll prepare the agreed routine bookkeeping for
            free, without seeing your finished work. Compare the results.
          </p>
          <p className="benchmark-offer-scope">
            Transaction categorization, bank and credit-card reconciliation, and questions for your
            team.
          </p>
          <a href="/contact" className={action}>
            Discuss a free test <ArrowRight size={16} />
          </a>
          <p className="public-small">No ongoing commitment.</p>
        </div>

        <figure className="benchmark-desk" aria-label="Example bookkeeping workpapers">
          <div className="benchmark-papers">
            <article className="benchmark-paper benchmark-source">
              <div className="benchmark-paper-heading">
                <span>FROM THE BANK STATEMENT</span>
                <Files size={17} />
              </div>
              <h2>Bank statement</h2>
              <p>June · Example</p>
              <div className="benchmark-statement-heading">
                <span>Transaction</span>
                <span>Amount</span>
              </div>
              <div className="benchmark-statement-row">
                <span>Client payment</span>
                <strong>+$3,000.00</strong>
              </div>
              <div className="benchmark-statement-row benchmark-marked-row">
                <span>ACH · reference 482</span>
                <strong>−$240.00</strong>
              </div>
              <div className="benchmark-statement-row">
                <span>Office rent</span>
                <strong>−$1,920.00</strong>
              </div>
              <div className="benchmark-statement-total">
                <span>Closing balance</span>
                <strong>$12,840.00</strong>
              </div>
              <p className="benchmark-paper-note">Starting balance: $12,000.00</p>
            </article>

            <article className="benchmark-paper benchmark-result">
              <span className="benchmark-month-tab">June / for review</span>
              <div className="benchmark-paper-heading">
                <span>PREPARED FOR REVIEW</span>
                <FileCheck2 size={17} />
              </div>
              <h2>Bank reconciliation</h2>
              <p>June · Example</p>
              <dl className="benchmark-reconciliation">
                <div>
                  <dt>Statement closing balance</dt>
                  <dd>$12,840.00</dd>
                </div>
                <div>
                  <dt>Prepared book balance</dt>
                  <dd>$12,840.00</dd>
                </div>
                <div className="benchmark-difference">
                  <dt>Difference</dt>
                  <dd>$0.00</dd>
                </div>
              </dl>
              <div className="benchmark-result-note">
                <Check size={15} />
                <span>
                  Balances agree.
                  <br />
                  Payment category still open.
                </span>
              </div>
            </article>

            <article className="benchmark-question">
              <span className="benchmark-note-label">UNCLEAR PAYMENT</span>
              <h2>What was this payment for?</h2>
              <p className="benchmark-question-amount">
                $240.00 <span>ACH · reference 482</span>
              </p>
              <p className="benchmark-paper-note">Category awaiting confirmation.</p>
            </article>
            <svg className="benchmark-pencil" viewBox="0 0 140 120" fill="none" aria-hidden="true">
              <path d="M12 9C98 3 120 55 70 99M70 99l4-20M70 99l23-3" />
            </svg>
          </div>
        </figure>
      </section>

      <section id="how-it-works" className="public-process public-wrap">
        <div className="public-section-heading">
          <h2>How the test works.</h2>
        </div>
        <div className="public-steps">
          {[
            {
              number: "01",
              Icon: Files,
              title: "Agree the test",
              text: "Pick a completed QBO client month. We agree the work, inputs and handoff.",
            },
            {
              number: "02",
              Icon: Search,
              title: "We prepare independently",
              text: "We use the original inputs without seeing your completed bookkeeping. You receive the work, reconciliation support and an exceptions list.",
            },
            {
              number: "03",
              Icon: FileCheck2,
              title: "Compare the work",
              text: "Check accuracy, open questions and review time against your completed month. Would our preparation save your team work?",
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
        <details className="benchmark-scope">
          <summary>What’s included—and what isn’t</summary>
          <div className="benchmark-scope-content">
            <div>
              <h3>The preparation</h3>
              <p>
                Bank and credit-card categorization and reconciliation. We agree any bill or receipt
                entry separately.
              </p>
            </div>
            <div>
              <h3>Outside this test</h3>
              <p>
                The test excludes full month-end close, tax filings, payroll, inventory and complex
                accounting judgments. Nothing is posted to live books without your approval.
              </p>
            </div>
          </div>
        </details>
      </section>

      <section className="public-cta public-wrap">
        <h2>Have a month in mind?</h2>
        <p>
          We do the preparation for free. Your team provides the inputs and reviews the work.
          <br />
          No software to implement. No obligation to continue.
        </p>
        <a href="/contact" className={action}>
          Discuss a free test <ArrowRight size={16} />
        </a>
        <span className="public-small">
          Scope, handoff and data handling agreed before sharing client files.
        </span>
      </section>
    </main>
  );
}

export function BenchmarkContact() {
  return (
    <main id="main" className="public-contact public-wrap benchmark-contact">
      <section>
        <p className="public-eyebrow">Talk to Vasanth</p>
        <h1>
          Tell me about
          <br />
          <em>the work.</em>
        </h1>
        <p className="public-lead">
          I’m Vasanth, Nila’s founder. Tell me where your team needs bookkeeping help. We’ll discuss
          a free test on one completed QBO client month.
        </p>
        <div className="public-contact-links">
          <a href={benchmarkEmail} className={action}>
            Email Vasanth <ArrowRight size={16} />
          </a>
          <a href="mailto:vasanth@nilahq.com">vasanth@nilahq.com</a>
        </div>
      </section>
      <section className="benchmark-letter">
        <h2>What to send</h2>
        <p>Your firm’s name and the bookkeeping work you’d like help with.</p>
        <p className="public-small">Please leave client names and files out of your first email.</p>
        <p className="public-small">
          Before you share files, we’ll agree the work, inputs, handoff and data handling—including
          access, AI usage, retention and deletion.
        </p>
      </section>
    </main>
  );
}
