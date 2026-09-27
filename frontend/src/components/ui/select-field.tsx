import { Children, Fragment, isValidElement, type ReactElement, type ReactNode } from "react";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";

type SelectFieldOptionProps = {
  value: string | number;
  disabled?: boolean;
  children: ReactNode;
};

function SelectFieldOption(_props: SelectFieldOptionProps) {
  return null;
}

function labelText(children: ReactNode): string {
  return Children.toArray(children)
    .map((child) => (typeof child === "string" || typeof child === "number" ? String(child) : ""))
    .join("");
}

function collectOptions(children: ReactNode): ReactElement<SelectFieldOptionProps>[] {
  const options: ReactElement<SelectFieldOptionProps>[] = [];
  Children.forEach(children, (child) => {
    if (!isValidElement<{ children: ReactNode }>(child)) return;
    if (child.type === SelectFieldOption) {
      options.push(child as ReactElement<SelectFieldOptionProps>);
    } else if (child.type === Fragment) {
      options.push(...collectOptions(child.props.children));
    }
  });
  return options;
}

type SelectFieldProps = {
  children: ReactNode;
  value?: string | number;
  defaultValue?: string | number;
  onValueChange?: (value: string) => void;
  id?: string;
  name?: string;
  disabled?: boolean;
  required?: boolean;
  className?: string;
  placeholder?: string;
  "aria-label"?: string;
  "aria-describedby"?: string;
  "aria-invalid"?: boolean;
};

function SelectField({
  children,
  value,
  defaultValue,
  onValueChange,
  id,
  name,
  disabled,
  required,
  className,
  placeholder,
  ...ariaProps
}: SelectFieldProps) {
  const options = collectOptions(children);
  const items = options.map((option) => ({
    value: String(option.props.value),
    label: labelText(option.props.children),
    disabled: option.props.disabled,
  }));

  return (
    <Select
      items={items}
      value={value === undefined ? undefined : String(value)}
      defaultValue={defaultValue === undefined ? undefined : String(defaultValue)}
      onValueChange={(next) => onValueChange?.(next ?? "")}
      name={name}
      disabled={disabled}
      required={required}
    >
      <SelectTrigger
        id={id}
        data-value={value === undefined ? undefined : String(value)}
        className={className}
        {...ariaProps}
      >
        <SelectValue placeholder={placeholder ?? items.find((item) => item.value === "")?.label} />
      </SelectTrigger>
      <SelectContent alignItemWithTrigger={false}>
        {options.map((option, index) => (
          <SelectItem
            key={option.key ?? index}
            value={String(option.props.value)}
            data-value={String(option.props.value)}
            disabled={option.props.disabled}
          >
            {option.props.children}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}

export { SelectField, SelectFieldOption };
