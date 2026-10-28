defmodule DIY.LinksTest do
  use DIY.DataCase, async: true
  use ExUnitProperties

  import Ecto.Query
  import ExUnit.CaptureLog

  alias DIY.Links
  alias DIY.Links.Link
  alias DIY.Repo

  @day ~D[2026-10-26]

  defp data(text \\ "abc"), do: "1" <> Base.url_encode64(text, padding: false)

  test "the id of a short link: the version 2, then 16 letters or digits" do
    assert Links.id?("2Ab3dE9xYk2Lm7Qz0")
    refute Links.id?("2Ab3dE9xYk2Lm7Qz")
    refute Links.id?("2Ab3dE9xYk2Lm7Qz0p")
    refute Links.id?("2Ab3dE9xYk2Lm7Qz_")
    refute Links.id?("1Ab3dE9xYk2Lm7Qz0")
    refute Links.id?(nil)
  end

  test "a short link gives the DATA of its long link, and the table keeps no id and no house" do
    long = data("the house")
    assert {:ok, id} = Links.create(long, @day)
    assert Links.id?(id)
    assert {:ok, ^long} = Links.fetch(id, @day)

    # The row has a hash of the id, and the DATA is encrypted.
    [link] = Repo.all(Link)
    refute link.key =~ id
    refute link.box =~ long
    assert byte_size(link.key) == 32

    # A different id finds nothing.
    assert {:error, :gone} = Links.fetch("2" <> String.duplicate("A", 16), @day)
    assert {:error, :gone} = Links.fetch("no id", @day)
  end

  test "a link ends 365 days after its last visit, and a visit keeps its day" do
    {:ok, id} = Links.create(data(), @day)

    # A visit 300 days later keeps the day: the link then lasts 365 more days.
    later = Date.add(@day, 300)
    assert {:ok, _data} = Links.fetch(id, later)
    assert [%Link{used_on: ^later}] = Repo.all(Link)
    assert {:ok, _data} = Links.fetch(id, Date.add(later, 365))

    # 366 days after the last visit, the link ended: it is deleted.
    last = Date.add(later, 365)
    assert {:error, :gone} = Links.fetch(id, Date.add(last, 366))
    assert Repo.all(Link) == []
  end

  test "a new link deletes the links that ended" do
    {:ok, old} = Links.create(data("old"), @day)
    {:ok, kept} = Links.create(data("kept"), Date.add(@day, 100))

    {:ok, _new} = Links.create(data("new"), Date.add(@day, 366))
    assert {:error, :gone} = Links.fetch(old, Date.add(@day, 366))
    assert {:ok, _data} = Links.fetch(kept, Date.add(@day, 366))
    assert Repo.aggregate(Link, :count) == 2
  end

  test "only the DATA of a long link, and 100,000 links at most" do
    assert {:error, :data} = Links.create("2abc", @day)
    assert {:error, :data} = Links.create("1" <> String.duplicate("a", 6_001), @day)
    assert {:ok, _id} = Links.create("1" <> String.duplicate("a", 6_000), @day)

    rows =
      for n <- 2..100_000,
          do: %{key: <<n::256>>, box: "x", used_on: @day}

    for chunk <- Enum.chunk_every(rows, 5_000), do: Repo.insert_all(Link, chunk)
    assert Repo.aggregate(Link, :count) == 100_000
    assert {:error, :full} = Links.create(data(), @day)
  end

  test "a box that a person changed gives no house" do
    {:ok, id} = Links.create(data(), @day)
    Repo.update_all(from(l in Link), set: [box: "short"])
    assert {:error, :gone} = Links.fetch(id, @day)

    # One changed byte of the text: the tag of AES-GCM does not agree.
    Repo.delete_all(Link)
    {:ok, id} = Links.create(data("two"), @day)
    [%Link{key: key, box: box}] = Repo.all(Link)
    <<head::binary-28, byte, rest::binary>> = box
    changed = head <> <<Bitwise.bxor(byte, 1)>> <> rest
    Repo.update_all(from(l in Link, where: l.key == ^key), set: [box: changed])
    assert {:error, :gone} = Links.fetch(id, @day)
  end

  @tag :tmp_dir
  test "the migration makes the table in a new database, and a second run changes nothing",
       %{tmp_dir: dir} do
    {:ok, repo} =
      Repo.start_link(
        name: nil,
        database: Path.join(dir, "new.db"),
        pool: DBConnection.ConnectionPool,
        pool_size: 1
      )

    run = fn ->
      Ecto.Migrator.run(Repo, [{1, DIY.Links.Migration}], :up,
        all: true,
        dynamic_repo: repo,
        log: false
      )
    end

    assert run.() == [1]
    assert run.() == []

    # A boot that stopped after the table, before the version of the
    # migration: the next boot runs it again with no error.
    Ecto.Adapters.SQL.query!(repo, "DELETE FROM schema_migrations")
    assert run.() == [1]

    # The dynamic repo is of this process only.
    Repo.put_dynamic_repo(repo)
    assert {:ok, id} = Links.create(data(), @day)
    assert {:ok, _data} = Links.fetch(id, @day)
  end

  test "a migration that fails lets the app start, and the log tells the kind of the error" do
    {:ok, repo} = Repo.start_link(name: nil, database: ":memory:", pool_size: 1)
    GenServer.stop(repo)

    log = capture_log(fn -> assert Links.migrate(dynamic_repo: repo) == :error end)
    assert log =~ "The table of the short links is not ready ("
  end

  # The steps of a visit (specs/Links.tla): other requests can come
  # between the read and the write of a visit.
  test "a visit puts back a row that a new link deleted after the read, and keeps the later day" do
    {:ok, id} = Links.create(data("visit"), @day)
    [link] = Repo.all(Link)

    # A new link (at midnight) deletes the row after the read of the visit.
    Repo.delete_all(Link)
    later = Date.add(@day, 365)
    assert Links.visit(link, later) == :ok
    assert [%Link{used_on: ^later}] = Repo.all(Link)
    assert {:ok, _data} = Links.fetch(id, later)

    # A visit that read before a different visit writes an older day: the
    # row keeps the later day.
    assert Links.visit(link, @day) == :ok
    assert [%Link{used_on: ^later}] = Repo.all(Link)
  end

  test "the delete of an ended link keeps a row that a different visit just wrote" do
    {:ok, _id} = Links.create(data(), @day)
    [link] = Repo.all(Link)

    # The read found the link ended on day 366. A different visit wrote
    # day 2 before the delete.
    assert Links.visit(link, Date.add(@day, 2)) == :ok
    assert Links.expire(link.key, Date.add(@day, 366)) == :ok
    assert [_row] = Repo.all(Link)

    # 366 days after that visit, the delete works.
    assert Links.expire(link.key, Date.add(@day, 368)) == :ok
    assert Repo.all(Link) == []
  end

  test "an error of the storage gives an error, and the log has no id and no house" do
    {:ok, id} = Links.create(data("the house"), @day)

    # A process with no connection of the sandbox: each statement fails.
    # The failure can take more than the 100 ms of `assert_receive` when
    # many tests run at the same time. So the test waits 5 seconds at most.
    task = fn fun ->
      parent = self()
      spawn(fn -> send(parent, {:result, fun.()}) end)
      assert_receive {:result, result}, 5_000
      result
    end

    log =
      capture_log(fn ->
        assert task.(fn -> Links.create(data(), @day) end) == {:error, :storage}
        assert task.(fn -> Links.fetch(id, @day) end) == {:error, :storage}
      end)

    assert log =~ "The storage of the short links failed (DBConnection.OwnershipError)"
    refute log =~ id
    refute log =~ "the house"
  end

  property "each DATA comes back from its short link, and each id is new" do
    check all(
            texts <-
              uniq_list_of(string(:printable, max_length: 300), min_length: 1, max_length: 5)
          ) do
      ids =
        for text <- texts do
          long = data(text)
          {:ok, id} = Links.create(long, @day)
          assert {:ok, ^long} = Links.fetch(id, @day)
          id
        end

      assert length(Enum.uniq(ids)) == length(ids)
      Repo.delete_all(Link)
    end
  end
end
