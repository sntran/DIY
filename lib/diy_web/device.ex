defmodule DIYWeb.Device do
  @moduledoc """
  The LiveView part of the protocol of the build on the device. The hook
  `Device` of the page (`assets/js/device.js`) is the device part. The
  TLA+ model `specs/Device.tla` checks the protocol with two and three tabs.

  A LiveView with `on_mount DIYWeb.Device` gets these assigns:

  - `:build`: the `DIY.Build` of the page. It is `nil` until the hook sends
    the stored build.
  - `:device`: the state of the protocol:
    - `base`: the stamp of the stored build that the next save comes from.
    - `epoch`: the number of builds that the page took from outside (from
      a conflict or from a different tab). A conflict of a save of an old
      epoch changes no build.
    - `latest`: the newest stored build that the page knows, as
      `{revision, text, stamp}`.
    - `saved`: the stamp of the last build that the device saved.

  A LiveView changes the build only with `put_build/2`.
  """
  import Phoenix.Component, only: [assign: 3]

  alias DIY.Build
  alias Phoenix.LiveView

  @doc false
  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:build, nil)
      |> assign(:device, %{base: "", epoch: 0, latest: {0, nil, ""}, saved: nil})

    {:cont, LiveView.attach_hook(socket, :device, :handle_event, &handle_event/3)}
  end

  @doc """
  Shows the new build, and sends it to the device. The next save comes from
  this build.
  """
  def put_build(socket, %Build{} = build) do
    %{base: base, epoch: epoch} = device = socket.assigns.device

    socket
    |> assign(:build, build)
    |> assign(:device, %{device | base: build.stamp})
    |> LiveView.push_event("device:save", %{text: Build.to_json(build), base: base, epoch: epoch})
  end

  @doc "True when the device has the build of the page."
  def saved?(%{build: %Build{stamp: stamp}, device: %{saved: stamp}}), do: true
  def saved?(_assigns), do: false

  @doc false
  def handle_event("device:restore", %{"text" => text, "stamp" => stamp}, socket)
      when (is_binary(text) or is_nil(text)) and is_binary(stamp) do
    stored = stored(text, stamp)
    device = %{socket.assigns.device | epoch: 0, latest: stored, saved: stamp}
    {:halt, socket |> assign(:device, device) |> adopt(stored)}
  end

  def handle_event("device:saved", %{"stamp" => stamp}, socket) when is_binary(stamp) do
    {:halt, assign(socket, :device, %{socket.assigns.device | saved: stamp})}
  end

  def handle_event(
        "device:conflict",
        %{"text" => text, "stamp" => stamp, "epoch" => epoch},
        socket
      )
      when (is_binary(text) or is_nil(text)) and is_binary(stamp) and is_integer(epoch) do
    device = socket.assigns.device
    latest = newer(device.latest, stored(text, stamp))
    socket = assign(socket, :device, %{device | latest: latest})

    if epoch == device.epoch do
      {:halt,
       socket
       |> take(latest)
       |> LiveView.put_flash(
         :info,
         "A different tab changed this build. This page shows that build now."
       )}
    else
      {:halt, socket}
    end
  end

  def handle_event("device:changed", %{"text" => text, "stamp" => stamp}, socket)
      when (is_binary(text) or is_nil(text)) and is_binary(stamp) do
    device = socket.assigns.device
    {revision, _text, _stamp} = changed = stored(text, stamp)
    socket = assign(socket, :device, %{device | latest: newer(device.latest, changed)})

    if revision > revision(socket.assigns.build),
      do: {:halt, take(socket, changed)},
      else: {:halt, socket}
  end

  def handle_event("device:error", %{"error" => error}, socket) when is_binary(error) do
    {:halt, LiveView.put_flash(socket, :error, "This device did not save the build: #{error}")}
  end

  def handle_event("device:" <> _event, _params, socket), do: {:halt, socket}
  def handle_event(_event, _params, socket), do: {:cont, socket}

  # A stored text, as {revision, text, stamp}. A text that is not a build has
  # the revision 0.
  defp stored(text, stamp) do
    case Build.from_json(text) do
      {:ok, build} -> {build.revision, text, stamp}
      {:error, _reason} -> {0, text, stamp}
    end
  end

  defp newer({revision, _, _} = latest, {other, _, _}) when revision >= other, do: latest
  defp newer(_latest, other), do: other

  defp revision(%Build{revision: revision}), do: revision
  defp revision(nil), do: 0

  # Shows a stored build that comes from outside: a new epoch.
  defp take(socket, stored) do
    socket
    |> assign(:device, %{socket.assigns.device | epoch: socket.assigns.device.epoch + 1})
    |> adopt(stored)
  end

  # Shows a stored build. A text that is not a build gives a new build, which
  # the next save writes over the text.
  defp adopt(socket, {_revision, text, stamp}) do
    socket = assign(socket, :device, %{socket.assigns.device | base: stamp})

    case {text, Build.from_json(text)} do
      {_text, {:ok, build}} ->
        assign(socket, :build, build)

      {nil, _error} ->
        assign(socket, :build, Build.new())

      {_text, {:error, _reason}} ->
        socket
        |> assign(:build, Build.new())
        |> LiveView.put_flash(
          :info,
          "The build on this device is from a different version of the app. This page starts a new build."
        )
    end
  end
end
