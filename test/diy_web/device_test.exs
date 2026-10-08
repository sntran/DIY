defmodule DIYWeb.DeviceTest do
  use DIYWeb.ConnCase, async: true
  use ExUnitProperties

  import Phoenix.LiveViewTest

  alias DIY.Build

  defp stored(build), do: %{"text" => Build.to_json(build), "stamp" => build.stamp}

  defp door(door) do
    {:ok, build} = Build.choose_door(Build.new(), door)
    build
  end

  defp mount(conn), do: elem(live_isolated(conn, DIYWeb.DeviceLive), 1)

  defp open(conn, payload) do
    view = mount(conn)
    render_hook(view, "device:restore", payload)
    view
  end

  defp empty, do: %{"text" => nil, "stamp" => ""}

  defp edit(view), do: render_click(view, "edit", %{})

  # The build and the state of the protocol of a LiveView.
  defp build(view), do: :sys.get_state(view.pid).socket.assigns.build
  defp device(view), do: :sys.get_state(view.pid).socket.assigns.device

  defp flash(view, kind), do: view |> element("#flash-#{kind}") |> render()

  # The save that the LiveView pushed last.
  defp save(view) do
    assert_push_event view, "device:save", save
    save
  end

  test "the page waits for the restore, and a click before it changes nothing", %{conn: conn} do
    view = mount(conn)
    assert render(view) =~ "waiting"
    edit(view)
    refute_push_event view, "device:save", _save
  end

  test "a restore shows the stored build, and the next save comes from it", %{conn: conn} do
    first = door("planning")
    view = open(conn, stored(first))
    assert build(view) == first
    assert DIYWeb.Device.saved?(%{build: build(view), device: device(view)})

    edit(view)
    assert %{base: base, backup: false, text: text} = save(view)
    assert base == first.stamp
    {:ok, next} = Build.from_json(text)
    assert next.revision == 2
    refute DIYWeb.Device.saved?(%{build: build(view), device: device(view)})

    render_hook(view, "device:saved", %{"stamp" => next.stamp})
    assert DIYWeb.Device.saved?(%{build: build(view), device: device(view)})
  end

  test "a text that is not a build gives a new build, and the next save keeps a copy", %{
    conn: conn
  } do
    view = open(conn, %{"text" => "not a build", "stamp" => "x"})
    assert flash(view, :info) =~ "keeps a copy of the old one"
    assert build(view).revision == 0

    edit(view)
    assert %{base: "x", backup: true} = save(view)

    edit(view)
    assert %{backup: false} = save(view)
  end

  test "a failed save on an unreadable text asks for the copy again", %{conn: conn} do
    view = open(conn, %{"text" => "not a build", "stamp" => "x"})
    edit(view)
    assert %{backup: true, epoch: epoch} = save(view)

    render_hook(view, "device:error", %{"error" => "full", "stamp" => "x", "epoch" => epoch})
    edit(view)
    assert %{backup: true, base: "x", epoch: epoch} = save(view)

    # A failed save on a different stored build does not ask for a copy.
    render_hook(view, "device:error", %{"error" => "full", "stamp" => "y", "epoch" => epoch})
    edit(view)
    assert %{backup: false, base: "y", epoch: epoch} = save(view)

    # After a save, the store has no unreadable text.
    render_hook(view, "device:saved", %{"stamp" => "z"})
    render_hook(view, "device:error", %{"error" => "full", "stamp" => "x", "epoch" => epoch})
    edit(view)
    assert %{backup: false} = save(view)
  end

  test "a restore that is not a text, or is too large, gives a new build with a copy", %{
    conn: conn
  } do
    for text <- [%{"version" => 1}, String.duplicate("x", 512 * 1024 + 1)] do
      view = open(conn, %{"text" => text, "stamp" => "x"})
      assert flash(view, :info) =~ "keeps a copy of the old one"
      edit(view)
      assert %{base: "x", backup: true} = save(view)

      # A second restore changes nothing.
      before = build(view)
      render_hook(view, "device:restore", %{"text" => 5, "stamp" => "y"})
      render_hook(view, "device:restore", stored(door("my_house")))
      assert build(view) == before
    end
  end

  test "a build of an old version is a text that the page cannot read", %{conn: conn} do
    view = open(conn, %{"text" => ~s({"version": 0}), "stamp" => "x"})
    assert flash(view, :info) =~ "keeps a copy of the old one"
  end

  test "a build of a newer version stops the saves, until a build of this version", %{
    conn: conn
  } do
    view = open(conn, %{"text" => ~s({"version": 2}), "stamp" => "x"})
    assert flash(view, :error) =~ "comes from a newer version"

    edit(view)
    refute_push_event view, "device:save", _save

    render_hook(view, "device:changed", stored(door("planning")))
    edit(view)
    assert %{text: _} = save(view)
  end

  test "a build that is too large for the device does not go to it" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        build: Build.new(),
        device: %{base: "", epoch: 1, backup: false, newer: false}
      }
    }

    large = %Build{revision: 1, stamp: String.duplicate("x", 512 * 1024)}
    socket = DIYWeb.Device.put_build(socket, large)
    assert socket.assigns.build == Build.new()
    assert socket.assigns.flash["error"] =~ "too large"
  end

  test "a conflict of the epoch shows the stored build, in a new epoch", %{conn: conn} do
    view = open(conn, empty())
    edit(view)
    %{epoch: epoch} = save(view)

    other = door("planning")
    render_hook(view, "device:conflict", Map.put(stored(other), "epoch", epoch))
    assert flash(view, :info) =~ "A different tab changed this build"
    assert build(view) == other

    edit(view)
    assert %{base: base, epoch: new_epoch} = save(view)
    assert base == other.stamp
    assert new_epoch != epoch
  end

  test "a conflict of an old epoch changes no build", %{conn: conn} do
    view = open(conn, empty())
    edit(view)
    %{epoch: epoch} = save(view)
    mine = build(view)
    render_hook(view, "device:conflict", Map.put(stored(door("planning")), "epoch", epoch + 1))
    refute flash(view, :info) =~ "A different tab changed this build"
    assert build(view) == mine
  end

  test "a conflict with an empty store saves the build again on it", %{conn: conn} do
    view = open(conn, empty())
    edit(view)
    %{text: text, epoch: epoch} = save(view)

    render_hook(view, "device:conflict", %{"text" => nil, "stamp" => "", "epoch" => epoch})
    assert %{text: ^text, base: "", epoch: new_epoch} = save(view)
    assert new_epoch != epoch
  end

  test "a conflict or an error before the restore changes nothing", %{conn: conn} do
    view = mount(conn)
    render_hook(view, "device:conflict", Map.put(stored(door("planning")), "epoch", 1))
    render_hook(view, "device:error", %{"error" => "x", "stamp" => "", "epoch" => 1})
    assert build(view) == nil
  end

  test "a newer build of a different tab shows at once", %{conn: conn} do
    view = open(conn, empty())
    other = door("planning")
    render_hook(view, "device:changed", stored(other))
    assert build(view) == other

    edit(view)
    assert %{base: base} = save(view)
    assert base == other.stamp
  end

  test "an older build, a text that is not a build, or a write before the restore changes nothing",
       %{conn: conn} do
    mine = Build.change(door("my_house"), & &1)
    view = open(conn, stored(mine))
    render_hook(view, "device:changed", stored(door("planning")))
    render_hook(view, "device:changed", %{"text" => "x", "stamp" => ""})
    assert build(view) == mine

    waiting = mount(conn)
    render_hook(waiting, "device:changed", stored(door("my_house")))
    assert build(waiting) == nil
  end

  test "a failed write keeps the build, and the next save comes from the stored build", %{
    conn: conn
  } do
    first = door("my_house")
    view = open(conn, stored(first))
    edit(view)
    %{epoch: epoch} = save(view)
    mine = build(view)

    render_hook(view, "device:error", %{
      "error" => "full",
      "stamp" => first.stamp,
      "epoch" => epoch
    })

    assert flash(view, :error) =~ "This device did not save the build: full"
    assert build(view) == mine

    edit(view)
    assert %{base: base, epoch: new_epoch} = save(view)
    assert base == first.stamp
    assert new_epoch != epoch
  end

  test "an error of an old epoch only shows", %{conn: conn} do
    view = open(conn, empty())
    edit(view)
    %{epoch: epoch} = save(view)
    mine = build(view)

    render_hook(view, "device:error", %{"error" => "full", "stamp" => "", "epoch" => epoch + 1})
    assert flash(view, :error) =~ "This device did not save the build"

    edit(view)
    assert %{base: base} = save(view)
    assert base == mine.stamp
  end

  test "an event with bad parameters, or a large text, changes nothing", %{conn: conn} do
    view = open(conn, empty())
    before = {build(view), device(view)}
    large = String.duplicate("x", 512 * 1024 + 1)

    for {event, params} <- [
          {"device:restore", %{"text" => 5}},
          {"device:saved", %{"stamp" => 1}},
          {"device:conflict", %{"text" => "x"}},
          {"device:conflict", %{"text" => large, "stamp" => "", "epoch" => 1}},
          {"device:changed", %{}},
          {"device:changed", %{"text" => large, "stamp" => ""}},
          {"device:error", %{"error" => nil}},
          {"device:other", %{}}
        ] do
      render_hook(view, event, params)
      assert {build(view), device(view)} == before
    end
  end

  test "saved? is false before the restore" do
    refute DIYWeb.Device.saved?(%{build: nil, device: %{saved: nil}})
  end

  # Two tabs, as in specs/Device.tla: real LiveViews, and a fake device with
  # the compare and set of assets/js/device.js. The test is the hook of each
  # tab: it takes the saves in order, keeps its queue on a conflict, and
  # sends what it sees of the store on one channel, in order. A write puts a
  # read of the store in the queue of the other tab. A restart of a tab is a
  # reconnect (a new LiveView, the same hook and queue). After random steps,
  # the test gives all the messages: then each tab shows the stored build
  # (the same stamp), and its next save comes from it.
  property "two tabs show the stored build in the end", %{conn: conn} do
    check all(
            steps <-
              list_of(
                {member_of([0, 1]), member_of([:edit, :edit, :hook, :hook, :view, :restart])},
                max_length: 30
              ),
            max_runs: 100
          ) do
      state = %{store: nil, tabs: %{0 => tab(conn), 1 => tab(conn)}}
      state = Enum.reduce(steps, state, &step(&1, &2, conn))
      state = drain(state, conn)

      for t <- 0..1 do
        view = state.tabs[t].view
        stamp = if state.store, do: state.store["stamp"], else: ""
        assert build(view).stamp == stamp

        edit(view)
        assert %{base: ^stamp} = save(view)
      end
    end
  end

  defp tab(conn), do: %{view: mount(conn), queue: [:read], inbox: []}

  defp step({t, :edit}, state, _conn) do
    edit(state.tabs[t].view)
    collect(state, t)
  end

  defp step({t, :hook}, state, _conn) do
    case state.tabs[t].queue do
      [] ->
        state

      [:read | rest] ->
        state
        |> put_in([:tabs, t, :queue], rest)
        |> tell(t, {"device:restore", stored_text(state)})

      # The news of a write of the other tab: read the store.
      [:check | rest] ->
        state
        |> put_in([:tabs, t, :queue], rest)
        |> tell(t, {"device:changed", stored_text(state)})

      [save | rest] ->
        state = put_in(state, [:tabs, t, :queue], rest)

        if stamp(state) == save.base do
          {:ok, build} = Build.from_json(save.text)
          text = %{"text" => save.text, "stamp" => build.stamp}

          %{state | store: text}
          |> tell(t, {"device:saved", %{"stamp" => build.stamp}})
          |> update_in([:tabs, 1 - t, :queue], &(&1 ++ [:check]))
        else
          tell(state, t, {"device:conflict", Map.put(stored_text(state), "epoch", save.epoch)})
        end
    end
  end

  defp step({t, :view}, state, _conn) do
    case state.tabs[t].inbox do
      [] ->
        state

      [{event, payload} | rest] ->
        render_hook(state.tabs[t].view, event, payload)
        state |> put_in([:tabs, t, :inbox], rest) |> collect(t)
    end
  end

  # A reconnect: a new LiveView, with the hook and its queue. The new read
  # replaces the old reads of the queue.
  defp step({t, :restart}, state, conn) do
    view = mount(conn)

    update_in(state, [:tabs, t], fn tab ->
      %{tab | view: view, queue: Enum.reject(tab.queue, &(&1 == :read)) ++ [:read], inbox: []}
    end)
  end

  defp stamp(%{store: nil}), do: ""
  defp stamp(%{store: %{"stamp" => stamp}}), do: stamp

  defp stored_text(%{store: nil}), do: %{"text" => nil, "stamp" => ""}
  defp stored_text(%{store: store}), do: store

  defp tell(state, t, message), do: update_in(state, [:tabs, t, :inbox], &(&1 ++ [message]))

  # The saves that the LiveView of the tab pushed.
  defp collect(state, t) do
    receive do
      {_ref, {:push_event, "device:save", save}} ->
        state |> update_in([:tabs, t, :queue], &(&1 ++ [save])) |> collect(t)
    after
      0 -> state
    end
  end

  defp drain(state, conn) do
    if Enum.all?(0..1, &(state.tabs[&1].queue == [] and state.tabs[&1].inbox == [])) do
      state
    else
      Enum.reduce(0..1, state, fn t, state ->
        state |> then(&step({t, :hook}, &1, conn)) |> then(&step({t, :view}, &1, conn))
      end)
      |> drain(conn)
    end
  end
end
