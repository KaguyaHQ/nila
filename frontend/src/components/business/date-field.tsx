import { CalendarDays } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { Button } from "@/components/ui/button";
import { Calendar } from "@/components/ui/calendar";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { InlineInput } from "./inline-input";

function fromIso(value: string): Date | undefined {
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value);
  if (!match) return undefined;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const date = new Date(0);
  date.setFullYear(year, month - 1, day);
  date.setHours(12, 0, 0, 0);
  return date.getFullYear() === year && date.getMonth() === month - 1 && date.getDate() === day
    ? date
    : undefined;
}

function toIso(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function display(value: string): string {
  const date = fromIso(value);
  return date
    ? `${String(date.getDate()).padStart(2, "0")}/${String(date.getMonth() + 1).padStart(2, "0")}/${date.getFullYear()}`
    : "";
}

function parse(value: string): Date | undefined {
  const match = /^(\d{1,2})[/.-](\d{1,2})[/.-](\d{2}|\d{4})$/.exec(value.trim());
  if (!match) return undefined;
  const year = Number(match[3].length === 2 ? `20${match[3]}` : match[3]);
  return fromIso(`${year}-${match[2].padStart(2, "0")}-${match[1].padStart(2, "0")}`);
}

export function BusinessDateField({
  id,
  label,
  value,
  onChange,
  disabled,
  required = false,
  min,
}: {
  id: string;
  label: string;
  value: string;
  onChange: (value: string) => void;
  disabled: boolean;
  required?: boolean;
  min?: string;
}) {
  const [text, setText] = useState(() => display(value));
  const [invalid, setInvalid] = useState(false);
  const [open, setOpen] = useState(false);
  const [month, setMonth] = useState(() => fromIso(value) ?? new Date());
  const input = useRef<HTMLInputElement>(null);
  const editing = useRef(false);
  const minimum = min ? fromIso(min) : undefined;

  useEffect(() => {
    if (!editing.current) setText(display(value));
  }, [value]);

  useEffect(() => {
    if (editing.current) return;
    const selected = fromIso(value);
    const lower = min ? fromIso(min) : undefined;
    const beforeMinimum = Boolean(selected && lower && selected < lower);
    input.current?.setCustomValidity(
      beforeMinimum ? "Date cannot be before the document date." : "",
    );
    setInvalid(beforeMinimum);
  }, [value, min]);

  function validDate(raw: string): Date | undefined {
    const date = parse(raw);
    return date && (!minimum || date >= minimum) ? date : undefined;
  }

  function type(raw: string) {
    setText(raw);
    setInvalid(false);
    const date = validDate(raw);
    input.current?.setCustomValidity(raw && !date ? "Enter a valid date as DD/MM/YYYY." : "");
    onChange(date ? toIso(date) : "");
  }

  function finish() {
    editing.current = false;
    if (!text) return;
    const date = validDate(text);
    if (date) {
      setText(display(toIso(date)));
      input.current?.setCustomValidity("");
      onChange(toIso(date));
    } else {
      setInvalid(true);
    }
  }

  function choose(date: Date | undefined) {
    if (!date) return;
    const iso = toIso(date);
    setText(display(iso));
    setInvalid(false);
    input.current?.setCustomValidity("");
    onChange(iso);
    setOpen(false);
  }

  return (
    <div className="flex min-w-0 items-center gap-1">
      <InlineInput
        ref={input}
        id={id}
        type="text"
        inputMode="numeric"
        autoComplete="off"
        placeholder="DD/MM/YYYY"
        maxLength={10}
        required={required}
        disabled={disabled}
        aria-label={label}
        aria-keyshortcuts="Alt+ArrowDown"
        aria-invalid={invalid || undefined}
        value={text}
        className="min-w-0 flex-1 tabular-nums"
        onFocus={() => {
          editing.current = true;
        }}
        onChange={(event) => type(event.target.value)}
        onBlur={finish}
        onKeyDown={(event) => {
          if (event.altKey && event.key === "ArrowDown") {
            event.preventDefault();
            setMonth(fromIso(value) ?? new Date());
            setOpen(true);
          }
        }}
      />
      {!disabled && (
        <Popover
          open={open}
          onOpenChange={(next) => {
            if (next) setMonth(fromIso(value) ?? new Date());
            setOpen(next);
          }}
        >
          <PopoverTrigger
            type="button"
            tabIndex={-1}
            aria-label={`Choose ${label.toLowerCase()}`}
            render={<Button type="button" variant="ghost" size="icon-sm" />}
          >
            <CalendarDays className="size-4" />
          </PopoverTrigger>
          <PopoverContent align="start" className="w-auto p-1">
            <Calendar
              mode="single"
              selected={fromIso(value)}
              month={month}
              onMonthChange={setMonth}
              onSelect={choose}
              captionLayout="dropdown"
              startMonth={new Date(1900, 0)}
              endMonth={new Date(2100, 11)}
              disabled={minimum ? { before: minimum } : undefined}
              autoFocus
            />
            {!required && value && (
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="ml-2 mb-1"
                onClick={() => {
                  setText("");
                  input.current?.setCustomValidity("");
                  onChange("");
                  setOpen(false);
                }}
              >
                Clear
              </Button>
            )}
          </PopoverContent>
        </Popover>
      )}
    </div>
  );
}
