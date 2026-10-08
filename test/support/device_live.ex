defmodule DIYWeb.DeviceLive do
  @moduledoc """
  A LiveView for the tests of the protocol of the build on the device
  (`DIYWeb.Device`), with no pages of the app: "edit" makes a new build
  with the next revision, and the page shows the build.
  """
  use DIYWeb, :live_view

  on_mount DIYWeb.Device

  alias DIY.Build

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_event(_event, _params, %{assigns: %{build: nil}} = socket), do: {:noreply, socket}

  def handle_event("edit", _params, socket) do
    {:noreply, DIYWeb.Device.put_build(socket, Build.change(socket.assigns.build, & &1))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="device" phx-hook="Device"></div>
    <p id="build">
      {if @build, do: "#{@build.revision}:#{@build.door}:#{@build.stamp}", else: "waiting"}
    </p>
    <div id="flash-info">{Phoenix.Flash.get(@flash, :info)}</div>
    <div id="flash-error">{Phoenix.Flash.get(@flash, :error)}</div>
    """
  end
end
