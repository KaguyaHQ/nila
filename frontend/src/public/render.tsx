import { renderToStaticMarkup } from "react-dom/server";
import { PublicPage } from "./pages";
import { legalPages } from "./legal";

export function renderPublicPage(page: string) {
  const legal = legalPages[page as keyof typeof legalPages];
  if (!legal && page !== "home" && page !== "contact") return null;
  return {
    title: legal
      ? `${legal.title} · Nila`
      : page === "home"
        ? "Nila — from sales bills to GST workings"
        : "Try Nila on one client",
    description:
      page === "home"
        ? "GST preparation for CA firms. Read sales invoices, review exceptions and download Excel workings and GSTR-1 JSON with Nila."
        : page === "contact"
          ? "Try Nila with one client’s sales bills. Arrange a walkthrough or request a callback."
          : legal.title,
    body: renderToStaticMarkup(<PublicPage page={page} />),
  };
}

export function renderPublicPages() {
  return Object.fromEntries(
    ["home", "contact", "privacy", "terms", "data_deletion"].map((page) => [
      page,
      renderPublicPage(page),
    ]),
  );
}
