defmodule DIYWeb.Wires do
  @moduledoc """
  The wires of an item, in its panel (`DIYWeb.Inside.item_stage/1`). Each
  wire with the item at one end shows its numbers. It shows what the rules
  of the NEC ask for, and the faults of what the person has
  (`DIY.Wire`). The person adds a wire from the item to a different item
  that takes wires.

  The app does not do the work. It does not replace an electrician or an
  inspector. It tells the rules, so that the person can ask the right
  questions.
  """
  use DIYWeb, :html

  alias DIY.{Build, Catalog, Wire}
  alias DIYWeb.Format

  @systems [
    {"12", "12 V DC"},
    {"24", "24 V DC"},
    {"48", "48 V DC"},
    {"120", "120 V AC"},
    {"240", "240 V AC"}
  ]

  # The range of each number, for the text of an error, and true for a
  # whole number.
  @ranges %{
    amps: {1, 1000, false},
    feet: {1, 500, false},
    from_ocpd: {1, 2000, true},
    to_ocpd: {1, 2000, true},
    from_dc: {1, 1500, true},
    to_dc: {1, 1500, true}
  }

  attr :build, :map, required: true
  attr :item, :map, required: true
  attr :error, :any, default: nil, doc: "`{:wire, id, key}`: a number of a wire that is not valid"

  @doc """
  The part Wires of the panel of an item. It shows the wires with the
  other end in the same place (`DIY.Build.world/2`). A wire to a station
  that is in the other place waits: it shows again when the station comes
  back.
  """
  def section(assigns) do
    build = assigns.build
    by_id = Map.new(build.items, &{&1.id, &1})
    world = Build.world(build, assigns.item)

    wires =
      for wire <- Build.wires_of(build, assigns.item.id),
          from = by_id[wire.from],
          to = by_id[wire.to],
          Build.world(build, from) == Build.world(build, to),
          do: {wire, from, to}

    # Two wires between the same two items get a number in their title.
    pairs = Enum.frequencies_by(wires, fn {wire, _from, _to} -> pair(wire) end)

    {wires, _seen} =
      Enum.map_reduce(wires, %{}, fn {wire, from, to}, seen ->
        n = Map.get(seen, pair(wire), 0) + 1
        title = "#{Catalog.name(from)} to #{Catalog.name(to)}"
        title = if pairs[pair(wire)] > 1, do: "#{title}, wire #{n}", else: title
        {{wire, from, to, title}, Map.put(seen, pair(wire), n)}
      end)

    others =
      for other <- build.items,
          other.id != assigns.item.id and Build.wired?(other),
          Build.world(build, other) == world,
          do: other

    # A busbar has a number of positions for wires.
    ports = if assigns.item.type == "dc_bus", do: assigns.item.params["ports"]

    {build_max, item_max} = Build.max_wires()

    full =
      cond do
        length(build.wires) >= build_max -> :build
        Build.wires_full?(build, assigns.item.id) -> :item
        true -> nil
      end

    assigns =
      assign(assigns,
        wires: wires,
        others: Enum.reject(others, &Build.wires_full?(build, &1.id)),
        any_other: others != [],
        full: full,
        build_max: build_max,
        item_max: item_max,
        buses: Build.bus_systems(build),
        ports: ports,
        used: length(wires),
        world: world
      )

    ~H"""
    <section id="part-wires" class="stage-sec" aria-labelledby="part-wires-title">
      <h3 id="part-wires-title" class="stage-sec-title" tabindex="-1">Wires</h3>
      <p class="stage-help">
        The app checks each wire with the rules of the NEC, the National Electrical Code (2023). It does not replace an electrician or the inspector of your city.
      </p>
      <p
        :if={@ports}
        id="wire-ports"
        role="status"
        class={if @used > @ports, do: "wire-over", else: "stage-help"}
      >
        {ports_text(@used, @ports)}
      </p>
      <.wire
        :for={{wire, from, to, title} <- @wires}
        wire={wire}
        from={from}
        to={to}
        title={title}
        buses={@buses}
        error={wire_error(@error, wire.id)}
      />
      <form
        :if={@others != [] and is_nil(@full)}
        id="add-wire"
        phx-submit="add_wire"
        class="stage-field"
      >
        <input type="hidden" name="from" value={@item.id} />
        <label for="wire-to" class="stage-label">Add a wire from this item to</label>
        <div class="wire-add">
          <select id="wire-to" name="to" class="stage-input">
            <option :for={other <- @others} value={other.id}>{place_name(@build, other)}</option>
          </select>
          <button type="submit" id="add-wire-button" class="stage-btn">Add</button>
        </div>
      </form>
      <p :if={@full || (@any_other and @others == [])} id="wire-full" class="stage-help">
        {full_text(@full, @build_max, @item_max)}
      </p>
      <p :if={not @any_other} id="wire-none" class="stage-help">
        {none_text(@world)}
      </p>
    </section>
    """
  end

  defp pair(wire), do: Enum.sort([wire.from, wire.to])

  # Why the person cannot add a wire: the build, this item, or each other
  # item has its most wires.
  defp full_text(:build, max, _item_max),
    do: "The build has #{max} wires, the most for a build. Remove a wire to add a different one."

  defp full_text(:item, _max, max),
    do:
      "This item has #{max} wires, the most for an item. Remove a wire of this item to add a different one."

  defp full_text(nil, _max, max),
    do: "Each other item that takes wires here has #{max} wires, the most for an item."

  # The kinds that take wires in each place (`DIY.Catalog`).
  defp none_text(:house),
    do: "Add a second item that takes wires: a power station, a busbar or a transfer switch."

  defp none_text(_van),
    do:
      "Add a second item that takes wires: a battery, a busbar, an inverter, a power station, an alternator charger or a shore power inlet."

  @doc """
  The text of the positions of a busbar: how many have a wire. When more
  wires connect to it than it has positions, it is a fault.
  """
  def ports_text(used, ports) when used > ports,
    do:
      "#{used} wires connect to the busbar, and it has #{Format.count(ports, "position")} for wires. Connect fewer wires, or use a larger busbar."

  def ports_text(0, ports),
    do: "It has #{Format.count(ports, "position")} for wires. No position has a wire yet."

  def ports_text(1, ports),
    do: "It has #{Format.count(ports, "position")} for wires. 1 of them has a wire."

  def ports_text(used, ports),
    do: "It has #{Format.count(ports, "position")} for wires. #{used} of them have a wire."

  defp wire_error({:wire, id, key}, id), do: key
  defp wire_error(_error, _id), do: nil

  attr :wire, :map, required: true
  attr :from, :map, required: true
  attr :to, :map, required: true
  attr :title, :string, required: true
  attr :buses, :map, required: true, doc: "the system of each busbar with a battery"
  attr :error, :atom, default: nil

  defp wire(assigns) do
    %{wire: wire, from: from, to: to} = assigns
    two_way = Wire.two_way?(wire)
    advice = Wire.advise(wire, Wire.ends(from, to))
    battery = Enum.find([from, to], &(&1.type == "van_battery"))
    buses = assigns.buses
    bus = Enum.find([from, to], &(&1.type == "dc_bus"))
    names = %{from.id => Catalog.name(from), to.id => Catalog.name(to)}

    assigns =
      assign(assigns,
        id: "wire-#{wire.id}",
        dc: Wire.dc?(wire.system),
        two_way: two_way,
        advice: advice,
        largest: advice.awg && Wire.largest(advice.awg),
        faults: Wire.check(wire),
        has: Enum.any?([wire.awg, wire.from_ocpd, wire.to_ocpd]),
        from_name: names[from.id],
        to_name: names[to.id],
        # The ends in a fixed order: a change of the source changes only
        # the radio that is on.
        ends: names |> Enum.sort() |> Enum.with_index(),
        battery: battery && Catalog.name(battery),
        lead_acid: battery && battery.params["chemistry"] == "agm",
        # A busbar with a battery gives its voltage. A busbar with no
        # battery is on DC.
        bus: if(bus && Map.has_key?(buses, bus.id), do: Catalog.name(bus)),
        choices: if(bus, do: Enum.filter(@systems, &Wire.dc?(elem(&1, 0))), else: @systems)
      )

    ~H"""
    <article id={@id} class="wire" aria-labelledby={"#{@id}-title"}>
      <h4 id={"#{@id}-title"} class="wire-title">{@title}</h4>
      <form id={"#{@id}-form"} phx-change="wire" phx-submit="wire" class="stage-fields">
        <input type="hidden" name="wire_id" value={@wire.id} />
        <fieldset class="stage-field">
          <legend class="stage-label">The current comes from</legend>
          <div class="stage-choices">
            <label :for={{{end_id, name}, n} <- @ends} class="stage-choice">
              <input
                type="radio"
                id={"#{@id}-end-#{n}"}
                name="wire[from]"
                value={end_id}
                checked={end_id == @from.id}
              />
              <span>{name}</span>
            </label>
          </div>
        </fieldset>
        <div :if={is_nil(@battery) and is_nil(@bus)} class="stage-field">
          <label for={"#{@id}-system"} class="stage-label">System</label>
          <select id={"#{@id}-system"} name="wire[system]" class="stage-input">
            <option :for={{key, label} <- @choices} value={key} selected={key == @wire.system}>
              {label}
            </option>
          </select>
        </div>
        <p :if={@battery} id={"#{@id}-system"} class="stage-help">
          System: {system_name(@wire.system)}, the voltage of {@battery}. Change it in the part of the battery.
        </p>
        <p :if={is_nil(@battery) and @bus} id={"#{@id}-system"} class="stage-help">
          System: {system_name(@wire.system)}, the voltage of the battery at {@bus}. Change it in the part of the battery.
        </p>
        <p :if={@lead_acid} id={"#{@id}-lead-acid"} class="stage-help">
          {@battery} is lead acid. The app uses the voltages of LiFePO4: ask the maker of the battery for its highest voltage.
        </p>
        <.number
          id={"#{@id}-amps"}
          name="wire[amps]"
          label="The most current of the port"
          unit="A"
          value={@wire.amps}
          help="The label or the manual of the port gives it. The app takes it as a load all the time."
          error={@error == :amps && range(:amps)}
        />
        <.number
          id={"#{@id}-feet"}
          name="wire[feet]"
          label="Length, one way"
          unit="ft"
          value={@wire.feet}
          error={@error == :feet && range(:feet)}
        />
        <label :if={@dc} class="stage-switch-row">
          <span>The far end also gives current: a battery, or a busbar with a battery</span>
          <input type="hidden" name="wire[two_way]" value="false" />
          <input
            type="checkbox"
            role="switch"
            name="wire[two_way]"
            value="true"
            checked={@wire.two_way}
            class="stage-switch"
          />
        </label>
      </form>

      <div id={"#{@id}-advice"} class="wire-advice">
        <p class="wire-head">What the rules ask for</p>
        <ul class="stage-list">
          <li>
            Current: 125% of {amps(@wire.amps)} A is {amps(@advice.need)} A. This is for a load all the time: 3 hours or more (NEC Article 100, 210.19(A) and 215.2(A)(1)).
          </li>
          <li :if={@advice.awg}>
            Wire: {@advice.awg} AWG copper or larger, rated 75 °C, with terminals of 75 °C. With it, the voltage drop is {percent(
              @advice.drop
            )}.
          </li>
          <li :if={is_nil(@advice.awg)}>
            Wire: no single wire of 4/0 AWG or less is enough. Ask an electrician.
          </li>
          <li>At {@from_name}: {ocpd_text(@advice.from, @largest, @advice.highest)}</li>
          <li :if={@two_way}>At {@to_name}: {ocpd_text(@advice.to, @largest, @advice.highest)}</li>
        </ul>
        <p :if={@two_way and @advice.to > Wire.rating(@advice.need)} class="stage-help">
          {@to_name} takes no fuse less than {@advice.to} A: the wire must carry it.
        </p>
        <p :if={@advice.highest} class="stage-help">
          {volts(@advice.highest)} V is the voltage of a full LiFePO4 battery of {system_name(
            @wire.system
          )}: {Wire.cells(@wire.system)} cells at 3.65 V.
        </p>
      </div>

      <form id={"#{@id}-has"} phx-change="wire" phx-submit="wire" class="stage-fields">
        <input type="hidden" name="wire_id" value={@wire.id} />
        <p class="wire-head">What you have</p>
        <div class="stage-field">
          <label for={"#{@id}-awg"} class="stage-label">Wire size</label>
          <select id={"#{@id}-awg"} name="wire[awg]" class="stage-input">
            <option value="" selected={is_nil(@wire.awg)}>Not known yet</option>
            <option :for={awg <- Wire.sizes()} value={awg} selected={awg == @wire.awg}>
              {awg} AWG
            </option>
          </select>
        </div>
        <fieldset id={"#{@id}-from-end"} class="stage-fields wire-end">
          <legend class="wire-head">At {@from_name}</legend>
          <.number
            id={"#{@id}-from-ocpd"}
            name="wire[from_ocpd]"
            label="Breaker or fuse"
            unit="A"
            value={@wire.from_ocpd}
            whole
            error={@error == :from_ocpd && range(:from_ocpd)}
          />
          <.number
            :if={@dc}
            id={"#{@id}-from-dc"}
            name="wire[from_dc]"
            label="Its DC rating, on its label"
            unit="V"
            value={@wire.from_dc}
            whole
            error={@error == :from_dc && range(:from_dc)}
          />
        </fieldset>
        <fieldset :if={@two_way} id={"#{@id}-to-end"} class="stage-fields wire-end">
          <legend class="wire-head">At {@to_name}</legend>
          <.number
            id={"#{@id}-to-ocpd"}
            name="wire[to_ocpd]"
            label="Breaker or fuse"
            unit="A"
            value={@wire.to_ocpd}
            whole
            error={@error == :to_ocpd && range(:to_ocpd)}
          />
          <.number
            id={"#{@id}-to-dc"}
            name="wire[to_dc]"
            label="Its DC rating, on its label"
            unit="V"
            value={@wire.to_dc}
            whole
            error={@error == :to_dc && range(:to_dc)}
          />
        </fieldset>
      </form>

      <div id={"#{@id}-check"} role="status">
        <ul :if={@faults != []} class="wire-faults">
          <li :for={fault <- @faults}>
            {fault_text(fault, @wire, @from_name, @to_name)}
          </li>
        </ul>
        <p :if={@faults == [] and @has} class="wire-ok">
          What you have meets these rules.
        </p>
      </div>

      <div class="stage-remove">
        <button
          type="button"
          id={"#{@id}-ask-remove"}
          phx-click={
            JS.hide()
            |> JS.show(to: "##{@id}-confirm", display: "flex")
            |> JS.focus(to: "##{@id}-keep")
          }
          class="stage-btn stage-danger"
        >
          Remove the wire
        </button>
        <div
          id={"#{@id}-confirm"}
          class="stage-confirm hidden"
          role="group"
          aria-labelledby={"#{@id}-remove-text"}
        >
          <p id={"#{@id}-remove-text"}>Remove this wire: {@title}?</p>
          <button
            type="button"
            id={"#{@id}-remove"}
            phx-click={
              JS.push("delete_wire", value: %{id: @wire.id})
              |> JS.focus(to: "#part-wires-title")
            }
            class="stage-btn stage-danger"
          >
            Remove
          </button>
          <button
            type="button"
            id={"#{@id}-keep"}
            phx-click={
              JS.hide(to: "##{@id}-confirm")
              |> JS.show(to: "##{@id}-ask-remove")
              |> JS.focus(to: "##{@id}-ask-remove")
            }
            class="stage-btn"
          >
            Keep it
          </button>
        </div>
      </div>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :unit, :string, required: true
  attr :value, :any, required: true
  attr :help, :string, default: nil
  attr :whole, :boolean, default: false, doc: "true for a whole number"
  attr :error, :any, default: false, doc: "the text of the error, or false"

  # A number of a wire: a field and its unit. An empty field is a number
  # that is not known yet.
  defp number(assigns) do
    described =
      Enum.filter(
        [
          "#{assigns.id}-unit",
          assigns.help && "#{assigns.id}-help",
          assigns.error && "#{assigns.id}-error"
        ],
        & &1
      )

    assigns = assign(assigns, :described, Enum.join(described, " "))

    ~H"""
    <div class="stage-field">
      <label for={@id} class="stage-label">{@label}</label>
      <div class="wire-number">
        <input
          id={@id}
          name={@name}
          value={Format.value(@value)}
          type="number"
          step={if @whole, do: "1", else: "any"}
          inputmode={if @whole, do: "numeric", else: "decimal"}
          phx-debounce="400"
          aria-invalid={@error && "true"}
          aria-describedby={@described}
          class="stage-input"
        />
        <span id={"#{@id}-unit"} class="stage-unit">{@unit}</span>
      </div>
      <p :if={@error} id={"#{@id}-error"} class="stage-error">{@error}</p>
      <p :if={@help} id={"#{@id}-help"} class="stage-help">{@help}</p>
    </div>
    """
  end

  defp system_name(system), do: @systems |> List.keyfind(system, 0) |> elem(1)

  defp range(key) do
    case Map.fetch!(@ranges, key) do
      {min, max, true} -> "Give a whole number from #{min} to #{max}, or nothing."
      {min, max, false} -> "Give a number from #{min} to #{max}, or nothing."
    end
  end

  # The name of an item with its room, for the list of the ends.
  defp place_name(build, item) do
    {:ok, room} = Build.room(build, item.room)
    "#{Catalog.name(item)}, in #{room.name}"
  end

  defp percent(drop), do: "#{:erlang.float_to_binary(drop / 1, decimals: 1)}%"

  @doc """
  The text of the breaker or the fuse at an end. It has the smallest
  rating and the largest that the wire takes. On DC, it has the DC
  rating.
  """
  def ocpd_text(least, largest, highest) do
    range =
      if is_nil(largest) or largest <= least,
        do: "a breaker or a fuse of #{least} A",
        else: "a breaker or a fuse of #{least} A to #{largest} A"

    dc = if highest, do: ", rated for DC at #{volts(highest)} V or more", else: ""
    range <> dc <> "."
  end

  defp volts(v), do: :erlang.float_to_binary(v / 1, decimals: 1)

  @doc "The text of a fault of `DIY.Wire.check/1`."
  def fault_text({:wire_small, nil, need}, wire, _from, _to),
    do:
      "The wire is too small: #{wire.awg} AWG carries #{Wire.ampacity(wire.awg)} A, and the wire needs #{amps(need)} A. This is 125% of #{amps(wire.amps)} A (NEC 210.19(A) and 215.2(A)(1))."

  def fault_text({:ocpd_small, side, need}, wire, from, to),
    do:
      "The breaker or the fuse at #{name(side, from, to)} is too small: #{ocpd(wire, side)} A is less than #{amps(need)} A. It can open at the normal current (NEC 210.20(A) and 215.3)."

  def fault_text({:ocpd_big, side, largest}, wire, from, to),
    do:
      "The breaker or the fuse at #{name(side, from, to)} does not protect the wire: #{wire.awg} AWG takes #{largest} A at most, and it is #{ocpd(wire, side)} A. Use a larger wire or a smaller breaker (NEC 240.4)."

  def fault_text({:no_ocpd, :from, nil}, _wire, from, _to),
    do:
      "The wire has no breaker or fuse at #{from}. A fault on the wire can then start a fire (NEC 240.21)."

  def fault_text({:no_ocpd, :to, nil}, _wire, _from, to),
    do:
      "The wire has no breaker or fuse at #{to}. That end also gives current: it can feed a fault on the wire (NEC 705.30(A))."

  def fault_text({:dc_rating, side, highest}, wire, from, to),
    do:
      "The breaker or the fuse at #{name(side, from, to)} has a DC rating of #{dc(wire, side)} V. The system can have #{volts(highest)} V (a full LiFePO4 battery): the breaker can fail to stop a fault. Use one for #{volts(highest)} V DC or more (NEC 706.31(C))."

  def fault_text({:drop, nil, drop}, _wire, _from, _to),
    do:
      "The voltage drop is #{percent(drop)}. The NEC advises 3% or less: use a larger wire or a shorter wire (an informational note of NEC 210.19(A))."

  defp name(:from, from, _to), do: from
  defp name(:to, _from, to), do: to

  defp ocpd(wire, :from), do: wire.from_ocpd
  defp ocpd(wire, :to), do: wire.to_ocpd

  defp dc(wire, :from), do: wire.from_dc
  defp dc(wire, :to), do: wire.to_dc

  defp amps(a), do: Format.value(Float.round(a / 1, 1))
end
