defmodule DIY.Links do
  @moduledoc """
  The short links of shared houses (docs/design.md, "A short link"). A
  short link is `/s/ID`. `ID` is the version `2`, then 16 random letters
  and digits (95 bits). The server keeps the `DATA` of the long link
  (`DIY.Share`) for it, encrypted:

  - The key of the row is a hash of the id (SHA-256). The table does not
    keep the id.
  - The `DATA` is encrypted with AES-256-GCM. Its key is an HMAC of the
    id. Thus the table alone does not give a house: only the link does.
  - A link ends 365 days after its last visit (`used_on`). A visit
    writes the day once a day at most. Each new link deletes the links
    that ended.
  - The table has 100,000 links at most. The app makes 1,000 new links a
    day at most, and 20 a day for each address (`allow/2`).
  - The storage of a Durable Object commits each statement alone. Thus
    each step is one statement that is correct at any time
    (`specs/Links.tla`). An error of the storage gives
    `{:error, :storage}`, and the log tells only the kind of the error.

  The long links stay as they are: their `DATA` has the version `1`.
  """
  import Ecto.Query

  require Logger

  alias DIY.Links.{Guard, Link, Migration}
  alias DIY.Repo

  @version "2"
  @length 16
  @alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  @days 365
  @max_links 100_000
  @per_day 1_000
  @per_address 20

  # When the migration of the start failed, a request tries it again. It
  # does so once a minute at most.
  @retry_ms 60_000

  # The longest DATA of a long link (`DIY.Share`): its version and 6,000
  # characters at most.
  @max_data 6_001

  @doc """
  Runs the migration of the table at the start (`DIY.Links.Guard`), and
  keeps the result. When it fails, the app starts without the short
  links. Then a request tries the migration again, once a minute at most.
  """
  def boot(opts \\ []), do: ready(migrate(opts))

  @doc """
  Runs the migration of the table. It can run again after a start that
  stopped in it. It gives `:ok`, or `:error` with a line in the log.
  """
  @spec migrate(keyword()) :: :ok | :error
  def migrate(opts \\ []) do
    Ecto.Migrator.run(Repo, [{1, Migration}], :up, [all: true, log: false] ++ opts)
    :ok
  catch
    kind, reason ->
      Logger.error("The table of the short links is not ready (#{kind(kind, reason)})")
      :error
  end

  defp ready(:ok), do: :ets.insert(Guard, {:ready, true})
  defp ready(:error), do: :ets.insert(Guard, {:ready, false, now()})

  # True when the table is ready. Else a migration again, when the last
  # try is one minute old. Only one request runs it: the request that
  # writes the time of the new try first (an atomic replace). Only a
  # migration that works changes the state.
  defp ready? do
    case :ets.lookup(Guard, :ready) do
      [{:ready, false, at} = last] ->
        now = now()

        now - at >= @retry_ms and
          :ets.select_replace(Guard, [{last, [], [{{:ready, false, now}}]}]) == 1 and
          migrate() == :ok and
          :ets.insert(Guard, {:ready, true})

      _ready ->
        true
    end
  end

  defp now, do: System.monotonic_time(:millisecond)

  @doc """
  `:ok` when the app can make one more short link today for the address
  (a key, `DIYWeb.Address`), and it counts it. Else `{:error, :many}`:
  1,000 links today for all the persons, or 20 for the address. No
  address (`nil`) gets no link. The counts are in the memory of the VM.

  Each count goes up first, and then the check reads the new count. Thus
  two requests at the same time cannot both get the last link. The count
  of all the persons is first: an address gets a count only when the app
  can still make links today.
  """
  @spec allow(String.t() | nil, Date.t()) :: :ok | {:error, :many}
  def allow(nil, _today), do: {:error, :many}

  def allow(address, today) do
    day = Date.to_gregorian_days(today)

    # The counts of the days before today go.
    :ets.select_delete(Guard, [{{{:count, :_, :"$1"}, :_}, [{:"/=", :"$1", day}], [true]}])

    cond do
      add({:count, :all, day}, 1) > @per_day ->
        add({:count, :all, day}, -1)
        {:error, :many}

      add({:count, address, day}, 1) > @per_address ->
        give_back(address, today)
        {:error, :many}

      true ->
        :ok
    end
  end

  # A link that the app did not make gives its counts back.
  defp give_back(address, today) do
    day = Date.to_gregorian_days(today)
    add({:count, :all, day}, -1)
    add({:count, address, day}, -1)
  end

  defp add(key, n), do: :ets.update_counter(Guard, key, n, {key, 0})

  @doc "True for the text of a short link: `2` and 16 letters or digits."
  @spec id?(term()) :: boolean()
  def id?(@version <> rest) when byte_size(rest) == @length,
    do: rest |> String.to_charlist() |> Enum.all?(&(&1 in @alphabet))

  def id?(_text), do: false

  @doc """
  Keeps the `DATA` of a long link, and gives the id of its short link.
  The day is the day of today (UTC). It first deletes the links that
  ended. A full table gives `{:error, :full}`, and a `DATA` that is not
  of a long link gives `{:error, :data}`.

  With the option `address`, the link counts for that address
  (`allow/2`), and too many links give `{:error, :many}`. A link that the
  app could not make gives its count back.
  """
  @spec create(String.t(), Date.t(), keyword()) ::
          {:ok, String.t()} | {:error, :full | :data | :storage | :many}
  def create(data, today \\ Date.utc_today(), opts \\ [])

  def create("1" <> _rest = data, today, opts) when byte_size(data) <= @max_data do
    case Keyword.fetch(opts, :address) do
      {:ok, address} ->
        with :ok <- allow(address, today), do: data |> insert(today) |> counted(address, today)

      :error ->
        insert(data, today)
    end
  end

  def create(_data, _today, _opts), do: {:error, :data}

  defp counted({:ok, _id} = made, _address, _today), do: made

  defp counted(error, address, today) do
    give_back(address, today)
    error
  end

  defp insert(data, today) do
    storage(fn ->
      Repo.delete_all(from(l in Link, where: l.used_on < ^Date.add(today, -@days)))

      if Repo.aggregate(Link, :count) < @max_links do
        id = new_id()
        {row, key} = keys(id)
        Repo.insert!(%Link{key: row, box: seal(key, data), used_on: today})
        {:ok, id}
      else
        {:error, :full}
      end
    end)
  end

  @doc """
  The `DATA` of the long link of a short link, and the day of the visit
  in the row. A link that is not there, or that ended, gives
  `{:error, :gone}`. An ended link is deleted.
  """
  @spec fetch(String.t(), Date.t()) :: {:ok, String.t()} | {:error, :gone | :storage}
  def fetch(id, today \\ Date.utc_today()) do
    if id?(id) do
      {row, key} = keys(id)
      storage(fn -> find(row, key, today) end)
    else
      {:error, :gone}
    end
  end

  defp find(row, key, today) do
    with %Link{} = link <- Repo.get(Link, row),
         :ok <- alive(link, today),
         {:ok, data} <- open(key, link.box) do
      if Date.compare(link.used_on, today) == :lt, do: visit(link, today)
      {:ok, data}
    else
      _gone -> {:error, :gone}
    end
  end

  defp alive(link, today) do
    if Date.diff(today, link.used_on) <= @days do
      :ok
    else
      expire(link.key, today)
      :gone
    end
  end

  @doc """
  The step Expire of `fetch/2` (`specs/Links.tla`): it deletes the row of
  a link that ended. The delete also checks the day in the row: a
  different request can write a new visit after the read of this
  request. It is public for the tests of the steps.
  """
  @spec expire(binary(), Date.t()) :: :ok
  def expire(row, today) do
    Repo.delete_all(
      from(l in Link, where: l.key == ^row and l.used_on < ^Date.add(today, -@days))
    )

    :ok
  end

  @doc """
  The step Write of `fetch/2` (`specs/Links.tla`): it keeps the day of a
  visit with an upsert. A new link can delete the row after the read (at
  midnight). Then the row comes back, because the visit found the link.
  Two visits at the same time keep the later day. It is public for the
  tests of the steps.
  """
  @spec visit(%Link{}, Date.t()) :: :ok
  def visit(%Link{key: row, box: box}, today) do
    Repo.insert!(%Link{key: row, box: box, used_on: today},
      on_conflict:
        from(l in Link, update: [set: [used_on: fragment("max(?, excluded.used_on)", l.used_on)]]),
      conflict_target: :key
    )

    :ok
  end

  # An error of the storage stops the short links, not the page. The log
  # has no id and no house: only the kind of the error. When the table is
  # not ready, no statement runs.
  defp storage(fun) do
    if ready?(), do: fun.(), else: {:error, :storage}
  catch
    kind, reason ->
      Logger.error("The storage of the short links failed (#{kind(kind, reason)})")
      {:error, :storage}
  end

  # The module of an exception, else only `:exit`, `:throw` or `:error`.
  defp kind(kind, reason),
    do: if(is_exception(reason), do: inspect(reason.__struct__), else: inspect(kind))

  # 16 letters or digits, each from 6 random bits: a value of 62 or more
  # is not used, so each character has the same chance.
  defp new_id, do: @version <> List.to_string(chars(@length, []))

  defp chars(0, acc), do: acc

  defp chars(n, acc) do
    <<_::2, value::6>> = :crypto.strong_rand_bytes(1)

    if value < 62,
      do: chars(n - 1, [Enum.at(@alphabet, value) | acc]),
      else: chars(n, acc)
  end

  # The key of the row, and the key of the encryption, from the id.
  defp keys(id) do
    {:crypto.hash(:sha256, "diy link row " <> id),
     :crypto.mac(:hmac, :sha256, id, "diy link key")}
  end

  defp seal(key, data) do
    iv = :crypto.strong_rand_bytes(12)
    {text, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, data, "diy link", true)
    iv <> tag <> text
  end

  defp open(key, <<iv::binary-12, tag::binary-16, text::binary>>) do
    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, text, "diy link", tag, false) do
      data when is_binary(data) -> {:ok, data}
      :error -> :error
    end
  end

  defp open(_key, _box), do: :error
end
