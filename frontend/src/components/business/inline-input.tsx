/**
 * Adapted from Midday invoice/input.tsx, amount-input.tsx and quantity-input.tsx.
 * Copyright (c) 2023-present Midday Labs AB. AGPL-3.0.
 * Source: midday-ai/midday @ 51587319f26a0ffaa9dfccab1920373cb65689b7
 * Nila adaptation: controlled decimal strings, shared shadcn inputs, accessible
 * placeholders instead of hidden fields; Phoenix remains the arithmetic owner.
 */
import { useState, type ComponentProps } from "react";
import { Textarea } from "@/components/ui/textarea";
import { Input } from "@/components/ui/input";
import { NativeSelect } from "@/components/ui/native-select";
import { cn } from "@/lib/utils";

export function InlineInput({ className, onFocus, onBlur, ...props }: ComponentProps<typeof Input>) {
  const [isFocused, setIsFocused] = useState(false);
  const isPlaceholder = (props.value === "" || props.value == null) && !isFocused;
  return <Input {...props} autoComplete="off"
    className={cn("h-8 rounded-none border-0 border-b border-transparent bg-transparent px-0 py-1 text-sm shadow-none focus-visible:border-ring focus-visible:ring-0 disabled:opacity-100 [appearance:textfield] [&::-webkit-inner-spin-button]:appearance-none [&::-webkit-outer-spin-button]:appearance-none", isPlaceholder && "border-dashed border-border", className)}
    onFocus={event => { setIsFocused(true); onFocus?.(event); }}
    onBlur={event => { setIsFocused(false); onBlur?.(event); }}
  />;
}

export function InlineSelect({ className, ...props }: ComponentProps<typeof NativeSelect>) {
  return <NativeSelect {...props} className={cn("h-8 rounded-none border-0 border-b border-transparent bg-transparent px-0 text-sm shadow-none focus-visible:border-ring focus-visible:ring-0 disabled:opacity-100", className)} />;
}

export function InlineTextarea({ className, ...props }: ComponentProps<typeof Textarea>) {
  return <Textarea {...props} rows={1} className={cn("field-sizing-content min-h-8 resize-none overflow-hidden rounded-none border-0 border-b border-transparent bg-transparent px-0 py-1 text-sm leading-6 shadow-none focus-visible:border-ring focus-visible:ring-0 disabled:bg-transparent disabled:opacity-100", className)} />;
}
