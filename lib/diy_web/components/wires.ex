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

  # The range of each number, for the text of an error.
  @ranges %{
    amps: {1, 1000},
    feet: {1, 500},
    from_ocpd: {1, 2000},
    to_ocpd: {1, 2000},
    from_dc: {1, 1500},
    to_dc: {1, 1500}
  }

  attr :build, :map, required: true
  attr :item, :map, required: true
  attr :error, :any, default: nil, doc: "`{:wire, id, key}`: a number of a wire that is not valid"

  @doc "The part Wires of the panel of an item."
  def section(assigns) do
    by_id = Map.new(assigns.build.items, &{&1.id, &1})

    wires =
      for wire <- Build.wires_of(assigns.build, assigns.item.id),
          Map.has_key?(by_id, wire.from) and Map.has_key?(by_id, wire.to),
          do: {wire, by_id[wire.from], by_id[wire.to]}

    world = Build.world(assigns.build, assigns.item)

    others =
      for other <- assigns.build.items,
          other.id != assigns.item.id and Build.wired?(other),
          Build.world(assigns.build, other) == world,
          do: other

    # A busbar has a number of positions for wires.
    ports = if assigns.item.type == "dc_bus", do: assigns.item.params["ports"]
    assigns = assign(assigns, wires: wires, others: others, ports: ports, used: length(wires))

    ~H"""
    <section id="part-wires" class="stage-sec" aria-labelledby="part-wires-title">
      <h3 id="part-wires-title" class="stage-sec-title" tabindex="-1">Wires</h3>
      <p class="stage-help">
        The app checks each wire with the rules of the NEC, the National Electrical Code (2023). It does not replace an electrician or the inspector of your city.
      </p>
      <p :if={@ports} id="wire-ports" class={if @used > @ports, do: "wire-over", else: "stage-help"}>
        {ports_text(@used, @ports)}
      </p>
      <.wire
        :for={{wire, from, to} <- @wires}
        build={@build}
        wire={wire}
        from={from}
        to={to}
        error={wire_error(@error, wire.id)}
      />
      <form :if={@others != []} id="add-wire" phx-submit="add_wire" class="stage-field">
        <input type="hidden" name="from" value={@item.id} />
        <label for="wire-to" class="stage-label">Add a wire from this item to</label>
        <div class="wire-add">
          <select id="wire-to" name="to" class="stage-input">
            <option :for={other <- @others} value={other.id}>{place_name(@build, other)}</option>
          </select>
          <button type="submit" id="add-wire-button" class="stage-btn">Add</button>
        </div>
      </form>
      <p :if={@others == []} id="wire-none" class="stage-help">
        Add a second item that takes wires: a battery, a busbar, an inverter, a power station, an alternator charger, a transfer switch or a shore power inlet.
      </p>
    </section>
    """
  end

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

  attr :build, :map, required: true
  attr :wire, :map, required: true
  attr :from, :map, required: true
  attr :to, :map, required: true
  attr :error, :atom, default: nil

  defp wire(assigns) do
    wire = assigns.wire
    two_way = Wire.two_way?(wire)
    advice = Wire.advise(wire, Wire.ends(assigns.from, assigns.to))

    assigns =
      assign(assigns,
        id: "wire-#{wire.id}",
        dc: Wire.dc?(wire.system),
        two_way: two_way,
        advice: advice,
        largest: advice.awg && Wire.largest(advice.awg),
        faults: Wire.check(wire),
        has: Enum.any?([wire.awg, wire.from_ocpd, wire.to_ocpd]),
        from_name: Catalog.name(assigns.from),
        to_name: Catalog.name(assigns.to)
      )

    ~H"""
    <article id={@id} class="wire" aria-labelledby={"#{@id}-title"}>
      <h4 id={"#{@id}-title"} class="wire-title">{@from_name} to {@to_name}</h4>
      <form id={"#{@id}-form"} phx-change="wire" phx-submit="wire" class="stage-fields">
        <input type="hidden" name="wire_id" value={@wire.id} />
        <fieldset class="stage-field">
          <legend class="stage-label">The current comes from</legend>
          <div class="stage-choices">
            <label
              :for={{end_id, name} <- [{@from.id, @from_name}, {@to.id, @to_name}]}
              class="stage-choice"
            >
              <input type="radio" name="wire[from]" value={end_id} checked={end_id == @from.id} />
              <span>{name}</span>
            </label>
          </div>
        </fieldset>
        <div class="stage-field">
          <label for={"#{@id}-system"} class="stage-label">System</label>
          <select id={"#{@id}-system"} name="wire[system]" class="stage-input">
            <option :for={{key, label} <- systems()} value={key} selected={key == @wire.system}>
              {label}
            </option>
          </select>
        </div>
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
            error={@error == :from_ocpd && range(:from_ocpd)}
          />
          <.number
            :if={@dc}
            id={"#{@id}-from-dc"}
            name="wire[from_dc]"
            label="Its DC rating, on its label"
            unit="V"
            value={@wire.from_dc}
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
            error={@error == :to_ocpd && range(:to_ocpd)}
          />
          <.number
            id={"#{@id}-to-dc"}
            name="wire[to_dc]"
            label="Its DC rating, on its label"
            unit="V"
            value={@wire.to_dc}
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

      <button
        type="button"
        phx-click={
          JS.push("delete_wire", value: %{id: @wire.id})
          |> JS.focus(to: "#part-wires-title")
        }
        class="stage-btn stage-danger"
      >
        Remove the wire
      </button>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :unit, :string, required: true
  attr :value, :any, required: true
  attr :help, :string, default: nil
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
          step="any"
          inputmode="decimal"
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

  defp systems, do: @systems

  defp range(key) do
    {min, max} = Map.fetch!(@ranges, key)
    "Give a number from #{min} to #{max}, or nothing."
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
      "The wire is too small: #{wire.awg} AWG carries #{Wire.ampacity(wire.awg)} A, and the wire needs #{amps(need)} A. This is 125% of #{amps(wire.amps)} A (NEC 210.19(A))."

  def fault_text({:ocpd_small, side, need}, wire, from, to),
    do:
      "The breaker or the fuse at #{name(side, from, to)} is too small: #{ocpd(wire, side)} A is less than #{amps(need)} A. It can open at the normal current (NEC 210.20(A))."

  def fault_text({:ocpd_big, side, largest}, wire, from, to),
    do:
      "The breaker or the fuse at #{name(side, from, to)} does not protect the wire: #{wire.awg} AWG takes #{largest} A at most, and it is #{ocpd(wire, side)} A. Use a larger wire or a smaller breaker (NEC 240.4)."

  def fault_text({:no_ocpd, :from, nil}, _wire, from, _to),
    do:
      "The wire has no breaker or fuse at #{from}. A fault on the wire can then start a fire (NEC 240.21)."

  def fault_text({:no_ocpd, :to, nil}, _wire, _from, to),
    do:
      "The wire has no breaker or fuse at #{to}. That end also gives current: it can feed a fault on the wire (NEC 705.30)."

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
