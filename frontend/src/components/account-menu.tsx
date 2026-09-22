import { useRef } from "react";
import { ChevronsUpDown, LogOut, Settings, UserRound } from "lucide-react";
import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuSeparator, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
export function AccountMenu({ user, collapsed }: { user: { name: string; org: string }; collapsed: boolean }) {
  const logout = useRef<HTMLFormElement>(null);
  return <>
    <DropdownMenu>
      <DropdownMenuTrigger render={<Button variant="ghost" className="h-auto w-full justify-start gap-3 px-2 py-2" />} aria-label="Open account menu">
        <UserRound className="shrink-0" />
        {!collapsed && <><span className="min-w-0 flex-1 text-left"><span className="block truncate text-xs font-medium">{user.name}</span><span className="mt-1 block truncate text-xs font-normal text-muted-foreground">{user.org}</span></span><ChevronsUpDown className="size-3 text-muted-foreground" /></>}
      </DropdownMenuTrigger>
      <DropdownMenuContent side="top" className="min-w-48">
        <DropdownMenuItem render={<a href="/settings/profile" />}><Settings />Settings</DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem variant="destructive" onClick={() => logout.current?.requestSubmit()}><LogOut />Sign out</DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
    <form ref={logout} method="post" action="/users/log_out" hidden>
      <input type="hidden" name="_method" value="delete" />
      <input type="hidden" name="_csrf_token" value={document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""} />
    </form>
  </>;
}
