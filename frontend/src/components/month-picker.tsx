import { useRef, useState } from "react";
import { ChevronDown, ChevronLeft, ChevronRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Popover, PopoverContent, PopoverTitle, PopoverTrigger } from "@/components/ui/popover";

const months = [
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
];

export function MonthPicker({
  period,
  label,
  onSelect,
  large = false,
  min = "2017-07",
  max,
}: {
  period: string;
  label: string;
  onSelect: (period: string) => void;
  large?: boolean;
  min?: string;
  max: string;
}) {
  const [open, setOpen] = useState(false);
  const [year, setYear] = useState(Number(period.slice(0, 4)));
  const selected = useRef<HTMLButtonElement>(null);
  return (
    <Popover
      open={open}
      onOpenChange={(value) => {
        if (value) setYear(Number(period.slice(0, 4)));
        setOpen(value);
      }}
    >
      <PopoverTrigger
        aria-label="Choose month"
        render={
          <Button
            variant="ghost"
            size="sm"
            className={
              large
                ? "h-auto px-0 text-3xl font-semibold tracking-tight hover:bg-transparent"
                : undefined
            }
          />
        }
      >
        {label}
        <ChevronDown className={large ? "ml-2 size-4" : "size-4"} />
      </PopoverTrigger>
      <PopoverContent align="start" sideOffset={8} className="w-64 p-3" initialFocus={selected}>
        <PopoverTitle className="sr-only">Choose working month</PopoverTitle>
        <div className="flex items-center justify-between">
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="Previous year"
            disabled={year <= Number(min.slice(0, 4))}
            onClick={() => setYear(year - 1)}
          >
            <ChevronLeft />
          </Button>
          <span className="font-semibold tabular-nums" aria-live="polite">
            {year}
          </span>
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="Next year"
            disabled={year >= Number(max.slice(0, 4))}
            onClick={() => setYear(year + 1)}
          >
            <ChevronRight />
          </Button>
        </div>
        <div className="grid grid-cols-3 gap-1" role="group" aria-label={`Months in ${year}`}>
          {months.map((month, index) => {
            const value = `${year}-${String(index + 1).padStart(2, "0")}`;
            const active = value === period;
            return (
              <Button
                key={month}
                ref={active ? selected : undefined}
                variant={active ? "default" : "ghost"}
                aria-label={`${month} ${year}`}
                aria-pressed={active}
                disabled={value < min || value > max}
                onClick={() => {
                  setOpen(false);
                  if (value !== period) onSelect(value);
                }}
              >
                {month.slice(0, 3)}
              </Button>
            );
          })}
        </div>
      </PopoverContent>
    </Popover>
  );
}
