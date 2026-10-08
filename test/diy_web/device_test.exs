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

  defp open(conn, payload) do
    {:ok, view, _html} = live(conn, ~p"/")
    render_hook(view, "device:restore", payload)
    view
  end

  defp empty, do: %{"text" => nil, "stamp" => ""}

  # The save that the LiveView pushed last.
  defp save(view) do
    assert_push_event view, "device:save", save
    save
  end

  test "a text that is not a build gives a new build, and the next save keeps a copy", %{
    conn: conn
  } do
    view = open(conn, %{"text" => "not a build", "stamp" => "x"})
    assert render(view) =~ "keeps a copy of the old one"
    assert has_element?(view, "#door-my-house")

    view |> element("#door-my-house") |> render_click()
    assert %{base: "x", backup: true} = save(view)

    view |> element("#restart") |> render_click()
    assert %{backup: false} = save(view)
  end

  test "a build of a newer version stops the saves", %{conn: conn} do
    view = open(conn, %{"text" => ~s({"version": 2}), "stamp" => "x"})
    assert render(view) =~ "comes from a newer version"

    view |> element("#door-my-house") |> render_click()
    refute_push_event view, "device:save", _save
  end

  test "a second restore changes nothing", %{conn: conn} do
    view = open(conn, empty())
    html = render_hook(view, "device:restore", stored(door("planning")))
    assert html =~ "door-my-house"
  end

  test "a conflict of the epoch shows the stored build, in a new epoch", %{conn: conn} do
    view = open(conn, empty())
    view |> element("#door-my-house") |> render_click()
    %{epoch: epoch} = save(view)

    other = door("planning")
    html = render_hook(view, "device:conflict", Map.put(stored(other), "epoch", epoch))
    assert html =~ "A different tab changed this build"
    assert html =~ "A house I&#39;m planning"

    view |> element("#restart") |> render_click()
    assert %{base: base, epoch: new_epoch} = save(view)
    assert base == other.stamp
    assert new_epoch != epoch
  end

  test "a conflict of an old epoch changes no build", %{conn: conn} do
    view = open(conn, empty())
    view |> element("#door-my-house") |> render_click()
    %{epoch: epoch} = save(view)

    html =
      render_hook(view, "device:conflict", Map.put(stored(door("planning")), "epoch", epoch + 1))

    refute html =~ "A different tab changed this build"
    assert html =~ "My house"
  end

  test "a conflict with an empty store saves the build again on it", %{conn: conn} do
    view = open(conn, empty())
    view |> element("#door-my-house") |> render_click()
    %{text: text, epoch: epoch} = save(view)

    html = render_hook(view, "device:conflict", %{"text" => nil, "stamp" => "", "epoch" => epoch})
    assert html =~ "My house"
    assert %{text: ^text, base: "", epoch: new_epoch} = save(view)
    assert new_epoch != epoch
  end

  test "a conflict before the restore changes nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    html = render_hook(view, "device:conflict", Map.put(stored(door("planning")), "epoch", 1))
    assert html =~ "reads your build"
  end

  test "a newer build of a different tab shows at once", %{conn: conn} do
    view = open(conn, empty())

    assert render_hook(view, "device:changed", stored(door("planning"))) =~
             "A house I&#39;m planning"

    view |> element("#restart") |> render_click()
    assert %{base: base} = save(view)
    assert base != ""
  end

  test "an older build, a text that is not a build, or a write before the restore changes nothing",
       %{conn: conn} do
    view = open(conn, stored(Build.change(door("my_house"), & &1)))
    assert render_hook(view, "device:changed", stored(door("planning"))) =~ "My house"
    assert render_hook(view, "device:changed", %{"text" => "x", "stamp" => ""}) =~ "My house"

    {:ok, waiting, _html} = live(conn, ~p"/")
    assert render_hook(waiting, "device:changed", stored(door("my_house"))) =~ "reads your build"
  end

  test "a failed write keeps the build, and the next save comes from the stored build", %{
    conn: conn
  } do
    first = door("my_house")
    view = open(conn, stored(first))
    view |> element("#restart") |> render_click()
    %{epoch: epoch} = save(view)

    html =
      render_hook(view, "device:error", %{
        "error" => "full",
        "stamp" => first.stamp,
        "epoch" => epoch
      })

    assert html =~ "This device did not save the build: full"
    assert html =~ "door-my-house"

    view |> element("#door-planning") |> render_click()
    assert %{base: base, epoch: new_epoch} = save(view)
    assert base == first.stamp
    assert new_epoch != epoch
  end

  test "an error of an old epoch only shows", %{conn: conn} do
    view = open(conn, empty())
    view |> element("#door-my-house") |> render_click()
    %{text: text, epoch: epoch} = save(view)
    {:ok, build} = Build.from_json(text)

    html =
      render_hook(view, "device:error", %{"error" => "full", "stamp" => "", "epoch" => epoch + 1})

    assert html =~ "This device did not save the build"

    view |> element("#restart") |> render_click()
    assert %{base: base} = save(view)
    assert base == build.stamp
  end

  test "an event with bad parameters, or a large text, changes nothing", %{conn: conn} do
    view = open(conn, empty())
    before = render_hook(view, "device:other", %{})
    large = String.duplicate("x", 512 * 1024 + 1)

    for {event, params} <- [
          {"device:restore", %{"text" => 5}},
          {"device:saved", %{"stamp" => 1}},
          {"device:conflict", %{"text" => "x"}},
          {"device:conflict", %{"text" => large, "stamp" => "", "epoch" => 1}},
          {"device:changed", %{}},
          {"device:changed", %{"text" => large, "stamp" => ""}},
          {"device:error", %{"error" => nil}}
        ] do
      assert render_hook(view, event, params) == before
    end
  end

  test "saved? is false before the restore" do
    refute DIYWeb.Device.saved?(%{build: nil, device: %{saved: nil}})
  end

  # Two tabs, as in specs/Device.tla: real LiveViews, and a fake device with
  # the compare and set of assets/js/device.js. The test is the hook of each
  # tab: it takes the saves in order, keeps its queue on a conflict, and
  # sends what it sees of the store on one channel, in order. A restart of a
  # tab is a reconnect (a new LiveView, the same hook and queue). After
  # random steps, the test gives all the messages: then each tab shows the
  # stored build (the same stamp), and its next save comes from it.
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
        build = :sys.get_state(view.pid).socket.assigns.build
        assert build.stamp == stamp

        click(view)
        assert %{base: ^stamp} = save(view)
      end
    end
  end

  defp tab(conn) do
    {:ok, view, _html} = live(conn, ~p"/")
    %{view: view, queue: [:read], inbox: []}
  end

  defp click(view) do
    if has_element?(view, "#restart"),
      do: view |> element("#restart") |> render_click(),
      else: view |> element("#door-planning") |> render_click()
  end

  defp step({t, :edit}, state, _conn) do
    view = state.tabs[t].view
    if :sys.get_state(view.pid).socket.assigns.build, do: click(view)
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

      [save | rest] ->
        state = put_in(state, [:tabs, t, :queue], rest)

        if stamp(state) == save.base do
          {:ok, build} = Build.from_json(save.text)
          text = %{"text" => save.text, "stamp" => build.stamp}

          %{state | store: text}
          |> tell(t, {"device:saved", %{"stamp" => build.stamp}})
          |> tell(1 - t, {"device:changed", text})
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
    {:ok, view, _html} = live(conn, ~p"/")

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
