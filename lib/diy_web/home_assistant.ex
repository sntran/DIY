defmodule DIYWeb.HomeAssistant do
  @moduledoc """
  The LiveView part of the link to Home Assistant. The hook `HomeAssistant`
  of the page (`assets/js/home_assistant.js`) does the sign-in and keeps
  the tokens on the device: the server never sees them. The TLA+ model
  `specs/HomeAssistant.tla` checks the rules of the hook.

  A LiveView with `on_mount DIYWeb.HomeAssistant` gets the assign `:ha`:

  - `state`: `loading` (the hook did not tell yet), `none`, `signing_in`,
    `connecting`, `connected`, `offline` or `signed_out`;
  - `url`: the address of Home Assistant;
  - `name` and `version`: the name of the home and the version of Home
    Assistant, when it is connected;
  - `error`: why the last step did not work (`message/1`), or `nil`.

  The events of the page: `ha_connect` (with the address) and
  `ha_disconnect`.
  """
  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.LiveView

  @states ~w(none signing_in connecting connected offline signed_out)
  @errors ~w(url blocked state denied token unreachable storage signed_out)

  # The longest address, and the longest name or version, that the page
  # takes from the hook.
  @max_url 2048
  @max_text 200

  @doc false
  def on_mount(:default, _params, _session, socket) do
    socket =
      assign(socket, :ha, %{state: "loading", url: nil, name: nil, version: nil, error: nil})

    {:cont, LiveView.attach_hook(socket, :home_assistant, :handle_event, &handle_event/3)}
  end

  @doc false
  def handle_event("ha:status", %{"state" => state} = params, socket) when state in @states do
    ha = %{
      state: state,
      url: text(params["url"], @max_url),
      name: text(params["name"], @max_text),
      version: text(params["version"], @max_text),
      error: if(params["error"] in @errors, do: params["error"])
    }

    {:halt, assign(socket, :ha, ha)}
  end

  def handle_event("ha:status", _params, socket), do: {:halt, socket}

  def handle_event("ha_connect", %{"url" => text}, socket) do
    case address(text) do
      {:ok, url} ->
        {:halt, LiveView.push_event(socket, "ha:connect", %{url: url})}

      :error ->
        {:halt, assign(socket, :ha, %{socket.assigns.ha | error: "url"})}
    end
  end

  def handle_event("ha_disconnect", _params, socket),
    do: {:halt, LiveView.push_event(socket, "ha:disconnect", %{})}

  def handle_event(_event, _params, socket), do: {:cont, socket}

  defp text(value, max) when is_binary(value) and byte_size(value) <= max, do: value
  defp text(_value, _max), do: nil

  @doc """
  The address of Home Assistant in a text of the person. It has the
  scheme (`http` or `https`), the host, the port and the path, with no
  `/` at the end. The hook makes the same address (`address` in
  `assets/js/home_assistant.js`).
  """
  def address(text) when is_binary(text) and byte_size(text) <= @max_url do
    case URI.new(String.trim(text)) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        host = String.downcase(host)
        host = if String.contains?(host, ":"), do: "[#{host}]", else: host
        port = if uri.port == URI.default_port(scheme), do: "", else: ":#{uri.port}"
        path = String.trim_trailing(uri.path || "", "/")
        {:ok, "#{scheme}://#{host}#{port}#{path}"}

      _ ->
        :error
    end
  end

  def address(_text), do: :error

  @doc "The state of the link, in words, or `nil` while the page waits for the hook."
  def status(%{state: "loading"}), do: nil
  def status(%{state: "none"}), do: "Not connected."
  def status(%{state: "signing_in"}), do: "The app gets the sign-in from Home Assistant."

  def status(%{state: "connecting", url: url}),
    do: "The app connects to Home Assistant at #{url}."

  def status(%{state: "connected", name: name, version: version, url: url}),
    do: "Connected to #{name || "Home Assistant"} (Home Assistant #{version}) at #{url}."

  def status(%{state: "offline", url: url}),
    do: "Home Assistant at #{url} does not answer now. The app tries again."

  def status(%{state: "signed_out"}), do: "Not connected."

  @doc "Why the last step did not work, in words."
  def message("url"),
    do: "Give the address of your Home Assistant, for example https://home.example.com."

  def message("blocked"),
    do:
      "This page uses HTTPS, so the browser blocks an http address. Use the HTTPS address of your Home Assistant."

  def message("state"), do: "The sign-in did not finish. Try again."
  def message("denied"), do: "Home Assistant did not give access."
  def message("token"), do: "Home Assistant did not accept the sign-in. Try again."

  def message("unreachable"),
    do:
      "The app cannot reach Home Assistant at this address. Make sure that this device can open it."

  def message("storage"),
    do: "This browser cannot keep the sign-in. Make sure that the storage of the site is on."

  def message("signed_out"), do: "Home Assistant ended the sign-in. Connect again."
end
