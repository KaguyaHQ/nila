defmodule NilaWeb.AssistantLive do
  use NilaWeb, :live_view

  alias Nila.Assistant
  alias Nila.Assistant.RateLimiter

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Assistant")
      |> assign(:turns, [])
      |> assign(:pending?, false)
      |> assign(:draft, "")
      |> assign(:streaming_text, "")
      |> assign(:trace_steps, [])
      |> assign(:trace_topic, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("send", %{"message" => raw}, socket) do
    text = String.trim(raw || "")

    cond do
      text == "" ->
        {:noreply, socket}

      socket.assigns.pending? ->
        {:noreply, socket}

      true ->
        user = socket.assigns.current_scope.user

        case RateLimiter.check_user_message(user) do
          :allow ->
            user_turn = %{
              role: :user,
              text: text,
              id: System.unique_integer([:positive])
            }

            turns = socket.assigns.turns ++ [user_turn]
            scope = socket.assigns.current_scope
            trace_topic = "assistant:trace:#{System.unique_integer([:positive])}"
            Phoenix.PubSub.subscribe(Nila.PubSub, trace_topic)

            socket =
              socket
              |> assign(:turns, turns)
              |> assign(:pending?, true)
              |> assign(:draft, "")
              |> assign(:streaming_text, "")
              |> assign(:trace_steps, [])
              |> assign(:trace_topic, trace_topic)
              |> start_async(:assistant_reply, fn ->
                Assistant.chat(scope, turns, trace_topic: trace_topic)
              end)

            {:noreply, socket}

          :deny ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Slow down — you're sending messages too quickly. Try again in a moment."
             )}
        end
    end
  end

  def handle_event("draft", %{"message" => text}, socket) do
    {:noreply, assign(socket, :draft, text || "")}
  end

  def handle_event("prefill", %{"text" => text}, socket) do
    {:noreply, assign(socket, :draft, text || "")}
  end

  def handle_event("stop", _params, socket) do
    unsubscribe_trace(socket.assigns.trace_topic)

    {:noreply,
     socket
     |> cancel_async(:assistant_reply)
     |> assign(:pending?, false)
     |> assign(:streaming_text, "")
     |> assign(:trace_steps, [])
     |> assign(:trace_topic, nil)}
  end

  @impl true
  def handle_info({:assistant_trace, event}, socket) do
    {:noreply, assign(socket, :trace_steps, upsert_trace_step(socket.assigns.trace_steps, event))}
  end

  def handle_info({:assistant_delta, text}, socket) do
    {:noreply, assign(socket, :streaming_text, socket.assigns.streaming_text <> text)}
  end

  @impl true
  def handle_async(:assistant_reply, {:ok, {:ok, %{turn: turn}}}, socket) do
    unsubscribe_trace(socket.assigns.trace_topic)
    turn = put_citations(turn)

    {:noreply,
     socket
     |> assign(:turns, socket.assigns.turns ++ [turn])
     |> assign(:pending?, false)
     |> assign(:streaming_text, "")
     |> assign(:trace_topic, nil)}
  end

  def handle_async(:assistant_reply, {:ok, {:error, reason}}, socket) do
    unsubscribe_trace(socket.assigns.trace_topic)

    {:noreply,
     socket
     |> assign(:pending?, false)
     |> assign(:streaming_text, "")
     |> assign(:trace_topic, nil)
     |> put_flash(:error, friendly_error(reason))}
  end

  def handle_async(:assistant_reply, {:exit, {:shutdown, :cancel}}, socket) do
    {:noreply,
     socket
     |> assign(:pending?, false)
     |> assign(:trace_topic, nil)}
  end

  def handle_async(:assistant_reply, {:exit, _reason}, socket) do
    unsubscribe_trace(socket.assigns.trace_topic)

    {:noreply,
     socket
     |> assign(:pending?, false)
     |> assign(:streaming_text, "")
     |> assign(:trace_topic, nil)
     |> put_flash(:error, "Assistant crashed. Try again.")}
  end

  defp friendly_error(:rate_limited),
    do: "The model API is rate-limiting us. Try again in a minute."

  defp friendly_error(:upstream_overloaded),
    do: "The model API is busy. Try again shortly."

  defp friendly_error(:network),
    do: "Couldn't reach the assistant. Check your network and try again."

  defp friendly_error(:tool_loop_exceeded),
    do: "The assistant got stuck in a tool loop. Try rephrasing your question."

  defp friendly_error(:bad_request),
    do: "The assistant couldn't process that request."

  defp friendly_error(_),
    do: "Something went wrong talking to the assistant."

  defp unsubscribe_trace(nil), do: :ok
  defp unsubscribe_trace(topic), do: Phoenix.PubSub.unsubscribe(Nila.PubSub, topic)

  defp upsert_trace_step(steps, event) do
    event = Map.put_new(event, :elapsed_ms, nil)

    if Enum.any?(steps, &(&1.id == event.id)) do
      Enum.map(steps, fn step ->
        if step.id == event.id, do: Map.merge(step, event), else: step
      end)
    else
      steps ++ [event]
    end
  end

  defp put_citations(turn) do
    Map.put(turn, :citations, citations_for(turn[:attachments] || []))
  end

  defp citations_for(attachments) do
    attachments
    |> Enum.flat_map(fn {_tag, items} -> items end)
    |> Enum.reduce([], fn item, citations ->
      url = item[:url]
      label = item[:filename] || item[:description] || "Record"

      if url && Enum.all?(citations, &(&1.url != url)) do
        citations ++ [%{index: length(citations) + 1, label: label, url: url}]
      else
        citations
      end
    end)
  end

  defp trace_elapsed(nil), do: ""
  defp trace_elapsed(ms) when ms < 1000, do: "#{ms} ms"
  defp trace_elapsed(ms), do: "#{Float.round(ms / 1000, 1)} s"

  attr :doc, :map, required: true

  def document_card(assigns) do
    ~H"""
    <div class="flex flex-col gap-1 rounded-box border border-base-300 bg-base-100 p-3 text-left text-small shadow-moon">
      <div class="flex items-center justify-between gap-2">
        <span class="truncate font-medium text-base-content">
          {@doc.filename || "(unnamed)"}
        </span>
        <span class="rounded-full bg-base-200 px-2 py-0.5 text-label font-medium uppercase text-base-content/70">
          {@doc.status}
        </span>
      </div>
      <div :if={@doc.document_type} class="text-fine text-base-content/70">
        {@doc.document_type}
      </div>
      <div class="flex items-center justify-between text-micro text-base-content/60">
        <span :if={@doc.uploaded_at}>{@doc.uploaded_at}</span>
      </div>
    </div>
    """
  end

  attr :draft, :string, required: true
  attr :pending?, :boolean, required: true

  def composer(assigns) do
    ~H"""
    <form
      id="assistant-form"
      phx-submit="send"
      phx-change="draft"
      class="flex w-full items-center gap-3 rounded-box border border-base-300 bg-base-100 px-4 py-3 shadow-moon"
    >
      <textarea
        id="assistant-input"
        name="message"
        rows="1"
        placeholder="Ask about a document you've uploaded…"
        phx-hook="SubmitOnEnter"
        disabled={@pending?}
        class="block max-h-48 flex-1 resize-none overflow-y-hidden border-0 bg-transparent text-body text-base-content placeholder:text-base-content/50 focus:outline-none focus:ring-0 disabled:opacity-50"
      >{@draft}</textarea>
      <.button
        :if={!@pending?}
        type="submit"
        disabled={String.trim(@draft) == ""}
        class="disabled:cursor-not-allowed"
      >
        <.icon name="hero-paper-airplane" class="size-4" />
        <span>Send</span>
      </.button>
      <button
        :if={@pending?}
        id="assistant-stop"
        type="button"
        phx-click="stop"
        class="inline-flex h-10 items-center justify-center gap-2 rounded-field bg-error px-3 text-small font-medium text-error-content shadow-moon transition hover:bg-error/90"
      >
        <.icon name="hero-stop" class="size-4" />
        <span>Stop</span>
      </button>
    </form>
    """
  end

  def example_chips(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center justify-center gap-2">
      <button
        :for={chip <- example_prompts()}
        type="button"
        id={"assistant-example-#{chip.id}"}
        phx-click={
          JS.push("prefill", value: %{text: chip.text})
          |> JS.dispatch("nila:assistant-prefill",
            to: "#assistant-input",
            detail: %{text: chip.text}
          )
        }
        class="inline-flex items-center gap-1.5 rounded-field border border-base-300 bg-base-100 px-3 py-1.5 text-small font-medium text-base-content/80 shadow-moon transition hover:border-base-content/20 hover:bg-base-200"
      >
        <.icon name={chip.icon} class="size-4 text-base-content/50" />
        {chip.label}
      </button>
    </div>
    """
  end

  defp example_prompts do
    [
      %{
        id: "recent-documents",
        label: "Recent documents",
        text: "Show me my recent documents",
        icon: "hero-document-text"
      },
      %{
        id: "pending-review",
        label: "Pending review",
        text: "Which documents are pending review?",
        icon: "hero-clock"
      }
    ]
  end
end
