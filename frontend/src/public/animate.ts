import { scroll, transform } from "motion";

// Enhance the server-rendered illustration. The complete story remains readable
// without JavaScript, on small screens, and when reduced motion is requested.
const story = document.querySelector<HTMLElement>(".invoice-story");
const media = matchMedia(
  "(prefers-reduced-motion: no-preference) and (min-width: 1000px) and (min-height: 600px)",
);
let cleanup = () => {};
function setup() {
  cleanup();
  if (!story || !media.matches) return;
  const stops: (() => void)[] = [];
  // Measure the actual two values so the number lands in its spreadsheet cell.
  const canvas = story.querySelector<HTMLElement>(".story-canvas");
  const transfer = story.querySelector<HTMLElement>(".story-transfer");
  const source = story.querySelector<HTMLElement>(".story-value-source");
  const target = story.querySelector<HTMLElement>(".story-value-target");
  if (!canvas || !transfer || !source || !target) return;
  story.classList.add("story-animated");
  const scale = canvas.getBoundingClientRect().width / canvas.offsetWidth;
  const origin = transfer.getBoundingClientRect();
  const point = (element: HTMLElement) => {
    const rect = element.getBoundingClientRect();
    return {
      x: (rect.left + rect.width / 2 - origin.left - origin.width / 2) / scale,
      y: (rect.top + rect.height / 2 - origin.top - origin.height / 2) / scale,
    };
  };
  const from = point(source);
  const to = point(target);

  function track(selector: string, frames: Record<string, number[]>, times: number[]) {
    const element = story?.querySelector<HTMLElement>(selector);
    if (!element || !story) return;
    const sample = Object.fromEntries(
      Object.entries(frames).map(([key, values]) => [key, transform(times, values)]),
    );
    stops.push(
      scroll(
        (progress: number) => {
          const value = (key: string, fallback: number) => sample[key]?.(progress) ?? fallback;
          element.style.transform = `translate(${value("x", 0)}px, ${value("y", 0)}px) scale(${value("scale", 1)}) rotate(${value("rotate", 0)}deg)`;
          if (sample.opacity) element.style.opacity = String(value("opacity", 1));
          if (sample.scaleX) element.style.transform = `scaleX(${value("scaleX", 1)})`;
        },
        { target: story, offset: ["start start", "end end"] },
      ),
    );
    stops.push(() => element.removeAttribute("style"));
  }
  track(
    ".story-paper",
    {
      x: [0, 0, -270, -270, -330],
      y: [0, 0, 0, 0, -65],
      scale: [1, 1, 0.86, 0.86, 0.62],
      rotate: [-3, -3, -2, -2, -6],
      opacity: [1, 1, 1, 1, 0.22],
    },
    [0, 0.12, 0.32, 0.62, 0.82],
  );
  track(
    ".story-review",
    { opacity: [0, 0, 1, 1, 0], y: [25, 25, 0, 0, -30] },
    [0, 0.23, 0.34, 0.65, 0.73],
  );
  track(".story-annotation", { opacity: [0, 0, 1, 1, 0] }, [0, 0.2, 0.32, 0.62, 0.73]);
  track(".story-confirmation", { opacity: [0, 0, 1, 1], y: [8, 8, 0, 0] }, [0, 0.43, 0.53, 1]);
  track(
    ".story-sheet",
    { opacity: [0, 0, 1, 1], y: [75, 75, 0, 0], scale: [0.94, 0.94, 1, 1] },
    [0, 0.65, 0.77, 1],
  );
  track(
    ".story-transfer",
    {
      opacity: [0, 0, 1, 1, 0],
      x: [from.x, from.x, from.x, to.x, to.x],
      y: [from.y, from.y, from.y, to.y, to.y],
      scale: [1, 1, 1, 0.72, 0.72],
    },
    [0, 0.62, 0.65, 0.83, 0.86],
  );
  track(".story-value-target", { opacity: [0, 0, 1, 1] }, [0, 0.83, 0.86, 1]);
  track(".story-caption-source", { opacity: [1, 1, 0, 0] }, [0, 0.18, 0.27, 1]);
  track(".story-caption-review", { opacity: [0, 0, 1, 1, 0] }, [0, 0.23, 0.33, 0.64, 0.74]);
  track(".story-caption-working", { opacity: [0, 0, 1, 1] }, [0, 0.72, 0.82, 1]);
  track(".story-progress", { scaleX: [0, 1] }, [0, 1]);
  cleanup = () => {
    for (const stop of stops) stop();
    story.classList.remove("story-animated");
  };
}
setup();
void document.fonts.ready.then(setup);
window.addEventListener("resize", setup);
media.addEventListener("change", setup);
if (import.meta.hot)
  import.meta.hot.dispose(() => {
    cleanup();
    window.removeEventListener("resize", setup);
    media.removeEventListener("change", setup);
  });
