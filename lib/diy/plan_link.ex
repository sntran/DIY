defmodule DIY.PlanLink do
  @moduledoc """
  The link of plans to compare (docs/design.md, "A link of plans"): the
  path `/p/DATA`. `DATA` is the version of the format (`1`), then the
  plans as JSON, compressed with raw DEFLATE, in base64url (`DIY.Pack`).

  The link carries the numbers of 1 to 6 plans of the worksheet
  (`DIY.Plan`): their names, their charges, their credits and their
  fees. It has no house, no months and no ZIP code. The person who opens
  it sees the plans with the months of their own house.

  The server keeps no copy of the plans: it reads them only to answer
  the request of the link.
  """

  alias DIY.Plan

  @version "1"

  # The most plans of a link: the chart of the preview shows each one.
  @max_plans 6

  # The largest DATA, and the largest JSON after the inflate. Two plans
  # give a DATA of about 250 characters. A name has 60 letters at most,
  # but a letter can have many marks: thus the link checks its size.
  @max_data 6_000
  @max_json 16 * 1024

  @doc "The most plans of a link."
  def max_plans, do: @max_plans

  @doc """
  The `DATA` of the link of plans. A link has 1 to 6 plans: other lists
  give `{:error, :plans}`. The link has no id of a plan and no averages
  of an EFL. Plans that a link cannot carry give `{:error, :too_large}`.
  """
  @spec encode([Plan.t()]) :: {:ok, String.t()} | {:error, :plans | :too_large}
  def encode([_ | _] = plans) when length(plans) <= @max_plans do
    maps = for p <- plans, do: p |> Plan.to_map() |> Map.drop(["id", "averages"])
    json = Jason.encode!(%{"p" => maps})
    data = DIY.Pack.encode(json)

    if byte_size(json) <= @max_json and byte_size(data) < @max_data,
      do: {:ok, @version <> data},
      else: {:error, :too_large}
  end

  def encode(_plans), do: {:error, :plans}

  @doc """
  Reads the `DATA` of a link. Gives `{:ok, plans}`, with the ids `p1`,
  `p2` and so on, or `{:error, reason}` for a text that is not a link of
  plans. Each plan must be a plan that a build can keep
  (`DIY.Plan.read/1`).
  """
  @spec decode(term()) :: {:ok, [Plan.t()]} | {:error, atom()}
  def decode(@version <> data) when byte_size(data) < @max_data do
    with {:ok, json} <- DIY.Pack.decode(data, @max_json),
         {:ok, %{"p" => [_ | _] = maps}} when length(maps) <= @max_plans <- Jason.decode(json) do
      read(maps)
    else
      {:ok, _other} -> {:error, :not_plans}
      {:error, %Jason.DecodeError{}} -> {:error, :json}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode(@version <> _data), do: {:error, :too_long}
  def decode(_data), do: {:error, :version}

  defp read(maps) do
    maps
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {map, n}, {:ok, acc} ->
      with true <- is_map(map),
           {:ok, plan} <- Plan.read(Map.merge(map, %{"id" => "p#{n}", "averages" => nil})) do
        {:cont, {:ok, acc ++ [plan]}}
      else
        _bad -> {:halt, {:error, :plan}}
      end
    end)
  end
end
