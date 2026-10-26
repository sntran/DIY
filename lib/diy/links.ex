defmodule DIY.Links do
  @moduledoc """
  The short links of shared houses (docs/design.md, "A short link"). A
  short link is `/s/ID`. `ID` is the version `2`, then 12 random letters
  and digits (71 bits). The server keeps the `DATA` of the long link
  (`DIY.Share`) for it, encrypted:

  - The key of the row is a hash of the id (SHA-256). The table does not
    keep the id.
  - The `DATA` is encrypted with AES-256-GCM. Its key is an HMAC of the
    id. Thus the table alone does not give a house: only the link does.
  - A link ends 365 days after its last visit (`used_on`). A visit
    writes the day once a day at most. Each new link deletes the links
    that ended.
  - The table has 100,000 links at most.

  The long links stay as they are: their `DATA` has the version `1`.
  """
  import Ecto.Query

  alias DIY.Links.{Link, Migration}
  alias DIY.Repo

  @version "2"
  @length 12
  @alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  @days 365
  @max_links 100_000

  # The longest DATA of a long link (`DIY.Share`): its version and 6,000
  # characters at most.
  @max_data 6_001

  @doc "Runs the migration of the table at the boot (`DIY.Application`)."
  def migrate do
    Ecto.Migrator.run(Repo, [{1, Migration}], :up, all: true, log: false)
    :ignore
  end

  @doc "True for the text of a short link: `2` and 12 letters or digits."
  @spec id?(term()) :: boolean()
  def id?(@version <> rest) when byte_size(rest) == @length,
    do: rest |> String.to_charlist() |> Enum.all?(&(&1 in @alphabet))

  def id?(_text), do: false

  @doc """
  Keeps the `DATA` of a long link, and gives the id of its short link.
  The day is the day of today (UTC). It first deletes the links that
  ended. A full table gives `{:error, :full}`, and a `DATA` that is not
  of a long link gives `{:error, :data}`.
  """
  @spec create(String.t(), Date.t()) :: {:ok, String.t()} | {:error, :full | :data}
  def create(data, today \\ Date.utc_today())

  def create("1" <> _rest = data, today) when byte_size(data) <= @max_data do
    Repo.delete_all(from(l in Link, where: l.used_on < ^Date.add(today, -@days)))

    if Repo.aggregate(Link, :count) < @max_links do
      id = new_id()
      {row, key} = keys(id)
      Repo.insert!(%Link{key: row, box: seal(key, data), used_on: today})
      {:ok, id}
    else
      {:error, :full}
    end
  end

  def create(_data, _today), do: {:error, :data}

  @doc """
  The `DATA` of the long link of a short link, and the day of the visit
  in the row. A link that is not there, or that ended, gives
  `{:error, :gone}`. An ended link is deleted.
  """
  @spec fetch(String.t(), Date.t()) :: {:ok, String.t()} | {:error, :gone}
  def fetch(id, today \\ Date.utc_today()) do
    with true <- id?(id),
         {row, key} = keys(id),
         %Link{} = link <- Repo.get(Link, row),
         :ok <- alive(link, today),
         {:ok, data} <- open(key, link.box) do
      if Date.compare(link.used_on, today) == :lt,
        do: Repo.update_all(from(l in Link, where: l.key == ^row), set: [used_on: today])

      {:ok, data}
    else
      _gone -> {:error, :gone}
    end
  end

  # A link ends 365 days after its last visit. An ended link is deleted.
  defp alive(link, today) do
    if Date.diff(today, link.used_on) <= @days do
      :ok
    else
      Repo.delete!(link)
      :gone
    end
  end

  # 12 letters or digits, each from 6 random bits: a value of 62 or more
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
