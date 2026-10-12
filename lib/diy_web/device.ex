defmodule DIYWeb.Device do
  @moduledoc """
  The LiveView part of the protocol of the build on the device. The hook
  `Device` of the page (`assets/js/device.js`) is the device part. The
  TLA+ model `specs/Device.tla` checks the protocol: each event here is an
  action of the model.

  A LiveView with `on_mount DIYWeb.Device` gets these assigns:

  - `:build`: the `DIY.Build` of the page. It is `nil` until the hook sends
    the stored build.
  - `:device`: the state of the protocol:
    - `restoring`: the LiveView waits for the stored build.
    - `base`: the stamp of the stored build that the next save comes from.
    - `epoch`: a number for the builds that the page shows. A new LiveView
      has a new epoch, and the epoch changes when the page takes a build
      from outside. An answer to a save of an old epoch changes nothing.
    - `saved`: the stamp of the last build that the device saved.
    - `backup`: the next save keeps a copy of the stored text, because the
      page cannot read it.
    - `unreadable`: the stamp of that text. A failed save on it asks for the
      copy again.
    - `newer`: the stored build comes from a newer version of the app. The
      page does not write over it.

  A LiveView changes the build only with `put_build/2`. When a build comes
  from the device (a restore, a conflict, or a different tab), the protocol
  calls `build_changed(socket)` of the LiveView, if it has one, before the
  next render.

  The notices of the protocol are in the language of the page.
  """
  use Gettext, backend: DIY.Gettext
  import Phoenix.Component, only: [assign: 3]

  alias DIY.Build
  alias Phoenix.LiveView

  # The largest text of a build that the page takes from the device.
  @max_text 512 * 1024

  @doc false
  def on_mount(:default, _params, _session, socket) do
    device = %{
      restoring: true,
      base: "",
      epoch: new_epoch(),
      saved: nil,
      backup: false,
      unreadable: nil,
      newer: false
    }

    socket = socket |> assign(:build, nil) |> assign(:device, device)
    {:cont, LiveView.attach_hook(socket, :device, :handle_event, &handle_event/3)}
  end

  defp new_epoch, do: System.unique_integer([:positive, :monotonic])

  @doc """
  Shows the new build, and sends it to the device (Edit of the model). The
  next save comes from this build.
  """
  def put_build(%{assigns: %{device: %{newer: true}}} = socket, %Build{}) do
    LiveView.put_flash(socket, :error, newer())
  end

  def put_build(socket, %Build{} = build) do
    device = socket.assigns.device
    text = Build.to_json(build)

    if byte_size(text) > @max_text do
      LiveView.put_flash(
        socket,
        :error,
        gettext("The build is too large for this device. Remove some items.")
      )
    else
      save(socket, build, text, device)
    end
  end

  defp save(socket, build, text, device) do
    socket
    |> assign(:build, build)
    |> assign(:device, %{device | base: build.stamp, backup: false})
    |> LiveView.push_event("device:save", %{
      text: text,
      base: device.base,
      epoch: device.epoch,
      backup: device.backup
    })
  end

  defp newer,
    do:
      gettext(
        "The build on this device comes from a newer version of the app. Load the page again."
      )

  @doc "True when the device has the build of the page."
  def saved?(%{build: %Build{stamp: stamp}, device: %{saved: stamp}}), do: true
  def saved?(_assigns), do: false

  defguardp text?(text) when is_nil(text) or (is_binary(text) and byte_size(text) <= @max_text)

  @doc false
  # Restore: only the first one, for a LiveView that waits.
  def handle_event("device:restore", %{"text" => text, "stamp" => stamp}, socket)
      when text?(text) and is_binary(stamp) do
    if socket.assigns.device.restoring do
      device = %{socket.assigns.device | restoring: false, saved: stamp}
      {:halt, socket |> assign(:device, device) |> take(text, stamp, false)}
    else
      {:halt, socket}
    end
  end

  # A restore that the page cannot read (for example a text that is not a
  # string, or a large text): a new build, as for an unreadable text.
  def handle_event("device:restore", %{"stamp" => stamp}, socket) when is_binary(stamp) do
    if socket.assigns.device.restoring do
      device = %{socket.assigns.device | restoring: false, saved: stamp}
      {:halt, socket |> assign(:device, device) |> take(:unreadable, stamp, false)}
    else
      {:halt, socket}
    end
  end

  # A save: the store has the build of the page now, not an unreadable text.
  def handle_event("device:saved", %{"stamp" => stamp}, socket) when is_binary(stamp) do
    {:halt, assign(socket, :device, %{socket.assigns.device | saved: stamp, unreadable: nil})}
  end

  def handle_event(
        "device:conflict",
        %{"text" => text, "stamp" => stamp, "epoch" => epoch},
        socket
      )
      when text?(text) and is_binary(stamp) and is_integer(epoch) do
    device = socket.assigns.device

    cond do
      epoch != device.epoch or device.restoring ->
        {:halt, socket}

      # The store is empty (the user removed the data of the site): save the
      # build again on it.
      is_nil(text) ->
        socket = assign(socket, :device, %{device | base: stamp, epoch: new_epoch()})
        {:halt, put_build(socket, socket.assigns.build)}

      true ->
        {:halt,
         socket
         |> take(text, stamp, true)
         |> LiveView.put_flash(
           :info,
           gettext("A different tab changed this build. This page shows that build now.")
         )}
    end
  end

  # A write of a different tab: a newer build shows at once.
  def handle_event("device:changed", %{"text" => text, "stamp" => stamp}, socket)
      when text?(text) and is_binary(stamp) do
    with false <- socket.assigns.device.restoring,
         {:ok, %Build{revision: revision}} <- Build.from_json(text),
         true <- revision > socket.assigns.build.revision do
      {:halt, take(socket, text, stamp, true)}
    else
      _ -> {:halt, socket}
    end
  end

  # A failed save: keep the build. The next save comes from the stored
  # build, and has all the build. If the store still has a text that the
  # page cannot read, the next save keeps a copy of it.
  def handle_event(
        "device:error",
        %{"error" => error, "stamp" => stamp, "epoch" => epoch},
        socket
      )
      when is_binary(error) and is_binary(stamp) and is_integer(epoch) do
    device = socket.assigns.device

    socket =
      if epoch == device.epoch and not device.restoring do
        backup = device.backup or stamp == device.unreadable
        assign(socket, :device, %{device | base: stamp, epoch: new_epoch(), backup: backup})
      else
        socket
      end

    {:halt,
     LiveView.put_flash(
       socket,
       :error,
       gettext("This device did not save the build: %{error}", error: error)
     )}
  end

  def handle_event("device:" <> _event, _params, socket), do: {:halt, socket}
  def handle_event(_event, _params, socket), do: {:cont, socket}

  # Shows a stored build. outside: the build comes from outside, in a new
  # epoch. A text that is not a build gives a new build: the next save keeps
  # a copy of the text, and writes over it. A build of a newer version
  # stops the saves.
  defp take(socket, text, stamp, outside) do
    socket |> take_build(text, stamp, outside) |> changed()
  end

  defp changed(%{view: view} = socket) do
    if function_exported?(view, :build_changed, 1), do: view.build_changed(socket), else: socket
  end

  defp take_build(socket, text, stamp, outside) do
    device = %{socket.assigns.device | base: stamp}
    device = if outside, do: %{device | epoch: new_epoch()}, else: device
    current = Build.version()

    case {text, Build.from_json(text)} do
      {_text, {:ok, build}} ->
        socket |> assign(:device, %{device | newer: false}) |> assign(:build, build)

      {nil, _error} ->
        socket |> assign(:device, device) |> assign(:build, Build.new())

      {_text, {:error, {:version, version}}} when version > current ->
        socket
        |> assign(:device, %{device | newer: true})
        |> assign(:build, Build.new())
        |> LiveView.put_flash(:error, newer())

      {_text, {:error, _reason}} ->
        socket
        |> assign(:device, %{device | backup: true, unreadable: stamp})
        |> assign(:build, Build.new())
        |> LiveView.put_flash(
          :info,
          gettext(
            "The page cannot read the build on this device. It starts a new build, and keeps a copy of the old one."
          )
        )
    end
  end
end
