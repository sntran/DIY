defmodule DIY.Build do
  @moduledoc """
  The build of a user: the house, and later the vans. The build stays on
  the device (see `DIYWeb.Device`). The server reads it from JSON, and
  writes it to JSON after each change.

  `revision` counts the changes. Each change adds 1. `stamp` is a random
  name for each change. The device writes a build only on the build that
  it comes from: the stored stamp must be the stamp of that build (see
  `DIYWeb.Device` and `specs/Device.tla`).

  `from_json/1` accepts only a build that it can read in full. It never
  raises: a stored text from an old version, or a text that a person
  changed, gives an error, and the page starts a new build.
  """

  @version 1
  @doors ~w(my_house planning)

  @enforce_keys [:revision]
  defstruct version: @version, revision: 0, stamp: "", door: nil

  @type door :: String.t() | nil
  @type t :: %__MODULE__{
          version: pos_integer(),
          revision: non_neg_integer(),
          stamp: String.t(),
          door: door()
        }

  @doc "The version of the format of the build."
  def version, do: @version

  @doc "The doors of the first screen: my house, or a house I'm planning."
  def doors, do: @doors

  @doc "A new, empty build."
  @spec new() :: t()
  def new, do: %__MODULE__{revision: 0}

  @doc """
  Applies a change to the build, adds 1 to its revision, and gives it a new
  stamp.
  """
  @spec change(t(), (t() -> t())) :: t()
  def change(%__MODULE__{revision: revision} = build, fun) do
    %__MODULE__{} = changed = fun.(build)
    %__MODULE__{changed | revision: revision + 1, stamp: new_stamp()}
  end

  # 96 random bits: two changes never get the same stamp.
  defp new_stamp, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  @doc """
  Starts the build again from nothing. The revision goes on, so that the
  new build replaces the stored build on the device.
  """
  @spec restart(t()) :: t()
  def restart(%__MODULE__{} = build), do: change(build, fn _ -> new() end)

  @doc "Sets the door of the first screen."
  @spec choose_door(t(), String.t()) :: {:ok, t()} | {:error, :door}
  def choose_door(build, door) when door in @doors,
    do: {:ok, change(build, &%{&1 | door: door})}

  def choose_door(_build, _door), do: {:error, :door}

  @doc "The build as a JSON text."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = build) do
    Jason.encode!(%{
      "version" => build.version,
      "revision" => build.revision,
      "stamp" => build.stamp,
      "door" => build.door
    })
  end

  @doc """
  Reads a build from a JSON text. The error tells why the text is not a
  build of this version.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, atom()}
  def from_json(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> from_map(map)
      {:ok, _other} -> {:error, :not_a_build}
      {:error, _reason} -> {:error, :not_json}
    end
  end

  def from_json(_text), do: {:error, :not_json}

  defp from_map(%{"version" => @version} = map) do
    with {:ok, revision} <- revision(map["revision"]),
         {:ok, stamp} <- stamp(map["stamp"]),
         {:ok, door} <- door(map["door"]) do
      {:ok, %__MODULE__{revision: revision, stamp: stamp, door: door}}
    end
  end

  defp from_map(%{"version" => version}) when is_integer(version), do: {:error, :version}
  defp from_map(_map), do: {:error, :not_a_build}

  defp revision(revision) when is_integer(revision) and revision >= 0, do: {:ok, revision}
  defp revision(_revision), do: {:error, :revision}

  defp stamp(stamp) when is_binary(stamp), do: {:ok, stamp}
  defp stamp(_stamp), do: {:error, :stamp}

  defp door(nil), do: {:ok, nil}
  defp door(door) when door in @doors, do: {:ok, door}
  defp door(_door), do: {:error, :door}
end
