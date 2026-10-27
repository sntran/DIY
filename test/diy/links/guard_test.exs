defmodule DIY.Links.GuardTest do
  # The state of the guard is for all the tests: no test runs at the same
  # time.
  use DIY.DataCase, async: false

  import ExUnit.CaptureLog

  alias DIY.Links
  alias DIY.Links.{Guard, Link}
  alias DIY.Repo

  @day ~D[2026-10-27]

  setup do
    # The tests of the pages also count links. Each test here starts with
    # no counts.
    :ets.match_delete(Guard, {{:count, :_, :_}, :_})

    on_exit(fn ->
      :ets.match_delete(Guard, {{:count, :_, :_}, :_})
      :ets.insert(Guard, {:ready, true})
    end)
  end

  defp data, do: "1" <> Base.url_encode64("abc", padding: false)

  test "an address makes 20 links a day, and all the persons make 1,000" do
    for _n <- 1..20, do: assert(Links.allow("a", @day) == :ok)
    assert Links.allow("a", @day) == {:error, :many}
    assert Links.allow("b", @day) == :ok

    # A new day starts again, and the counts of the day before go.
    tomorrow = Date.add(@day, 1)
    assert Links.allow("a", tomorrow) == :ok
    assert :ets.match(Guard, {{:count, :_, Date.to_gregorian_days(@day)}, :"$1"}) == []

    # 1,000 links of all the persons in a day.
    for n <- 2..999, do: assert(Links.allow("address #{n}", tomorrow) == :ok)
    assert Links.allow("c", tomorrow) == :ok
    assert Links.allow("d", tomorrow) == {:error, :many}
  end

  test "the counts go up first: no address row after the 1,000 links of a day" do
    for n <- 1..1_000, do: assert(Links.allow("address #{n}", @day) == :ok)
    assert Links.allow("late", @day) == {:error, :many}

    day = Date.to_gregorian_days(@day)
    assert :ets.lookup(Guard, {:count, :all, day}) == [{{:count, :all, day}, 1_000}]
    assert :ets.lookup(Guard, {:count, "late", day}) == []
  end

  test "a page with no address gets no link, and a link that the app did not make gives its count back" do
    assert Links.create(data(), @day, address: nil) == {:error, :many}

    # The table is not ready: 25 tries spend no count of the address.
    :ets.insert(Guard, {:ready, false, System.monotonic_time(:millisecond)})
    for _n <- 1..25, do: assert(Links.create(data(), @day, address: "a") == {:error, :storage})
    :ets.insert(Guard, {:ready, true})

    # The row of the address goes: an error of the storage adds no rows.
    assert :ets.lookup(Guard, {:count, "a", Date.to_gregorian_days(@day)}) == []

    for _n <- 1..20, do: assert({:ok, _id} = Links.create(data(), @day, address: "a"))
    assert Links.create(data(), @day, address: "a") == {:error, :many}
  end

  test "a full table keeps the count: a page cannot try without a limit" do
    rows = for n <- 1..100_000, do: %{key: <<n::256>>, box: "x", used_on: @day}
    for chunk <- Enum.chunk_every(rows, 5_000), do: Repo.insert_all(Link, chunk)

    for _n <- 1..20, do: assert(Links.create(data(), @day, address: "a") == {:error, :full})
    assert Links.create(data(), @day, address: "a") == {:error, :many}
  end

  test "a table that is not ready gets no statement, and a request tries the migration again after one minute" do
    {:ok, repo} = Repo.start_link(name: nil, database: ":memory:", pool_size: 1)
    GenServer.stop(repo)

    # The migration of the start fails.
    log = capture_log(fn -> Links.boot(dynamic_repo: repo) end)
    assert log =~ "The table of the short links is not ready"
    assert [{:ready, false, at}] = :ets.lookup(Guard, :ready)

    assert Links.create(data(), @day) == {:error, :storage}
    assert Links.fetch("2" <> String.duplicate("A", 16), @day) == {:error, :storage}

    # A different request wrote a new time first: this request does not run
    # the migration.
    :ets.insert(Guard, {:ready, false, at})
    assert Links.create(data(), @day) == {:error, :storage}

    # One minute later, a request runs the migration again. It works: the
    # table is ready.
    :ets.insert(Guard, {:ready, false, at - 60_000})
    assert {:ok, _id} = Links.create(data(), @day)
    assert :ets.lookup(Guard, :ready) == [{:ready, true}]
  end
end
