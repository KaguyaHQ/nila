if Application.compile_env(:nila, :dev_routes, false) or
     Application.compile_env(:nila, :compile_design_system, false) do
  defmodule NilaWeb.Dev.DesignSystemLive do
    @moduledoc false
    use NilaWeb, :live_view

    @rows [
      %{
        invoice: "INV-1042",
        party: "Aster Components",
        place: "Gujarat",
        taxable_paise: 12_500_000,
        rate: "18%",
        status: "Reviewed",
        variant: "success"
      },
      %{
        invoice: "INV-1048",
        party: "Dune Retail",
        place: "Maharashtra",
        taxable_paise: 8_760_000,
        rate: "12%",
        status: "Needs POS",
        variant: "warning"
      },
      %{
        invoice: "INV-1051",
        party: "Meridian Works",
        place: "Karnataka",
        taxable_paise: 3_616_000,
        rate: "18%",
        status: "Proposed",
        variant: "info"
      }
    ]

    @impl true
    def mount(_params, _session, socket) do
      {:ok,
       socket
       |> assign(:open_folds, MapSet.new(["ds-b2b-schedule"]))
       |> assign(:show_modal, false)
       |> assign(:rows, @rows)}
    end

    @impl true
    def handle_event("open-design-modal", _params, socket),
      do: {:noreply, assign(socket, :show_modal, true)}

    def handle_event("close-design-modal", _params, socket),
      do: {:noreply, assign(socket, :show_modal, false)}

    def handle_event("toggle-fold", %{"fold" => fold}, socket) do
      open_folds =
        if MapSet.member?(socket.assigns.open_folds, fold) do
          MapSet.delete(socket.assigns.open_folds, fold)
        else
          MapSet.put(socket.assigns.open_folds, fold)
        end

      {:noreply, assign(socket, :open_folds, open_folds)}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <Layouts.app flash={@flash} current_path="/dev/design-system">
        <div id="design-system-reference" class="h-full overflow-y-auto">
          <main class="lg:py-canvas py-region mx-auto max-w-7xl px-6 lg:px-8">
            <div class="space-y-canvas">
              <header class="border-base-300 moonlight py-region rounded-box border px-6 lg:px-8">
                <div class="gap-region grid lg:grid-cols-[minmax(0,1fr)_auto] lg:items-end">
                  <div class="space-y-related">
                    <p class="text-eyebrow text-moon font-semibold uppercase">Development reference</p>
                    <h1 class="font-display text-h2 font-normal">Nila design system</h1>
                    <p class="text-body text-ink-muted max-w-2xl font-light">
                      Executable components, accounting-shaped examples, and semantic tokens.
                      CSS and component modules remain the source of truth.
                    </p>
                  </div>
                  <.badge variant="warning">Static specimen · not client data</.badge>
                </div>
              </header>

              <nav aria-label="Design system sections" class="gap-related flex flex-wrap">
                <.button href="#foundations" variant="ghost" size="sm">Foundations</.button>
                <.button href="#components" variant="ghost" size="sm">Components</.button>
                <.button href="#accounting" variant="ghost" size="sm">Accounting</.button>
                <.button href="#workpaper" variant="ghost" size="sm">Workpaper</.button>
              </nav>

              <section id="foundations" class="space-y-region scroll-mt-8">
                <.section_heading
                  eyebrow="Foundations"
                  title="A small vocabulary, visible at actual scale"
                >
                  Type roles follow meaning. Color, spacing, and ink remain semantic.
                </.section_heading>

                <div class="gap-section grid xl:grid-cols-2">
                  <.card id="ds-typography" class="space-y-section">
                    <div>
                      <h3 class="text-h4 font-semibold">Typography</h3>
                      <p class="text-ink-muted text-ui">
                        16px to read · 14px to work · 12px for context
                      </p>
                    </div>

                    <div class="space-y-section">
                      <.type_sample role="Hero" class="font-display text-hero font-normal">
                        Month closed.
                      </.type_sample>
                      <.type_sample role="Statement" class="font-display text-statement font-normal">
                        Ready for review.
                      </.type_sample>
                      <.type_sample role="Heading 2" class="font-display text-h2 font-normal">
                        Sales & GSTR-1
                      </.type_sample>
                      <.type_sample role="Heading 3" class="font-display text-h3 font-normal">
                        Return workings
                      </.type_sample>
                      <.type_sample role="Heading 4" class="text-h4 font-semibold">
                        Human assurance
                      </.type_sample>
                      <.type_sample role="Lead" class="text-lead font-light">
                        Books and return populations are prepared for inspection.
                      </.type_sample>
                      <.type_sample role="Body" class="text-body font-light">
                        Review the two invoices where place of supply changes the return treatment.
                      </.type_sample>
                      <.type_sample role="UI" class="text-ui font-medium">
                        INV-1048 · Needs place of supply
                      </.type_sample>
                      <div id="ds-type-context" class="space-y-related">
                        <p class="text-ink-subtle text-label font-semibold uppercase">Context</p>
                        <.context_text tag="p">
                          Imported 17 Aug 2026 · sales-register.xlsx · Sheet 1
                        </.context_text>
                      </div>
                      <.type_sample
                        role="Label"
                        class="text-ink-subtle text-label font-semibold uppercase"
                      >
                        Taxable value
                      </.type_sample>
                    </div>
                  </.card>

                  <div class="space-y-section">
                    <.card id="ds-colors" class="space-y-section">
                      <div>
                        <h3 class="text-h4 font-semibold">Semantic color</h3>
                        <p class="text-ink-muted text-ui">Named by purpose, never by palette value.</p>
                      </div>
                      <div class="gap-block grid grid-cols-2 sm:grid-cols-4">
                        <.swatch name="Primary" class="bg-primary text-primary-content" />
                        <.swatch name="Accent" class="bg-accent text-accent-content" />
                        <.swatch name="Info" class="bg-info text-info-content" />
                        <.swatch name="Success" class="bg-success text-success-content" />
                        <.swatch name="Warning" class="bg-warning text-warning-content" />
                        <.swatch name="Error" class="bg-error text-error-content" />
                        <.swatch name="Canvas" class="bg-base-200 text-base-content" />
                        <.swatch name="Surface" class="bg-base-100 text-base-content" />
                      </div>
                    </.card>

                    <.card id="ds-spacing" class="space-y-section">
                      <div>
                        <h3 class="text-h4 font-semibold">Structural spacing</h3>
                        <p class="text-ink-muted text-ui">Relationships, not arbitrary gaps.</p>
                      </div>
                      <div class="space-y-block">
                        <.spacing_sample name="Related" width="w-related" />
                        <.spacing_sample name="Block" width="w-block" />
                        <.spacing_sample name="Section" width="w-section" />
                        <.spacing_sample name="Region" width="w-region" />
                        <.spacing_sample name="Canvas" width="w-canvas" />
                      </div>
                    </.card>
                  </div>
                </div>
              </section>

              <section id="components" class="space-y-region scroll-mt-8">
                <.section_heading eyebrow="Components" title="Shared recipes, not copied classes">
                  Variants express action and state while typography remains readable.
                </.section_heading>

                <div class="gap-section grid xl:grid-cols-2">
                  <.card id="ds-buttons" class="space-y-section">
                    <div>
                      <h3 class="text-h4 font-semibold">Buttons</h3>
                      <p class="text-ink-muted text-ui">
                        One state-aware primary action per workpaper.
                      </p>
                    </div>
                    <div class="gap-related flex flex-wrap items-center">
                      <.button>Approve GSTR-1</.button>
                      <.button variant="soft">Review next</.button>
                      <.button variant="outline">Export workbook</.button>
                      <.button variant="ghost">View evidence</.button>
                      <.button variant="soft" disabled>Unavailable</.button>
                    </div>
                    <div class="gap-related flex flex-wrap items-center">
                      <.button size="xs" variant="soft">Compact</.button>
                      <.button variant="soft">Standard</.button>
                      <.button size="lg" variant="soft">Prominent</.button>
                    </div>
                  </.card>

                  <.card id="ds-badges" class="space-y-section">
                    <div>
                      <h3 class="text-h4 font-semibold">Statuses</h3>
                      <p class="text-ink-muted text-ui">
                        Machine, human, workflow, and approval states stay distinct.
                      </p>
                    </div>
                    <div class="gap-related flex flex-wrap">
                      <.badge variant="info">Proposed</.badge>
                      <.badge variant="warning">Needs review</.badge>
                      <.badge variant="success">Reviewed</.badge>
                      <.badge variant="primary">Approved</.badge>
                      <.badge variant="error">Blocked</.badge>
                      <.badge variant="neutral">Not independently tested</.badge>
                    </div>
                  </.card>
                </div>

                <.card id="ds-fields" class="space-y-section">
                  <div>
                    <h3 class="text-h4 font-semibold">Fields</h3>
                    <p class="text-ink-muted text-ui">
                      Standard controls share one 32px working geometry.
                    </p>
                  </div>
                  <div class="gap-section grid md:grid-cols-2">
                    <.input
                      id="ds-invoice-number"
                      name="specimen[invoice_number]"
                      label="Invoice number"
                      value="INV-1048"
                    />
                    <.input
                      type="select"
                      id="ds-place-of-supply"
                      name="specimen[place_of_supply]"
                      label="Place of supply"
                      value="Maharashtra"
                      options={["Gujarat", "Karnataka", "Maharashtra"]}
                    />
                    <.input
                      type="textarea"
                      id="ds-review-note"
                      name="specimen[review_note]"
                      label="Review note"
                      value="Place of supply confirmed from the delivery address."
                    />
                    <div class="space-y-block">
                      <.input
                        type="checkbox"
                        id="ds-reviewed"
                        name="specimen[reviewed]"
                        label="Human review completed"
                        value={true}
                      />
                      <.input
                        id="ds-disabled-field"
                        name="specimen[locked]"
                        label="Filed reference"
                        value="ARN pending"
                        disabled
                      />
                    </div>
                  </div>
                </.card>

                <div class="gap-section grid xl:grid-cols-2">
                  <.card id="ds-feedback" class="space-y-section">
                    <div>
                      <h3 class="text-h4 font-semibold">Feedback</h3>
                      <p class="text-ink-muted text-ui">
                        Inline messages reserve semantic color for actual state.
                      </p>
                    </div>
                    <div class="space-y-related">
                      <.callout kind="info" title="Draft prepared">
                        Return workings are available for inspection.
                      </.callout>
                      <.callout kind="warning" title="Review required">
                        Confirm place of supply before approval.
                      </.callout>
                    </div>
                  </.card>

                  <.card id="ds-overlays" class="space-y-section">
                    <div>
                      <h3 class="text-h4 font-semibold">Overlay</h3>
                      <p class="text-ink-muted text-ui">
                        Focus, dismissal, and keyboard behavior remain LiveView-owned.
                      </p>
                    </div>
                    <.button id="ds-open-modal" variant="outline" phx-click="open-design-modal">
                      Open modal
                    </.button>
                  </.card>
                </div>

                <.modal
                  :if={@show_modal}
                  id="ds-modal"
                  title="Review invoice"
                  on_close="close-design-modal"
                >
                  <div class="space-y-block">
                    <p class="text-body text-ink-muted">
                      The geometry follows Radix while focus and dismissal remain native LiveView behavior.
                    </p>
                    <div class="flex justify-end gap-2">
                      <.button variant="ghost" phx-click="close-design-modal">Cancel</.button>
                      <.button phx-click="close-design-modal">Confirm review</.button>
                    </div>
                  </div>
                </.modal>

                <div id="ds-cards" class="gap-section grid md:grid-cols-3">
                  <.stat_card label="Taxable value" figure>
                    {format_money(24_876_000, prefix: "₹")}
                    <:caption>Across 3 specimen invoices</:caption>
                  </.stat_card>
                  <.stat_card label="Output tax" figure>
                    {Nila.Formatters.format_money_with_paise(3_952_080)}
                    <:caption>Derived from the specimen register</:caption>
                  </.stat_card>
                  <.stat_card label="Human review">
                    1 remaining
                    <:caption>Place of supply needs confirmation</:caption>
                  </.stat_card>
                </div>
              </section>

              <section id="accounting" class="space-y-region scroll-mt-8">
                <.section_heading eyebrow="Accounting" title="Operational density keeps its hierarchy">
                  Exact values remain aligned and the unresolved line stays visible.
                </.section_heading>

                <.data_table id="ds-register-rows" rows={@rows} dense>
                  <:col :let={row} label="Invoice">
                    <span class="font-semibold">{row.invoice}</span>
                  </:col>
                  <:col :let={row} label="Party">{row.party}</:col>
                  <:col :let={row} label="Place of supply">{row.place}</:col>
                  <:col :let={row} label="Taxable value" align="right">
                    {format_money(row.taxable_paise, prefix: "₹")}
                  </:col>
                  <:col :let={row} label="Rate" align="right">{row.rate}</:col>
                  <:col :let={row} label="Review">
                    <.badge variant={row.variant}>{row.status}</.badge>
                  </:col>
                </.data_table>
              </section>

              <section id="workpaper" class="space-y-region scroll-mt-8">
                <.section_heading eyebrow="Workpaper" title="Outcome first, proof beneath">
                  A representative GST state built from production primitives.
                </.section_heading>

                <.card id="ds-workpaper-result" padding="none" class="overflow-hidden">
                  <div class="moonlight py-region px-6 lg:px-8">
                    <div class="gap-region grid lg:grid-cols-[minmax(0,1fr)_auto] lg:items-end">
                      <div class="space-y-block">
                        <div class="gap-related flex flex-wrap items-center">
                          <.badge variant="warning">1 review remaining</.badge>
                          <span class="text-ink-muted text-ui">Sales & GSTR-1 · May 2026</span>
                        </div>
                        <div class="space-y-related">
                          <h3 class="font-display text-h2 font-normal">
                            Draft prepared. One invoice needs you.
                          </h3>
                          <p class="text-body text-ink-muted max-w-2xl font-light">
                            Confirm place of supply for INV-1048 before approval. The remaining
                            specimen population is ready for inspection.
                          </p>
                        </div>
                      </div>
                      <.button>Review INV-1048</.button>
                    </div>
                  </div>

                  <div class="py-region space-y-section px-6 lg:px-8">
                    <div class="gap-section grid md:grid-cols-3">
                      <div class="space-y-related">
                        <p class="text-ink-subtle text-label font-semibold uppercase">Machine checks</p>
                        <p class="text-ui font-semibold">3 invoices classified</p>
                        <p class="text-ink-muted text-ui">One uncertain place-of-supply result.</p>
                      </div>
                      <div class="space-y-related">
                        <p class="text-ink-subtle text-label font-semibold uppercase">
                          Human assurance
                        </p>
                        <p class="text-ui font-semibold">2 of 3 reviewed</p>
                        <p class="text-ink-muted text-ui">Distinct-invoice decisions recorded.</p>
                      </div>
                      <div class="space-y-related">
                        <p class="text-ink-subtle text-label font-semibold uppercase">Approval</p>
                        <p class="text-ui font-semibold">Waiting</p>
                        <p class="text-ink-muted text-ui">Available after the review is resolved.</p>
                      </div>
                    </div>

                    <div class="border-base-300 pt-section border-t">
                      <.fold
                        id="ds-b2b-schedule"
                        open={MapSet.member?(@open_folds, "ds-b2b-schedule")}
                      >
                        <:summary>
                          <.fold_summary title="B2B schedule" tabular>
                            <:detail>
                              2 invoices · {format_money(21_260_000, prefix: "₹")} taxable value
                            </:detail>
                            <:status>
                              <.badge variant="success">Prepared</.badge>
                            </:status>
                          </.fold_summary>
                        </:summary>
                        <div class="pt-section">
                          <.data_table id="ds-b2b-rows" rows={Enum.take(@rows, 2)} dense>
                            <:col :let={row} label="Invoice">{row.invoice}</:col>
                            <:col :let={row} label="Party">{row.party}</:col>
                            <:col :let={row} label="Taxable value" align="right">
                              {format_money(row.taxable_paise, prefix: "₹")}
                            </:col>
                            <:col :let={row} label="Rate" align="right">{row.rate}</:col>
                          </.data_table>
                        </div>
                      </.fold>
                    </div>

                    <div class="border-base-300 pt-section border-t">
                      <.fold
                        id="ds-rate-summary"
                        open={MapSet.member?(@open_folds, "ds-rate-summary")}
                      >
                        <:summary>
                          <.fold_summary title="Rate summary" tabular>
                            <:detail>2 rates · derived from the specimen register</:detail>
                            <:status>
                              <.badge variant="neutral">Derived</.badge>
                            </:status>
                          </.fold_summary>
                        </:summary>
                        <p class="pt-section text-body text-ink-muted font-light">
                          Derived from the same specimen register. This is provenance, not an
                          independently corroborated control.
                        </p>
                      </.fold>
                    </div>
                  </div>
                </.card>
              </section>
            </div>
          </main>
        </div>
      </Layouts.app>
      """
    end

    attr :eyebrow, :string, required: true
    attr :title, :string, required: true
    slot :inner_block, required: true

    defp section_heading(assigns) do
      ~H"""
      <div class="space-y-related">
        <p class="text-label text-moon font-semibold uppercase">{@eyebrow}</p>
        <h2 class="font-display text-h3 font-normal">{@title}</h2>
        <p class="text-body text-ink-muted max-w-2xl font-light">{render_slot(@inner_block)}</p>
      </div>
      """
    end

    attr :role, :string, required: true
    attr :class, :string, required: true
    slot :inner_block, required: true

    defp type_sample(assigns) do
      ~H"""
      <div class="space-y-related">
        <p class="text-ink-subtle text-label font-semibold uppercase">{@role}</p>
        <p class={@class}>{render_slot(@inner_block)}</p>
      </div>
      """
    end

    attr :name, :string, required: true
    attr :class, :string, required: true

    defp swatch(assigns) do
      ~H"""
      <div class={["rounded-field flex h-20 items-end p-3", @class]}>
        <span class="text-ui font-semibold">{@name}</span>
      </div>
      """
    end

    attr :name, :string, required: true
    attr :width, :string, required: true

    defp spacing_sample(assigns) do
      ~H"""
      <div class="gap-block grid grid-cols-[5rem_minmax(0,1fr)] items-center">
        <span class="text-ui font-medium">{@name}</span>
        <div class="bg-base-200 rounded-field h-6">
          <div class={["bg-primary rounded-field h-full", @width]}></div>
        </div>
      </div>
      """
    end
  end
end
