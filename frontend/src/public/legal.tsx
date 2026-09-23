export const legalPages = {
  privacy: {
    title: "Privacy policy",
    updated: "3 September 2026",
    content: (
      <>
        <p>
          Nila is operated by Kaguya Media Private Limited ("Nila", "we", "us"). This policy
          explains what we collect, why, who processes it on our behalf, and the rights you have
          over it. It covers <span>nila.tax</span> and the Nila application. If anything here is
          unclear, write to <a href="mailto:privacy@nila.tax">privacy@nila.tax</a>.
        </p>

        <section>
          <h2>Who the data belongs to</h2>

          <p>
            Our customers are CA firms and accountants. The documents you upload — bills, bank
            statements, GST returns — describe your clients' businesses. You are the data fiduciary
            for that material; Nila is a data processor acting on your instructions. We use it only
            to produce the workings you asked for, and never to build a product for anyone else.
          </p>
        </section>

        <section>
          <h2>What we collect</h2>

          <ul>
            <li>
              <span>Account data</span> — name, email, firm details, and authentication records for
              the people who log in.
            </li>

            <li>
              <span>Uploaded documents</span> — invoices, bank statements, GSTR files, photos, and
              anything else you send Nila to process, together with the structured records extracted
              from them (vendors, GSTINs, amounts, tax lines).
            </li>

            <li>
              <span>Client and contact details</span> — the businesses and people your work
              concerns, including GSTINs, and the phone numbers or emails Nila uses to chase missing
              documents in your firm's name.
            </li>

            <li>
              <span>WhatsApp communications</span> — incoming and outgoing messages, sender and
              recipient phone numbers, images, PDFs and other attachments, delivery and read
              statuses, message identifiers, and timestamps. We use this data to receive documents,
              follow up on missing records, and show your firm what happened.
            </li>

            <li>
              <span>Operational logs</span> — audit trails of actions taken in the app, and standard
              technical logs (IP, browser, timestamps) needed to run and secure the service.
            </li>
          </ul>
        </section>

        <section>
          <h2>Why we process it</h2>

          <p>
            To extract, classify, and draft the GST artifacts you use; to flag the lines that need a
            human; to follow up on missing documents on your behalf; to secure the service and keep
            an audit trail; and to meet our legal and tax obligations. We do not sell your data, and
            we do not use your clients' documents for advertising.
          </p>
        </section>

        <section>
          <h2>Who processes it for us</h2>

          <p>
            We use a small set of sub-processors under contract, each limited to what its job needs:
          </p>

          <ul>
            <li>
              <span>Hosting &amp; storage</span> — our application server and primary database run
              on Amazon Web Services infrastructure that we administer in Hyderabad, India. Uploaded
              files are stored in Cloudflare R2.
            </li>

            <li>
              <span>Document processing / AI</span> — uploaded documents may be sent to third-party
              model providers solely to extract and structure their contents for your workings.
            </li>

            <li>
              <span>Email &amp; messaging</span> — transactional email (Resend) and Meta's WhatsApp
              Cloud API, used to receive documents, notify you, report delivery status, and chase
              missing records.
            </li>
          </ul>

          <p>
            We will name our current sub-processors on request. Some may process data outside India;
            where they do, we rely on contractual safeguards.
          </p>
        </section>

        <section>
          <h2>How long we keep it</h2>

          <p>
            We retain documents and the records derived from them for as long as your account is
            active and you need them for your filings, plus the period required to meet legal and
            tax record-keeping obligations. When you close your account, we delete or anonymise your
            data within a reasonable period, except where law requires us to keep it longer.
          </p>
        </section>

        <section>
          <h2>How we protect it</h2>

          <p>
            Access is scoped per firm — one firm's documents are never served to another. Data is
            encrypted in transit, access is restricted to personnel who need it, and sensitive
            fields such as bank account numbers are stored encrypted. No system is perfectly secure,
            but we treat financial documents as sensitive by default.
          </p>
        </section>

        <section>
          <h2>Your rights</h2>

          <p>
            You can ask us to access, correct, export, or delete the personal data we hold about
            you, and to address grievances about how we handle it. Where you are acting for your
            clients, we will support you in meeting the corresponding requests from them. Write to{" "}
            <a href="mailto:privacy@nila.tax">privacy@nila.tax</a> and we will respond within a
            reasonable period. See our <a href="/data-deletion">data deletion instructions</a> to
            make a deletion request.
          </p>
        </section>

        <section>
          <h2>Changes</h2>

          <p>
            We may update this policy as the service evolves. Material changes will be posted here
            with a new date; continued use after a change means you accept the updated policy.
          </p>
        </section>
      </>
    ),
  },
  terms: {
    title: "Terms of service",
    updated: "17 July 2026",
    content: (
      <>
        <p>
          These terms govern your use of Nila, operated by Kaguya Media Private Limited ("Nila",
          "we", "us"). By creating an account or using the service you agree to them. If you are
          agreeing on behalf of a firm, you confirm you are authorised to bind it.
        </p>

        <section>
          <h2>What Nila does</h2>

          <p>
            Nila does a junior accountant's preparation work: you send an unstructured mess of
            documents, and Nila extracts, classifies, and drafts structured GST workings —
            registers, reconciliations, and import sheets — and flags the lines that need judgment.
            Nila is a tool that produces drafts for you to review. It is not your accountant,
            auditor, or tax adviser, and using it does not create a professional-client relationship
            with us.
          </p>
        </section>

        <section>
          <h2>You review; you file</h2>

          <p>
            Nila drafts, a human approves. Nila does not file returns or submit anything to any
            authority on your behalf. You are responsible for reviewing every output before you rely
            on it, for the accuracy and legality of what you ultimately file, and for the
            professional judgment applied to the lines Nila flags. The signature stays yours.
          </p>
        </section>

        <section>
          <h2>Your responsibilities</h2>

          <ul>
            <li>
              You have the right to upload the documents you send us and to have us process them,
              including any client authorisation required.
            </li>

            <li>
              You keep your login credentials secure and are responsible for activity under your
              account.
            </li>

            <li>
              You will not use Nila unlawfully, to process data you have no right to, or in a way
              that disrupts the service.
            </li>
          </ul>
        </section>

        <section>
          <h2>Intellectual property</h2>

          <p>
            We and our licensors retain all rights in Nila, including its software, design,
            documentation, and branding. You retain ownership of the data and documents you provide.
            You grant us only the limited rights needed to host, process, transmit, and display that
            material to operate the service for you.
          </p>
        </section>

        <section>
          <h2>No warranty</h2>

          <p>
            The service is provided "as is" and "as available". Automated extraction and
            classification can be wrong, and Nila's flags are aids, not guarantees. To the fullest
            extent permitted by law we disclaim all warranties, express or implied, including
            fitness for a particular purpose and that the output is accurate, complete, or
            compliant. The output is a draft for your review — not tax, legal, or accounting advice.
          </p>
        </section>

        <section>
          <h2>Limitation of liability</h2>

          <p>
            To the fullest extent permitted by law, Nila is not liable for any indirect, incidental,
            or consequential loss, or for any penalties, interest, or tax liability arising from
            returns you prepare or file using our output. Our total liability for any claim relating
            to the service is limited to the fees you paid us for it in the three months before the
            claim arose. Nothing here limits liability that cannot be limited under law.
          </p>
        </section>

        <section>
          <h2>Fees</h2>

          <p>
            Where the service is paid, fees, billing cycle, and taxes are as set out in your order
            or plan. Fees are exclusive of applicable GST unless stated otherwise.
          </p>
        </section>

        <section>
          <h2>Suspension &amp; termination</h2>

          <p>
            You may stop using Nila and close your account at any time. We may suspend or terminate
            access if these terms are breached or the service is misused. On termination, your data
            is handled as described in the <a href="/privacy">privacy policy</a>.
          </p>
        </section>

        <section>
          <h2>Governing law</h2>

          <p>
            These terms are governed by the laws of India, and the courts at Chennai, Tamil Nadu
            have exclusive jurisdiction over any dispute.
          </p>
        </section>

        <section>
          <h2>Changes</h2>

          <p>
            We may update these terms as the service evolves. Material changes will be posted here
            with a new date; continued use after a change means you accept the updated terms.
            Questions go to <a href="mailto:hello@nila.tax">hello@nila.tax</a>.
          </p>
        </section>
      </>
    ),
  },
  data_deletion: {
    title: "Request data deletion",
    updated: "31 July 2026",
    content: (
      <>
        <p>
          You can ask Nila, operated by Kaguya Media Private Limited, to delete or anonymise
          personal data associated with you or your business. This includes eligible account
          details, WhatsApp communications and metadata, uploaded documents, and records derived
          from them.
        </p>

        <section>
          <h2>How to make a request</h2>

          <p>
            Email{" "}
            <a href="mailto:privacy@nila.tax?subject=Data%20deletion%20request">privacy@nila.tax</a>{" "}
            from your registered business email with the subject “Data deletion request”. Include
            your name, company or firm name, registered email, and the phone number associated with
            the WhatsApp communications you want deleted. Do not send identity documents unless we
            ask for them.
          </p>
        </section>

        <section>
          <h2>What happens next</h2>

          <p>
            We will acknowledge the request, verify that you are authorised to make it, and identify
            the relevant data. We will then delete or anonymise eligible data and confirm when the
            request is complete. If the data belongs to one of our customers' clients, we may
            coordinate with that customer before acting on the request.
          </p>
        </section>

        <section>
          <h2>Data we may retain</h2>

          <p>
            Some records may be retained where required by legal and regulatory retention
            requirements, to establish or defend legal claims, prevent fraud or abuse, or preserve
            necessary security and audit records. We restrict retained data to those purposes and
            delete it when the applicable retention period ends. Residual copies in protected
            backups expire through the normal backup lifecycle.
          </p>
        </section>

        <section>
          <h2>Questions</h2>

          <p>
            For questions about deletion or any other privacy right, contact{" "}
            <a href="mailto:privacy@nila.tax">privacy@nila.tax</a>. Our broader handling practices
            are described in the <a href="/privacy">privacy policy</a>.
          </p>
        </section>
      </>
    ),
  },
};
