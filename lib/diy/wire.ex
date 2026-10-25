defmodule DIY.Wire do
  @moduledoc """
  The checks of a wire between two items: its size, and the breaker or the
  fuse at each end. The rules come from the NEC (NFPA 70, the edition of
  2023). The app does not do the work: it tells what the rules ask for.

  A wire here is the pair of conductors of one circuit (the positive and
  the negative, or the hot and the neutral). It goes from the item that
  gives the current (`from`) to a different item (`to`).

  - `system`: "12", "24" or "48" (volts DC), or "120" or "240" (volts AC).
  - `amps`: the most current of the port of `from`, all the time.
  - `feet`: the length of the wire, one way.
  - `two_way`: true when the far end can also give current, as a battery
    or a busbar with a battery on it does. Then the wire needs a breaker or
    a fuse at each end.
  - `awg`, `from_ocpd`, `to_ocpd`, `from_dc`, `to_dc`: what the person has
    (nil: not known yet). The wire size, the rating of the breaker or the
    fuse at each end (A), and its rating for DC (V) on its label.

  The ends tell the smallest fuse that the item at each end takes
  (`from_min`, `to_min`, A): a busbar with fuse holders takes only some
  sizes. On the wire of a battery to a busbar, they also tell the fuse at
  the battery (`bank`).

  The rules:

  - The current all the time is a continuous load: the breaker and the
    wire are at least 125% of it. The rules are NEC 210.19(A) and
    210.20(A) for a branch circuit, and NEC 215.2(A)(1) and 215.3 for a
    feeder.
  - The ampacity of copper wire comes from the 75 °C column of NEC Table
    310.16. The terminals at the two ends must be rated 75 °C (NEC
    110.14(C)).
  - A breaker or a fuse protects the wire: its rating is not more than the
    ampacity of the wire (NEC 240.4). When the ampacity is not a standard
    rating, the next standard rating is permitted (NEC 240.4(B)). Wire of
    14, 12 and 10 AWG takes 15, 20 and 30 A at most (NEC 240.4(D)).
  - The standard ratings come from NEC Table 240.6(A).
  - A breaker or a fuse is at the end where the wire gets its current (NEC
    240.21). A wire between two sources has one at each end: it is
    protected from all the sources (NEC 705.30(A)).
  - On DC, a breaker or a fuse is rated for DC, at the highest voltage of
    the battery or more (NEC 706.31(C) and 110.3(B)). A cell of a LiFePO4
    battery charges to 3.65 V at most (for example, the data sheet of the
    EVE LF280K cell). So a battery of 12 V (4 cells) is at 14.6 V. A
    battery of 24 V (8 cells) is at 29.2 V, and of 48 V (16 cells) at
    58.4 V.
  - The voltage drop is not more than 3% (an informational note of NEC
    210.19(A): advice, not a rule). It uses the DC resistance of stranded
    copper of NEC Chapter 9, Table 8.

  When a battery is at an end, the system of the wire is the voltage of
  the battery. A wire at a busbar is on DC, with the voltage of a battery
  that has a wire to the busbar (`end_system/4`). `DIY.Build` keeps them
  the same.
  """

  @typedoc "A size of copper wire, from 14 AWG to 4/0 AWG."
  @type awg :: String.t()

  @type wire :: %{
          system: String.t(),
          amps: number(),
          feet: number(),
          two_way: boolean(),
          awg: awg() | nil,
          from_ocpd: pos_integer() | nil,
          to_ocpd: pos_integer() | nil,
          from_dc: number() | nil,
          to_dc: number() | nil
        }

  @typedoc """
  The fuse at the battery of a chain: the rating that the person has
  (`fuse`, nil when not known), and the smallest rating for the current
  of the wire of the battery (`least`).
  """
  @type bank :: %{fuse: pos_integer() | nil, least: pos_integer()}

  @type ends :: %{
          required(:from_min) => non_neg_integer(),
          required(:to_min) => non_neg_integer(),
          optional(:free) => [:from | :to],
          optional(:bank) => bank() | nil
        }

  @type advice :: %{
          need: float(),
          from: pos_integer() | nil,
          to: pos_integer() | nil,
          awg: awg() | nil,
          drop: float() | nil,
          highest: float() | nil,
          bank: pos_integer() | nil
        }

  @type fault ::
          {:wire_small, nil, number()}
          | {:ocpd_small, :from | :to, number()}
          | {:ocpd_big, :from | :to, number()}
          | {:no_ocpd, :from | :to, nil}
          | {:dc_rating, :from | :to, number()}
          | {:drop, nil, float()}
          | {:bank_big, nil, pos_integer()}

  # Each size has its ampacity in the 75 °C column of NEC Table 310.16
  # (A). It also has the DC resistance of stranded copper in NEC Chapter
  # 9, Table 8 (ohms for 1000 ft at 75 °C).
  @sizes [
    {"14", 20, 3.14},
    {"12", 25, 1.98},
    {"10", 35, 1.24},
    {"8", 50, 0.778},
    {"6", 65, 0.491},
    {"4", 85, 0.308},
    {"3", 100, 0.245},
    {"2", 115, 0.194},
    {"1", 130, 0.154},
    {"1/0", 150, 0.122},
    {"2/0", 175, 0.0967},
    {"3/0", 200, 0.0766},
    {"4/0", 230, 0.0608}
  ]

  # NEC 240.4(D): the largest breaker or fuse for small copper wire.
  @small %{"14" => 15, "12" => 20, "10" => 30}

  # NEC Table 240.6(A): the standard ratings of fuses and breakers (A).
  @ratings [10, 15, 20, 25, 30, 35, 40, 45, 50, 60, 70, 80, 90, 100, 110, 125, 150, 175, 200] ++
             [225, 250, 300, 350, 400, 450, 500, 600, 700, 800, 1000, 1200, 1600, 2000] ++
             [2500, 3000, 4000, 5000, 6000]

  # The volts of each system, and the cells of a LiFePO4 battery in
  # series on DC.
  @systems %{
    "12" => {12, 4},
    "24" => {24, 8},
    "48" => {48, 16},
    "120" => {120, nil},
    "240" => {240, nil}
  }

  # The highest volts of a LiFePO4 cell, when it is full.
  @cell_volts 3.65

  @continuous 1.25
  @max_drop 3.0

  @doc "The sizes of wire, from the smallest to the largest."
  @spec sizes() :: [awg()]
  def sizes, do: Enum.map(@sizes, &elem(&1, 0))

  @doc "The systems: their keys, from 12 V DC to 240 V AC."
  @spec systems() :: [String.t()]
  def systems, do: ~w(12 24 48 120 240)

  @doc "True for a system of DC."
  @spec dc?(String.t()) :: boolean()
  def dc?(system), do: system in ~w(12 24 48)

  @doc "The volts of a system."
  @spec volts(String.t()) :: pos_integer()
  def volts(system), do: elem(Map.fetch!(@systems, system), 0)

  @doc "The cells in series of a LiFePO4 battery of the system, or nil on AC."
  @spec cells(String.t()) :: pos_integer() | nil
  def cells(system), do: elem(Map.fetch!(@systems, system), 1)

  @doc "The highest volts of a LiFePO4 battery of the system, or nil on AC."
  @spec highest(String.t()) :: float() | nil
  def highest(system) do
    case cells(system) do
      nil -> nil
      cells -> Float.round(cells * @cell_volts, 2)
    end
  end

  @doc "The standard ratings of NEC Table 240.6(A)."
  @spec ratings() :: [pos_integer()]
  def ratings, do: @ratings

  @doc "The ampacity of a size, in the 75 °C column (A)."
  @spec ampacity(awg()) :: pos_integer()
  def ampacity(awg), do: elem(size(awg), 1)

  @doc """
  The largest breaker or fuse that protects a size of wire (A). For small
  wire, it is the limit of NEC 240.4(D). Else it is the ampacity, or the
  next standard rating (NEC 240.4(B)).
  """
  @spec largest(awg()) :: pos_integer()
  def largest(awg), do: Map.get(@small, awg) || rating(ampacity(awg))

  @doc "The current of a wire with the margin of a load all the time (A)."
  @spec need(wire()) :: float()
  def need(wire), do: wire.amps * @continuous

  @doc "The smallest standard rating at or above some amps."
  @spec rating(number()) :: pos_integer()
  def rating(amps), do: Enum.find(@ratings, &(&1 >= amps))

  @doc """
  The voltage drop of a wire in percent: the current goes out and comes
  back, so the length of copper is two times the run.
  """
  @spec drop(awg(), number(), number(), String.t()) :: float()
  def drop(awg, amps, feet, system) do
    ohms = elem(size(awg), 2) * 2 * feet / 1000
    amps * ohms / volts(system) * 100
  end

  defp size(awg), do: List.keyfind(@sizes, awg, 0) || raise(ArgumentError, "no size #{awg}")

  # The kinds that can feed a fault at the far end: a battery, and a
  # busbar (it has a battery on it).
  @two_way ~w(van_battery dc_bus battery_switch battery_monitor)

  # The parts of a busbar: a busbar, and the parts on the wire of a battery
  # to a busbar. These parts are a battery switch and a battery monitor.
  # Their wires have the voltage of the batteries of their node.
  @bus ~w(dc_bus battery_switch battery_monitor)

  # The parts on the wire of a battery to a busbar. The fuse at the
  # battery protects this wire to the busbar: these parts have no fuse.
  @inline ~w(battery_switch battery_monitor)

  @doc "True for a busbar, or a part on the wire of a battery to a busbar."
  @spec bus?(map()) :: boolean()
  def bus?(item), do: item.type in @bus

  @doc "True for an item that can give current at the far end of a wire."
  @spec gives_current?(map()) :: boolean()
  def gives_current?(item), do: item.type in @two_way

  @doc """
  The system of a wire with a battery at an end: the voltage of the
  battery ("12", "24" or "48"). It is nil with no battery at the ends.
  """
  @spec battery_system(map(), map()) :: String.t() | nil
  def battery_system(from, to) do
    case Enum.find([from, to], &(&1.type == "van_battery")) do
      nil -> nil
      battery -> battery.params["volts"]
    end
  end

  @doc """
  The system of a wire from its ends:

  - the voltage of a battery at an end. A battery joined to a battery of
    a higher voltage (through a busbar or a wire) is a fault. Then each
    wire of the battery gets the higher voltage, because the DC ratings
    must be for it;
  - else the voltage of the battery of a busbar at an end;
  - else 12 V DC at a busbar that has no battery, when the system was AC:
    a busbar is on DC;
  - else the system that the wire has.

  `highs` gives the system of each busbar with a battery, and of each
  battery joined to a battery of a higher voltage, by their ids.
  """
  @spec end_system(String.t(), map(), map(), %{String.t() => String.t()}) :: String.t()
  def end_system(system, from, to, highs) do
    bus = Enum.find_value([from, to], &(bus?(&1) and highs[&1.id]))
    battery = Enum.find([from, to], &(&1.type == "van_battery"))

    cond do
      battery ->
        own = battery.params["volts"]
        Enum.max_by([own, highs[Map.get(battery, :id)] || own, bus || own], &volts/1)

      bus ->
        bus

      Enum.any?([from, to], &bus?/1) and not dc?(system) ->
        "12"

      true ->
        system
    end
  end

  @doc """
  The typical numbers of a new wire from an item to an item: 30 A and 6
  ft. The system is the system of a battery at an end. At a busbar, a
  battery switch or a battery monitor, it is 12 V DC. At a transfer switch or a shore power inlet, it is 120 V AC.
  Else it is 12 V DC. On DC, a wire to a battery or to a busbar has two ways.
  The person has nothing yet.
  """
  @spec defaults(map(), map()) :: wire()
  def defaults(from, to) do
    system =
      cond do
        system = battery_system(from, to) -> system
        Enum.any?([from, to], &bus?/1) -> "12"
        Enum.any?([from, to], &(&1.type in ~w(transfer_switch shore_power))) -> "120"
        true -> "12"
      end

    %{
      system: system,
      amps: 30.0,
      feet: 6.0,
      two_way: dc?(system) and gives_current?(to),
      awg: nil,
      from_ocpd: nil,
      to_ocpd: nil,
      from_dc: nil,
      to_dc: nil
    }
  end

  @doc """
  The ends of a wire, for the advice and the check:

  - `from_min` and `to_min`: the smallest fuse that the item at each end
    takes (A): the number of a busbar, else 0;
  - `bank`: the fuse at the battery of the chain of the wire, or nil (see
    `inline?/1`);
  - `free`: the ends that need no breaker. A wire with an end at a battery
    switch or a battery monitor is on the wire of a battery to a busbar.
    When a battery is on this chain, the fuse at the battery protects all
    of it (for example a class T fuse). So only its end at a battery needs
    a breaker. Each wire of the chain must then carry the fuse at the
    battery.
  """
  @spec ends(map(), map(), bank() | nil) :: ends()
  def ends(from, to, bank \\ nil) do
    chain = bank != nil and (inline?(from) or inline?(to))

    free =
      for {side, item} <- [from: from, to: to], chain and item.type != "van_battery", do: side

    %{from_min: fuse_min(from), to_min: fuse_min(to), free: free, bank: if(chain, do: bank)}
  end

  @doc """
  True for a part on the wire of a battery to a busbar: a battery switch or
  a battery monitor. The fuse at the battery protects the wires of these
  parts (`DIY.Build.wire_ends/2` finds it).
  """
  @spec inline?(map()) :: boolean()
  def inline?(item), do: item.type in @inline

  defp fuse_min(%{type: "dc_bus", params: params}), do: params["fuse_min"]
  defp fuse_min(_item), do: 0

  # The numbers of a wire, and their ranges. A form gives text, and a
  # stored build gives JSON. An empty text is nil (not known).
  @fields [
    system: {:choice, ~w(12 24 48 120 240)},
    amps: {:float, 1, 1000},
    feet: {:float, 1, 500},
    two_way: :bool,
    awg: {:maybe, {:choice, Enum.map(@sizes, &elem(&1, 0))}},
    from_ocpd: {:maybe, {:int, 1, 2000}},
    to_ocpd: {:maybe, {:int, 1, 2000}},
    from_dc: {:maybe, {:int, 1, 1500}},
    to_dc: {:maybe, {:int, 1, 1500}}
  ]

  # The longest text of a number. A longer text is not valid: the parse of
  # a very long text costs much time.
  @max_text 32

  @doc """
  Reads the numbers of a wire from a map with text keys (a form or JSON).
  The map changes the numbers of a wire (`base`). A key that is not in
  the map keeps its value. The error names the first number that is not
  valid. A text of more than 32 bytes is not valid.
  """
  @spec read(map(), wire()) :: {:ok, wire()} | {:error, atom()}
  def read(values, base) when is_map(values) do
    Enum.reduce_while(@fields, {:ok, base}, fn {key, type}, {:ok, wire} ->
      case Map.fetch(values, Atom.to_string(key)) do
        :error ->
          {:cont, {:ok, wire}}

        {:ok, value} ->
          case cast(type, value) do
            {:ok, value} -> {:cont, {:ok, Map.put(wire, key, value)}}
            :error -> {:halt, {:error, key}}
          end
      end
    end)
  end

  defp cast(_type, value) when is_binary(value) and byte_size(value) > @max_text, do: :error
  defp cast({:maybe, _type}, nil), do: {:ok, nil}

  defp cast({:maybe, type}, value) when is_binary(value) do
    if String.trim(value) == "", do: {:ok, nil}, else: cast(type, value)
  end

  defp cast({:maybe, type}, value), do: cast(type, value)

  defp cast({:choice, keys}, value) when is_binary(value),
    do: if(value in keys, do: {:ok, value}, else: :error)

  defp cast(:bool, value) when is_boolean(value), do: {:ok, value}
  defp cast(:bool, "true"), do: {:ok, true}
  defp cast(:bool, "false"), do: {:ok, false}

  defp cast({:int, min, max}, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> cast({:int, min, max}, int)
      _ -> :error
    end
  end

  defp cast({:int, min, max}, value) when is_integer(value) and value >= min and value <= max,
    do: {:ok, value}

  defp cast({:float, min, max}, value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> cast({:float, min, max}, float)
      _ -> :error
    end
  end

  defp cast({:float, min, max}, value) when is_number(value) and value >= min and value <= max,
    do: {:ok, value / 1}

  defp cast(_type, _value), do: :error

  @doc """
  True when the wire needs a breaker or a fuse at the far end: on DC, when
  the far end gives current too. On AC, a wire has one way here.
  """
  @spec two_way?(wire()) :: boolean()
  def two_way?(wire), do: wire.two_way and dc?(wire.system)

  @doc """
  What the rules ask for:

  - `need`: the current with the margin;
  - `from` and `to`: the smallest breaker or fuse at each end (`to` is nil
    when the far end gives no current);
  - `awg` and `drop`: the smallest wire that the breakers protect, with a
    drop of 3% or less, and its drop. They are nil when no size of 4/0 or
    less is enough;
  - `highest`: the highest volts for the DC rating (nil on AC);
  - `bank`: on the wire of a battery to a busbar, the fuse at the battery
    that protects the wire (the fuse of the person, else the smallest
    rating). The wire must carry it. Else nil.
  """
  @spec advise(wire(), ends()) :: advice()
  def advise(wire, ends) do
    need = need(wire)
    free = Map.get(ends, :free, [])
    from = if :from not in free, do: rating(max(need, ends.from_min))
    to = if two_way?(wire) and :to not in free, do: rating(max(need, ends.to_min))
    bank = bank_fuse(ends)

    awg =
      Enum.find(sizes(), fn awg ->
        ampacity(awg) >= need and largest(awg) >= max(max(from || 0, to || 0), bank || 0) and
          drop(awg, wire.amps, wire.feet, wire.system) <= @max_drop
      end)

    %{
      need: need,
      from: from,
      to: to,
      awg: awg,
      drop: awg && drop(awg, wire.amps, wire.feet, wire.system),
      highest: highest(wire.system),
      bank: bank
    }
  end

  defp bank_fuse(%{free: [_ | _], bank: %{fuse: fuse, least: least}}), do: fuse || least
  defp bank_fuse(_ends), do: nil

  @doc """
  The faults of what the person has, in the order of the rules. Each
  fault names its end (`:from`, `:to`, or nil for the wire) and a
  number:

  - `:wire_small`: the ampacity of the wire is less than the need. The
    number is the need.
  - `:ocpd_small`: the breaker is less than the need: it trips at the
    normal current. The number is the need.
  - `:ocpd_big`: the breaker is more than the wire takes: it does not
    protect the wire. The number is the largest that the wire takes.
  - `:no_ocpd`: the wire has no breaker at an end that gives current.
  - `:dc_rating`: the DC rating of the breaker is less than the highest
    volts of the battery. The number is the highest volts.
  - `:drop`: the drop is more than 3% (advice). The number is the drop.
  - `:bank_big`: on the wire of a battery to a busbar, the fuse at the
    battery is more than the wire takes: it does not protect the wire. The
    number is the fuse at the battery.

  A check needs its values: with no wire size, the app checks only the
  breakers. An end that needs no breaker (`free` of `ends/2`) has no
  fault of a breaker.
  """
  @spec check(wire(), ends()) :: [fault()]
  def check(wire, ends \\ %{from_min: 0, to_min: 0}) do
    need = need(wire)
    free = Map.get(ends, :free, [])
    sides = if(two_way?(wire), do: [:from, :to], else: [:from]) -- free

    wire_small(wire, need) ++
      Enum.flat_map(sides, &ocpd_faults(wire, &1, need)) ++
      bank_fault(wire, free, ends[:bank]) ++
      drop_fault(wire)
  end

  # The fuse at the battery protects the free ends: the wire must carry it.
  defp bank_fault(%{awg: awg}, [_ | _], %{fuse: fuse})
       when is_binary(awg) and is_integer(fuse) do
    if fuse > largest(awg), do: [{:bank_big, nil, fuse}], else: []
  end

  defp bank_fault(_wire, _free, _bank), do: []

  defp wire_small(%{awg: nil}, _need), do: []

  defp wire_small(%{awg: awg}, need),
    do: if(ampacity(awg) < need, do: [{:wire_small, nil, need}], else: [])

  defp ocpd_faults(wire, side, need) do
    ocpd = Map.fetch!(wire, ocpd_key(side))
    dc = Map.fetch!(wire, dc_key(side))
    highest = highest(wire.system)

    cond do
      is_nil(ocpd) and wire.awg ->
        [{:no_ocpd, side, nil}]

      is_nil(ocpd) ->
        []

      true ->
        Enum.filter(
          [
            ocpd < need && {:ocpd_small, side, need},
            wire.awg && ocpd > largest(wire.awg) && {:ocpd_big, side, largest(wire.awg)},
            highest && dc && dc < highest && {:dc_rating, side, highest}
          ],
          & &1
        )
    end
  end

  defp ocpd_key(:from), do: :from_ocpd
  defp ocpd_key(:to), do: :to_ocpd

  defp dc_key(:from), do: :from_dc
  defp dc_key(:to), do: :to_dc

  defp drop_fault(%{awg: nil}), do: []

  defp drop_fault(wire) do
    drop = drop(wire.awg, wire.amps, wire.feet, wire.system)
    if drop > @max_drop, do: [{:drop, nil, drop}], else: []
  end
end
