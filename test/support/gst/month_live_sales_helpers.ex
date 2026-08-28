defmodule NilaWeb.Gst.MonthLiveSalesHelpers do
  import Phoenix.LiveViewTest

  def confirm_all_open_issues(view) do
    # Month-level issues stay on the working paper; invoice issues live in SalesLive.
    for invoice <- ["20/2025-26"] do
      view |> element("#gstr1-inv-#{String.replace(invoice, "/", "\\/")}") |> render_click()

      while_confirmable(view)

      view
      |> element("#sales-review button[phx-click='done']")
      |> render_click()
    end

    while_confirmable(view)
  end

  defp while_confirmable(view) do
    cond do
      has_element?(view, "button[phx-click='resolve-invoice-issue']") ->
        view
        |> element("button[phx-click='resolve-invoice-issue']:first-of-type")
        |> render_click()

        while_confirmable(view)

      has_element?(view, "button[phx-click='confirm_issue']") ->
        view |> element("button[phx-click='confirm_issue']:first-of-type") |> render_click()
        while_confirmable(view)

      true ->
        :ok
    end
  end
end
