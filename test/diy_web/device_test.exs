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

  test "a text that is not a build gives a new build, which the next save writes over", %{
    conn: conn
  } do
    view = open(conn, %{"text" => "not a build", "stamp" => "x"})
    assert render(view) =~ "from a different version"
    assert has_element?(view, "#door-my-house")

    view |> element("#door-my-house") |> render_click()
    assert_push_event view, "device:save", %{base: "x"}
  end

  test "a conflict of the epoch shows the stored build", %{conn: conn} do
    view = open(conn, %{"text" => nil, "stamp" => ""})
    view |> element("#door-my-house") |> render_click()
    assert_push_event view, "device:save", %{epoch: 0}

    other = door("planning")
    html = render_hook(view, "device:conflict", Map.put(stored(other), "epoch", 0))
    assert html =~ "A different tab changed this build"
    assert html =~ "A house I&#39;m planning"

    # The next save comes from the stored build, in a new epoch.
    view |> element("#restart") |> render_click()
    assert_push_event view, "device:save", %{base: base, epoch: 1}
    assert base == other.stamp
  end

  test "a conflict of an old epoch changes no build", %{conn: conn} do
    view = open(conn, %{"text" => nil, "stamp" => ""})
    view |> element("#door-my-house") |> render_click()
    html = render_hook(view, "device:conflict", Map.put(stored(door("planning")), "epoch", 7))
    refute html =~ "A different tab changed this build"
    assert html =~ "My house"
  end

  test "a conflict shows the newest stored build that the page knows", %{conn: conn} do
    view = open(conn, %{"text" => nil, "stamp" => ""})
    view |> element("#door-my-house") |> render_click()

    newer = Build.change(door("planning"), & &1)
    render_hook(view, "device:changed", stored(newer))
    older = door("my_house")
    html = render_hook(view, "device:conflict", Map.put(stored(older), "epoch", 1))
    assert html =~ "A house I&#39;m planning"
  end

  test "a conflict with no stored text gives a new build", %{conn: conn} do
    view = open(conn, %{"text" => nil, "stamp" => ""})
    view |> element("#door-my-house") |> render_click()
    html = render_hook(view, "device:conflict", %{"text" => nil, "stamp" => "", "epoch" => 0})
    assert html =~ "door-my-house"
  end

  test "a newer build of a different tab shows at once", %{conn: conn} do
    view = open(conn, %{"text" => nil, "stamp" => ""})

    assert render_hook(view, "device:changed", stored(door("planning"))) =~
             "A house I&#39;m planning"
  end

  test "a build of a different tab before the restore shows at once", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert render_hook(view, "device:changed", stored(door("my_house"))) =~ "My house"
  end

  test "an older build of a different tab changes no build", %{conn: conn} do
    build = Build.change(door("my_house"), & &1)
    view = open(conn, stored(build))
    html = render_hook(view, "device:changed", stored(door("planning")))
    assert html =~ "My house"
  end

  test "an error of the storage shows", %{conn: conn} do
    view = open(conn, %{"text" => nil, "stamp" => ""})
    html = render_hook(view, "device:error", %{"error" => "QuotaExceededError"})
    assert html =~ "This device did not save the build: QuotaExceededError"
  end

  test "a device event with bad parameters changes nothing", %{conn: conn} do
    view = open(conn, %{"text" => nil, "stamp" => ""})
    before = render_hook(view, "device:other", %{})

    for {event, params} <- [
          {"device:restore", %{"text" => 5}},
          {"device:saved", %{"stamp" => 1}},
          {"device:conflict", %{"text" => "x"}},
          {"device:changed", %{}},
          {"device:error", %{"error" => nil}},
          {"device:other", %{}}
        ] do
      assert render_hook(view, event, params) == before
    end
  end

  test "saved? is false before the restore" do
    refute DIYWeb.Device.saved?(%{build: nil, device: %{saved: nil}})
  end

  # Two tabs, as in specs/Device.tla: two real LiveViews and a fake device
  # with the compare and set of assets/js/device.js. The test is the hook of
  # each tab. After random steps, it gives all the messages. Then each tab
  # shows the stored build, and the next save of each tab comes from it.
  property "two tabs show the stored build in the end", %{conn: conn} do
    check all(
            steps <-
              list_of({member_of([0, 1]), member_of([:edit, :store, :deliver])}, max_length: 25),
            max_runs: 40
          ) do
      tabs = for _ <- 0..1, do: open(conn, %{"text" => nil, "stamp" => ""})
      state = %{stored: nil, saves: %{0 => [], 1 => []}, inbox: %{0 => [], 1 => []}}

      state = Enum.reduce(steps, state, &step(&1, &2, tabs))
      state = drain(state, tabs)

      for t <- 0..1 do
        html = render(Enum.at(tabs, t))
        door = state.stored && Build.from_json(state.stored["text"]) |> elem(1) |> Map.get(:door)
        assert html =~ door_text(door)
      end
    end
  end

  defp door_text(nil), do: "door-my-house"
  defp door_text("my_house"), do: "My house"
  defp door_text("planning"), do: "A house I&#39;m planning"

  # An edit: a click on a door, or on "start again".
  defp step({t, :edit}, state, tabs) do
    view = Enum.at(tabs, t)

    if has_element?(view, "#restart"),
      do: view |> element("#restart") |> render_click(),
      else: view |> element("#door-planning") |> render_click()

    collect(state, t, view)
  end

  # The hook takes the next save of the tab: compare and set.
  defp step({t, :store}, state, tabs) do
    case state.saves[t] do
      [] ->
        state

      [save | rest] ->
        state = put_in(state.saves[t], rest)
        stored_stamp = if state.stored, do: state.stored["stamp"], else: ""
        view = Enum.at(tabs, t)

        if stored_stamp == save.base do
          {:ok, build} = Build.from_json(save.text)
          text = %{"text" => save.text, "stamp" => build.stamp}
          render_hook(view, "device:saved", %{"stamp" => build.stamp})
          other = 1 - t
          state = %{state | stored: text}
          update_in(state.inbox[other], &(&1 ++ [{"device:changed", text}]))
        else
          text = state.stored || %{"text" => nil, "stamp" => ""}
          message = {"device:conflict", Map.put(text, "epoch", save.epoch)}
          update_in(state.inbox[t], &(&1 ++ [message]))
        end
        |> collect(t, view)
    end
  end

  # The tab gets its next message: a conflict or a "storage" event.
  defp step({t, :deliver}, state, tabs) do
    case state.inbox[t] do
      [] ->
        state

      [{event, payload} | rest] ->
        view = Enum.at(tabs, t)
        render_hook(view, event, payload)
        collect(put_in(state.inbox[t], rest), t, view)
    end
  end

  # The saves that the LiveView of the tab pushed.
  defp collect(state, t, view) do
    receive do
      {_ref, {:push_event, "device:save", save}} ->
        collect(update_in(state.saves[t], &(&1 ++ [save])), t, view)
    after
      0 -> state
    end
  end

  defp drain(state, tabs) do
    if Enum.all?(0..1, &(state.saves[&1] == [] and state.inbox[&1] == [])) do
      state
    else
      state
      |> then(&Enum.reduce(0..1, &1, fn t, s -> step({t, :store}, s, tabs) end))
      |> then(&Enum.reduce(0..1, &1, fn t, s -> step({t, :deliver}, s, tabs) end))
      |> drain(tabs)
    end
  end
end
