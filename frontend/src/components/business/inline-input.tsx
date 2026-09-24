/**
 * Adapted from Midday invoice/input.tsx, amount-input.tsx and quantity-input.tsx.
 * Copyright (c) 2023-present Midday Labs AB. AGPL-3.0.
 * Source: midday-ai/midday @ 51587319f26a0ffaa9dfccab1920373cb65689b7
 * Nila adaptation: controlled decimal strings, shared shadcn inputs, accessible
 * placeholders instead of hidden fields; Phoenix remains the arithmetic owner.
 */
import { type ComponentProps, useState } from "react";
import { Input } from "@/components/ui/input";
import { NativeSelect } from "@/components/ui/native-select";
import { Textarea } from "@/components/ui/textarea";
import { cn } from "@/lib/utils";

export function InlineInput({
  className,
  onFocus,
  onBlur,
  ...props
}: ComponentProps<typeof Input>) {
  const [isFocused, setIsFocused] = useState(false);
  const isPlaceholder = (props.value === "" || props.value == null) && !isFocused;
  return (
    <Input
      {...props}
      autoComplete="off"
      className={cn(
        "h-8 rounded-sm border border-border/70 bg-muted/30 px-2 py-1 text-sm shadow-none hover:border-ring/60 hover:bg-accent/50 focus-visible:border-ring focus-visible:bg-background focus-visible:ring-2 focus-visible:ring-ring/30 disabled:border-transparent disabled:bg-transparent disabled:opacity-100 [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none",
        isPlaceholder && "border-dashed",
        className,
      )}
      onFocus={(event) => {
        setIsFocused(true);
        onFocus?.(event);
      }}
      onBlur={(event) => {
        setIsFocused(false);
        onBlur?.(event);
      }}
    />
  );
}

export function InlineSelect({ className, ...props }: ComponentProps<typeof NativeSelect>) {
  return (
    <NativeSelect
      {...props}
      className={cn(
        "h-8 w-full border-0 bg-transparent p-0 text-sm shadow-none disabled:opacity-100 [&_select]:rounded-sm [&_select]:border-border/70 [&_select]:bg-muted/30 [&_select]:pl-2 [&_select]:pr-6 [&_select]:hover:border-ring/60 [&_select]:hover:bg-accent/50 [&_select]:focus-visible:border-ring [&_select]:focus-visible:bg-background [&_select]:focus-visible:ring-2 [&_select]:focus-visible:ring-ring/30 [&_select:disabled]:border-transparent [&_select:disabled]:bg-transparent",
        className,
      )}
    />
  );
}

export function InlineTextarea({ className, ...props }: ComponentProps<typeof Textarea>) {
  return (
    <Textarea
      {...props}
      rows={1}
      className={cn(
        "field-sizing-content min-h-8 resize-none overflow-hidden rounded-sm border border-border/70 bg-muted/30 px-2 py-1 text-sm leading-6 shadow-none hover:border-ring/60 hover:bg-accent/50 focus-visible:border-ring focus-visible:bg-background focus-visible:ring-2 focus-visible:ring-ring/30 disabled:border-transparent disabled:bg-transparent disabled:opacity-100",
        className,
      )}
    />
  );
}
