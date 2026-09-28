import { useLayoutEffect } from "react";

// Keep each register view's place when its evidence reviewer replaces the page.
const positions = new Map<string, number>();

export function useSalesRegisterScroll(key: string) {
  useLayoutEffect(() => {
    const y = positions.get(key) ?? 0;
    let restored = false;
    const remember = () => {
      if (restored) positions.set(key, window.scrollY);
    };
    const frame = requestAnimationFrame(() => {
      window.scrollTo(0, y);
      restored = true;
    });
    window.addEventListener("scroll", remember, { passive: true });
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener("scroll", remember);
    };
  }, [key]);
}
