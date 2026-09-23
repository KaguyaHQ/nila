import { ArrowDown, ArrowRight, Check, FileSpreadsheet } from "lucide-react";

export function InvoiceStory() {
  return (
    <section className="invoice-story" aria-label="From invoice to working: an illustrated example">
      <div className="story-stage">
        <div className="story-heading">
          <p className="public-eyebrow">Nila / GST preparation for CA firms</p>
          <h1>
            Every working starts
            <br />
            with a bill.
          </h1>
          <p>Follow one from the source to the spreadsheet.</p>
        </div>
        <div className="story-canvas">
          <article className="story-paper">
            <div className="paper-masthead">
              <strong>
                MARINA
                <br />
                ENGINEERING
              </strong>
              <span>
                TAX INVOICE
                <br />
                <b>INV-1842</b>
              </span>
            </div>
            <div className="paper-rule" />
            <div className="paper-address">
              <div>
                <small>BILLED TO</small>
                <b>Orchard Industries</b>
                <span>Chennai, Tamil Nadu</span>
              </div>
              <div>
                <small>INVOICE DATE</small>
                <b>12 June 2026</b>
                <span>Payment due in 30 days</span>
              </div>
            </div>
            <table className="paper-items">
              <thead>
                <tr>
                  <th>Description</th>
                  <th>Amount</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td>
                    Equipment maintenance
                    <br />
                    <small>Service &amp; inspection · 1 unit</small>
                  </td>
                  <td>₹84,500.00</td>
                </tr>
              </tbody>
            </table>
            <dl className="paper-totals">
              <div className="paper-taxable">
                <dt>Taxable value</dt>
                <dd>₹84,500.00</dd>
              </div>
              <div>
                <dt>CGST · 9%</dt>
                <dd>₹7,605.00</dd>
              </div>
              <div>
                <dt>SGST · 9%</dt>
                <dd>₹7,605.00</dd>
              </div>
              <div className="paper-total">
                <dt>Total</dt>
                <dd>₹99,710.00</dd>
              </div>
            </dl>
            <div className="paper-foot">
              <span>Thank you for your business.</span>
              <span>
                Authorised signatory
                <br />
                <i>Marina</i>
              </span>
            </div>
            <span className="story-annotation">
              Source value located <Check size={13} />
            </span>
          </article>
          <aside className="story-review">
            <div className="story-review-top">
              <span className="public-logo">nila</span>
              <span>02 / REVIEW</span>
            </div>
            <h2>One number needs a look.</h2>
            <p>The extracted taxable value differs from the printed invoice.</p>
            <div className="story-correction">
              <span>Extracted</span>
              <s>₹84,050.00</s>
              <ArrowRight size={18} />
              <div>
                <small>On the invoice</small>
                <strong className="story-value-source">₹84,500.00</strong>
              </div>
            </div>
            <div className="story-confirmation">
              <Check size={17} />
              <span>Reviewer confirmed the source value</span>
            </div>
            <small className="story-demo-note">
              Illustrated review · no real invoice is being changed
            </small>
          </aside>
          <article className="story-sheet">
            <div className="sheet-title">
              <FileSpreadsheet size={20} />
              <div>
                <h2>GST sales working</h2>
                <span>June 2026 · Sample client</span>
              </div>
              <span className="sheet-file">XLSX</span>
            </div>
            <div className="sheet-scroll">
              <table>
                <thead>
                  <tr>
                    <th>Invoice</th>
                    <th>Taxable value</th>
                    <th>CGST</th>
                    <th>SGST</th>
                    <th>Invoice total</th>
                  </tr>
                </thead>
                <tbody>
                  <tr>
                    <td>INV-1842</td>
                    <td>
                      <span className="story-value-target">₹84,500.00</span>
                    </td>
                    <td>₹7,605.00</td>
                    <td>₹7,605.00</td>
                    <td>₹99,710.00</td>
                  </tr>
                  <tr className="sheet-empty-row">
                    <td>—</td>
                    <td>—</td>
                    <td>—</td>
                    <td>—</td>
                    <td>—</td>
                  </tr>
                  <tr className="sheet-empty-row">
                    <td>—</td>
                    <td>—</td>
                    <td>—</td>
                    <td>—</td>
                    <td>—</td>
                  </tr>
                </tbody>
              </table>
            </div>
            <div className="sheet-footer">
              <Check size={15} /> Reviewed against INV-1842<span>Source retained</span>
            </div>
          </article>
          <div className="story-transfer" aria-hidden="true">
            ₹84,500.00
          </div>
        </div>
        <div className="story-caption">
          <span className="story-caption-source">01 — The original invoice</span>
          <span className="story-caption-review">02 — A person checks the exception</span>
          <span className="story-caption-working">03 — The checked facts become your working</span>
        </div>
        <div className="story-bottom">
          <span>Sample invoice</span>
          <a href="#how-it-works">
            Skip to the workflow <ArrowDown size={14} />
          </a>
        </div>
        <div className="story-progress" aria-hidden="true" />
      </div>
    </section>
  );
}
