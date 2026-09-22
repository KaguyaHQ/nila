import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { Keyboard } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Kbd, KbdGroup } from "@/components/ui/kbd";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from "@/components/ui/dialog";

export function navigationShortcutBlocked(event: KeyboardEvent) {
  const target = event.target;
  return event.defaultPrevented || event.repeat || event.isComposing ||
    (target instanceof HTMLElement && (target.isContentEditable || Boolean(target.closest('input, textarea, select, [role="combobox"], [role="listbox"], [role="tablist"], [role="slider"]')))) ||
    [...document.querySelectorAll('[role="dialog"], [role="alertdialog"], [role="menu"], dialog[open]')].some(node => node.getClientRects().length > 0);
}

const Help = createContext<(button?: HTMLElement) => void>(() => {});
export function ShortcutHelpButton() {
  const open = useContext(Help);
  return <Tooltip><TooltipTrigger render={<Button variant="ghost" size="icon-sm" />} aria-label="Keyboard shortcuts" onClick={event => open(event.currentTarget)}><Keyboard /></TooltipTrigger><TooltipContent>Keyboard shortcuts <Kbd>?</Kbd></TooltipContent></Tooltip>;
}

export function KeyboardShortcuts({ children }: { children: ReactNode }) {
  const { pathname, search } = useLocation();
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);
  const opener = useRef<HTMLElement | null>(null);
  const prefix = useRef(0);
  const gst = pathname.match(/^\/gst\/(\d+)\/(\d{4}-\d{2})\/(sales|purchases)(.*)$/);
  const active = Boolean(gst) || pathname.startsWith("/clients");
  const canNavigate = Boolean(gst && /^(|\/register|\/checks|\/uploads|\/sections\/[a-z0-9]+)$/.test(gst[4]));
  function showHelp(button?: HTMLElement) {
    opener.current = button ?? (document.activeElement instanceof HTMLElement ? document.activeElement : null);
    prefix.current = 0;
    setOpen(true);
  }
  useEffect(() => { prefix.current = 0; }, [pathname, search]);
  useEffect(() => {
    function keyboard(event: KeyboardEvent) {
      if (!active || navigationShortcutBlocked(event) || event.altKey || event.ctrlKey || event.metaKey) { prefix.current = 0; return; }
      if (event.key === "?") { event.preventDefault(); showHelp(); return; }
      if (event.shiftKey) { prefix.current = 0; return; }
      if (event.key === "/") {
        prefix.current = 0;
        const input = [...document.querySelectorAll<HTMLInputElement>('[data-shortcut-search]')].find(node => node.getClientRects().length > 0 && !node.disabled && !node.readOnly && !node.closest('[inert], [aria-hidden="true"]'));
        if (input) { event.preventDefault(); input.focus(); input.select(); }
        return;
      }
      if (!canNavigate || !gst) { prefix.current = 0; return; }
      const now = Date.now();
      if (prefix.current && now - prefix.current < 1000 && (event.key === "s" || event.key === "p")) {
        prefix.current = 0;
        event.preventDefault();
        navigate(`/gst/${gst[1]}/${gst[2]}/${event.key === "s" ? "sales" : "purchases"}`);
        return;
      }
      prefix.current = event.key === "g" ? now : 0;
      if (event.key === "[" || event.key === "]") {
        const date = new Date(`${gst[2]}-01T12:00:00Z`);
        if (Number.isNaN(date.getTime())) return;
        date.setUTCMonth(date.getUTCMonth() + (event.key === "[" ? -1 : 1));
        const period = date.toISOString().slice(0, 7);
        if (period < "2017-07" || period > new Date().toISOString().slice(0, 7)) return;
        event.preventDefault();
        navigate(pathname.replace(`/${gst[2]}/`, `/${period}/`) + search);
      }
    }
    const reset = () => { prefix.current = 0; };
    window.addEventListener("keydown", keyboard);
    window.addEventListener("blur", reset);
    return () => { window.removeEventListener("keydown", keyboard); window.removeEventListener("blur", reset); };
  });
  const modifier = /Mac|iPhone|iPad/.test(navigator.platform) ? "⌘" : "Ctrl";
  const groups = [
    { title: "Navigation", rows: [
      { label: "Previous month", keys: ["["] },
      { label: "Next month", keys: ["]"] },
      { label: "Sales", keys: ["G", "S"], sequence: true },
      { label: "Purchases", keys: ["G", "P"], sequence: true },
      { label: "Search", keys: ["/"] },
    ] },
    { title: "Review", rows: [
      { label: "Previous invoice", keys: ["Alt", "←"] },
      { label: "Next invoice", keys: ["Alt", "→"] },
      { label: "Save and next · purchases", keys: [modifier, "↵"] },
      { label: "Close dialog", keys: ["Esc"] },
    ] },
  ];
  return <Help.Provider value={showHelp}>
    {children}
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogContent finalFocus={opener} className="gap-5 sm:max-w-sm max-h-[85dvh] overflow-y-auto">
        <DialogHeader>
          <DialogTitle>Keyboard shortcuts</DialogTitle>
          <DialogDescription className="sr-only">Shortcuts for navigation and invoice review. Navigation pauses while typing or using dialogs.</DialogDescription>
        </DialogHeader>
        {groups.map(group => <section key={group.title} aria-label={group.title} className="space-y-2">
          <h2 className="text-xs font-medium text-muted-foreground">{group.title}</h2>
          <dl>{group.rows.map(row => <div key={row.label} className="flex min-h-8 items-center justify-between gap-4 text-sm">
            <dt>{row.label}</dt>
            <dd><KbdGroup>{row.keys.map((key, index) => <span key={key} className="inline-flex items-center gap-1">
              {index > 0 && "sequence" in row && <span className="px-1 text-xs text-muted-foreground">then</span>}
              <Kbd>{key}</Kbd>
            </span>)}</KbdGroup></dd>
          </div>)}</dl>
        </section>)}
      </DialogContent>
    </Dialog>
  </Help.Provider>;
}
