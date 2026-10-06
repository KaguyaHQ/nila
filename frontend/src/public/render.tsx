import { ErrorPage } from "./error-page";
import { renderToStaticMarkup } from "react-dom/server";
import { PublicPage } from "./pages";
import { legalPages } from "./legal";

export function renderPublicPage(page: string) {
  const legal = legalPages[page as keyof typeof legalPages];
  if (!legal && !["home", "india", "contact", "india_contact", "business"].includes(page))
    return null;
  return {
    title: legal
      ? `${legal.title} · Nila`
      : page === "home"
        ? "Nila — bookkeeping for accounting firms"
        : page === "india"
          ? "Nila — from sales bills to GST workings"
          : page === "contact"
            ? "Discuss a free bookkeeping test · Nila"
            : page === "business"
              ? "Nila Business — invoices and quotations"
              : "Try Nila on one client",
    description:
      page === "home"
        ? "Test Nila on one completed QBO client month. We prepare the agreed routine bookkeeping for free; your firm compares the work. No ongoing commitment."
        : page === "india"
          ? "GST preparation for CA firms. Read sales invoices, review exceptions and download Excel workings and GSTR-1 JSON with Nila."
          : page === "contact"
            ? "Email Vasanth about a free QBO bookkeeping test. Agree the work, inputs and data handling before sharing files."
            : page === "india_contact"
              ? "Try Nila with one client’s sales bills. Arrange a walkthrough or request a callback."
              : page === "business"
                ? "Create GST invoices and quotations for domestic goods and services with Nila Business."
                : legal.title,
    body: renderToStaticMarkup(<PublicPage page={page} />),
  };
}

export function renderPublicPages() {
  return Object.fromEntries(
    [
      "home",
      "india",
      "business",
      "contact",
      "india_contact",
      "privacy",
      "terms",
      "data_deletion",
    ].map((page) => [page, renderPublicPage(page)]),
  );
}

export function renderErrorPage(status: 404 | 500) {
  return renderToStaticMarkup(<ErrorPage status={status} />);
}
