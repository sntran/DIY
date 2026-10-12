defmodule DIYWeb.Icon.StationShapes do
  @moduledoc """
  The models of the power stations that have a look of their own
  (`DIY.Catalog.station_models/0`), at their real size in meters, as parts
  of `DIYWeb.Icon.Shapes`. The F5000LFP of Pecron is the model of the kind
  (`DIYWeb.Icon.Shapes.model/1`), and a station that the app does not know
  has it too.

  The front looks to y, and the camera of the house sees the right side
  (x). The back and the left side show after a turn. The places of the
  parts follow the photos and the drawings of the makers. They are
  fractions of the width of the front (from the left) and of the height
  (down from the top). On a side, a place is a fraction of the depth, back
  from the front.

  - Pecron E3800LFP: a dark box on the floor, with an orange cap on each
    corner. The top half of its front has the groups of ports in orange
    frames. The bottom half has ribs and the name.
  - EcoFlow DELTA Pro and DELTA Pro 3: the front is the short end. Two
    wheels are at the back, and a handle comes out of the bottom of the
    front. The DELTA Pro is black with a gray cap. The DELTA Pro 3 is
    silver, with a dark hood at each end.
  - EcoFlow DELTA Pro Ultra: the inverter on its battery, two wide slabs.
    The battery has a silver front and a silver back.
  - Anker SOLIX F3800 (and Plus): a tall box of warm gray on wheels. The
    handle is at the top of its front, with the panel under it. The AC
    outlets are on the right side, and the inputs on the left side.
  """

  import DIYWeb.Icon.Shapes,
    only: [box: 3, front: 4, side: 4, top: 4, disc: 4, tube: 5, rbox: 4, rslab: 7, face: 3]

  alias DIYWeb.Geometry
  alias DIYWeb.Icon.Shapes

  @doc "The model of a station by the key of its model."
  def model("pecron_e3800lfp"), do: e3800()
  def model("ecoflow_delta_pro"), do: delta_pro()
  def model("ecoflow_delta_pro_3"), do: delta_pro_3()
  def model("ecoflow_delta_pro_ultra"), do: delta_pro_ultra()
  def model("anker_solix_f3800"), do: solix(false)
  def model("anker_solix_f3800_plus"), do: solix(true)

  @doc "The keys of the models that have a look of their own."
  def models,
    do: ~w(pecron_e3800lfp ecoflow_delta_pro ecoflow_delta_pro_3 ecoflow_delta_pro_ultra
           anker_solix_f3800 anker_solix_f3800_plus)

  @doc """
  The place of the panel of each model on its front, for the stage
  (`DIYWeb.Stage.region/1`): `{:front, {x, y, z}, {w, h}}` in meters.
  """
  def screen("pecron_e3800lfp"), do: {:front, {0.025, 0.309, 0.177}, {0.395, 0.175}}
  def screen("ecoflow_delta_pro"), do: {:front, {0.06, 0.602, 0.059}, {0.163, 0.262}}
  def screen("ecoflow_delta_pro_3"), do: {:front, {0.053, 0.675, 0.031}, {0.235, 0.268}}
  def screen("ecoflow_delta_pro_ultra"), do: {:front, {0.035, 0.483, 0.225}, {0.62, 0.155}}
  def screen("anker_solix_" <> _plus), do: {:front, {0.074, 0.397, 0.505}, {0.244, 0.081}}

  # A face with round corners on a plane, from a corner and a size on
  # that plane. The plane is `:front` (y), `:back` (y, it looks back),
  # `:side` (x) or `:top` (z).
  defp round_face(:front, {x, y, z}, {w, h}, r, class),
    do: face(for({u, v} <- Shapes.rounded({x, z}, {w, h}, r), do: {u, y, v}), {0, 1, 0}, class)

  defp round_face(:back, {x, y, z}, {w, h}, r, class),
    do: face(for({u, v} <- Shapes.rounded({x, z}, {w, h}, r), do: {u, y, v}), {0, -1, 0}, class)

  defp round_face(:side, {x, y, z}, {d, h}, r, class),
    do: face(for({u, v} <- Shapes.rounded({y, z}, {d, h}, r), do: {x, u, v}), {1, 0, 0}, class)

  defp round_face(:top, {x, y, z}, {w, d}, r, class),
    do: face(for({u, v} <- Shapes.rounded({x, y}, {w, d}, r), do: {u, v, z}), {0, 0, 1}, class)

  # A rectangle on the back (y = y, it looks back), from x, z. It is a
  # little out of the face.
  defp back({x, y, z}, {w, h}, class, out) do
    y = y - out
    face([{x, y, z}, {x + w, y, z}, {x + w, y, z + h}, {x, y, z + h}], {0, -1, 0}, class)
  end

  # A rectangle on the left side (x = x, it looks to the left), from y, z.
  defp left({x, y, z}, {d, h}, class, out) do
    x = x - out
    face([{x, y, z}, {x, y + d, z}, {x, y + d, z + h}, {x, y, z + h}], {-1, 0, 0}, class)
  end

  # A disc on the back or on the left side.
  defp disc_on(:back, center, r, class),
    do: face(Geometry.circle(center, {1, 0, 0}, {0, 0, 1}, r), {0, -1, 0}, class)

  defp disc_on(:left, center, r, class),
    do: face(Geometry.circle(center, {0, 1, 0}, {0, 0, 1}, r), {-1, 0, 0}, class)

  # A rectangle on the front from the fractions of a drawing. The fraction
  # of x is from the left of a width `{x0, w}`. The fraction of z is down
  # from the top of a height `h`.
  defp at({x0, w}, h, y, {a, b}, {f0, f1}, class, out),
    do: front({x0 + a * w, y, h * (1 - f1)}, {(b - a) * w, (f1 - f0) * h}, class, out)

  # A disc on the front, at the fractions of a drawing.
  defp dot({x0, w}, h, y, {a, f}, r, class, out),
    do: disc({x0 + a * w, y + out, h * (1 - f)}, :front, r, class)

  # An outlet of 120 V: a dark face with its two slots.
  defp outlet({x, y, z}, {w, h}, class, out) do
    [
      front({x, y, z}, {w, h}, class, out),
      front({x + w * 0.28, y, z + h * 0.45}, {w * 0.1, h * 0.35}, "i-black", out + 0.001),
      front({x + w * 0.62, y, z + h * 0.45}, {w * 0.1, h * 0.35}, "i-black", out + 0.001)
    ]
  end

  # A power station as the Pecron E3800LFP, on the floor (its cart is an
  # accessory). It is a dark box with an orange cap on each of its eight
  # corners. The top half of its front has the screen with the buttons DC
  # and AC. It also has four groups of ports, each in an orange frame: the
  # DC inputs, the AC outputs, the DC outputs and the USB ports. The
  # bottom half has ribs and the badge of the name. Each side has a grip at
  # its top. The right side has two vents, and the ports for more
  # batteries under them. The left side has the AC input and a vent. The
  # places follow the drawing of the front in the manual of Pecron. The
  # orange of the frames is `i-orange-l`: it has a color in the house plan.
  defp e3800 do
    {w, d, h} = {0.445, 0.307, 0.373}
    span = {0, w}
    rect = &at(span, h, d, &1, &2, &3, &4)
    dot = &dot(span, h, d, &1, &2, &3, &4)

    # A group of ports: an orange frame round a dark face.
    frame = fn {a, b}, {f0, f1} ->
      {da, df} = {0.003 / w, 0.003 / h}

      [
        rect.({a, b}, {f0, f1}, "i-orange-l", 0.003),
        rect.({a + da, b - da}, {f0 + df, f1 - df}, "i-dark-r", 0.004)
      ]
    end

    # The panel at the top of the front, and the ribs under it.
    panel =
      [
        rect.({0.056, 0.944}, {0.058, 0.526}, "i-dark-r", 0.002),
        rect.({0.056, 0.944}, {0.526, 0.935}, "i-black", 0.002)
      ] ++
        for k <- 0..13 do
          rect.({0.056, 0.944}, {0.535 + k * 0.029, 0.551 + k * 0.029}, "i-dark-l", 0.003)
        end

    # The badge of the name with the sun of the logo, and the name of the
    # model.
    names = [
      round_face(
        :front,
        {0.366 * w, d + 0.004, h * 0.232},
        {0.27 * w, 0.105 * h},
        0.01,
        "i-dark-r"
      ),
      rect.({0.4, 0.6}, {0.7, 0.735}, "i-white-t", 0.005),
      dot.({0.548, 0.685}, 0.006, "i-orange-l", 0.005),
      rect.({0.136, 0.26}, {0.088, 0.114}, "i-orange-l", 0.003)
    ]

    # The DC inputs: a round port and two XT60 ports.
    inputs =
      frame.({0.093, 0.301}, {0.137, 0.276}) ++
        [
          dot.({0.134, 0.2}, 0.007, "i-black", 0.005),
          rect.({0.181, 0.211}, {0.17, 0.23}, "i-black", 0.005),
          rect.({0.248, 0.278}, {0.17, 0.23}, "i-black", 0.005)
        ]

    # The screen with the battery and the lines of numbers, and the
    # buttons DC and AC.
    screen =
      [
        rect.({0.353, 0.564}, {0.112, 0.265}, "i-black", 0.003),
        rect.({0.37, 0.41}, {0.135, 0.24}, "i-white-t", 0.004)
      ] ++
        for(
          k <- 0..3,
          do: rect.({0.43, 0.54}, {0.14 + k * 0.03, 0.152 + k * 0.03}, "i-white-t", 0.004)
        ) ++
        Enum.flat_map([0.144, 0.232], fn f ->
          [
            dot.({0.621, f}, 0.0085, "i-orange-l", 0.003),
            dot.({0.621, f}, 0.0065, "i-dark-l", 0.004)
          ]
        end)

    # The AC outputs: the TT-30 and four outlets, under their flaps.
    ac =
      frame.({0.093, 0.643}, {0.301, 0.496}) ++
        [rect.({0.133, 0.243}, {0.32, 0.485}, "i-black", 0.005)] ++
        for c <- [0.327, 0.411, 0.495, 0.58] do
          rect.({c - 0.031, c + 0.031}, {0.36, 0.44}, "i-black", 0.005)
        end

    # The DC outputs (an XT60 port, the car socket and a round port), and
    # the USB ports under three flaps.
    dc =
      frame.({0.692, 0.904}, {0.102, 0.296}) ++
        [
          rect.({0.729, 0.759}, {0.14, 0.196}, "i-black", 0.005),
          dot.({0.834, 0.209}, 0.0165, "i-black", 0.005),
          dot.({0.742, 0.256}, 0.005, "i-black", 0.005)
        ] ++
        frame.({0.692, 0.904}, {0.312, 0.496}) ++
        for c <- [0.74, 0.798, 0.857] do
          rect.({c - 0.0225, c + 0.0225}, {0.335, 0.465}, "i-black", 0.005)
        end

    # The grips at the top of the sides and their gaps on the top, and the
    # raised plate of the top.
    grips = [
      side({w, 0.25 * d, h - 0.06}, {0.5 * d, 0.045}, "i-black", 0.002),
      left({0, 0.25 * d, h - 0.06}, {0.5 * d, 0.045}, "i-black", 0.002),
      top({w - 0.032, 0.25 * d, h}, {0.02, 0.5 * d}, "i-black", 0.002),
      top({0.012, 0.25 * d, h}, {0.02, 0.5 * d}, "i-black", 0.002),
      top({0.045, 0.02, h}, {w - 0.09, d - 0.04}, "i-gray-r", 0.001)
    ]

    # The two vents of the right side, and the bay of the ports for more
    # batteries under them.
    right =
      [
        side({w, 0.25 * d, 0.5 * h}, {0.23 * d, 0.25 * h}, "i-black", 0.002),
        side({w, 0.52 * d, 0.5 * h}, {0.23 * d, 0.25 * h}, "i-black", 0.002),
        side({w, 0.1 * d, 0.1 * h}, {0.5 * d, 0.3 * h}, "i-black", 0.002),
        disc({w + 0.003, 0.24 * d, 0.25 * h}, :side, 0.022, "i-dark-r"),
        disc({w + 0.003, 0.46 * d, 0.25 * h}, :side, 0.022, "i-dark-r")
      ] ++
        for k <- 0..5, y0 <- [0.25 * d, 0.52 * d] do
          side({w, y0 + 0.006 + k * 0.0115, 0.52 * h}, {0.004, 0.21 * h}, "i-dark-l", 0.003)
        end

    # The left side: two panels with flaps (the reset button and the port
    # RJ45, and the round AC input), and a vent under them.
    left_side =
      [
        left({0, 0.52 * d, 0.52 * h}, {0.18 * d, 0.24 * h}, "i-black", 0.002),
        left({0, 0.3 * d, 0.52 * h}, {0.18 * d, 0.24 * h}, "i-black", 0.002),
        left({0, 0.54 * d, 0.55 * h}, {0.14 * d, 0.18 * h}, "i-dark-l", 0.003),
        disc_on(:left, {-0.004, 0.39 * d, 0.64 * h}, 0.02, "i-dark-l"),
        left({0, 0.1 * d, 0.07 * h}, {0.6 * d, 0.38 * h}, "i-black", 0.002)
      ] ++
        for k <- 0..11 do
          left({0, (0.12 + k * 0.047) * d, 0.09 * h}, {0.012, 0.34 * h}, "i-dark-l", 0.003)
        end

    rbox({0, 0, 0}, {w, d, h}, 0.01, "dark") ++
      panel ++
      names ++
      inputs ++ screen ++ ac ++ dc ++ grips ++ right ++ left_side ++ caps(w, d, h)
  end

  # The orange caps of the E3800LFP: an L on each face at each corner. The
  # L on the front is 65 by 70 mm, and it goes 60 mm back on the side and
  # on the top. Each arm is 26 mm wide.
  defp caps(w, d, h) do
    {a, b, s, t, out} = {0.065, 0.07, 0.06, 0.026, 0.003}
    sign = fn n -> if n > 0, do: t, else: -t end

    ell = fn {u, v}, {du, dv} ->
      {su, sv} = {sign.(du), sign.(dv)}
      [{u, v}, {u + du, v}, {u + du, v + sv}, {u + su, v + sv}, {u + su, v + dv}, {u, v + dv}]
    end

    # The two ends of a side: the start (to +) and the far end (to -).
    ends = fn far -> [{0, 1}, {far, -1}] end

    fronts =
      for {x, sx} <- ends.(w), {z, sz} <- ends.(h), {y, n} <- [{d + out, 1}, {-out, -1}] do
        face(
          for({u, v} <- ell.({x, z}, {sx * a, sz * b}), do: {u, y, v}),
          {0, n, 0},
          "i-orange-~"
        )
      end

    sides =
      for {y, sy} <- ends.(d), {z, sz} <- ends.(h), {x, n} <- [{w + out, 1}, {-out, -1}] do
        face(
          for({u, v} <- ell.({y, z}, {sy * s, sz * b}), do: {x, u, v}),
          {n, 0, 0},
          "i-orange-~"
        )
      end

    tops =
      for {x, sx} <- ends.(w), {y, sy} <- ends.(d) do
        face(
          for({u, v} <- ell.({x, y}, {sx * a, sy * s}), do: {u, v, h + out}),
          {0, 0, 1},
          "i-orange-~"
        )
      end

    fronts ++ sides ++ tops
  end

  # A power station as the EcoFlow DELTA Pro. The front is its short end.
  # The black body has a gray cap with a handle at each end of its top.
  # The front of the body has the screen, the USB ports and the gold
  # button. The AC outlets (four outlets and the TT-30) are on a darker
  # plate. The slot of the pull handle is at its foot. The right side has
  # two fans in the cap, the name, and two doors near the front. The back
  # has the inputs, the ports for more batteries and a vent. Two wheels
  # are at the back, in wells of the body.
  defp delta_pro do
    {w, d, h} = {0.284, 0.635, 0.42}
    # The body is inside the wheels, and its front is 35 mm behind the
    # front of the cap. Its back part is 35 mm in front of the back of
    # the cap.
    {x0, x1, cap, y, rear} = {0.013, 0.271, 0.323, 0.6, 0.035}
    bw = x1 - x0
    span = {x0, bw}
    rect = &at(span, h, y, &1, &2, &3, &4)
    dot = &dot(span, h, y, &1, &2, &3, &4)

    wheels = for x <- [0, w - 0.035], do: tube({x, 0.075, 0.056}, 0.056, 0.035, :x, "dark")

    feet =
      for x <- [0.04, w - 0.08], fy <- [0.09, d - 0.09] do
        box({x, fy, 0}, {0.04, 0.04, 0.012}, "dark")
      end

    body =
      box({0.035, rear, 0.012}, {w - 0.07, 0.15 - rear, 0.108}, "dark") ++
        box({x0, rear, 0.12}, {bw, 0.15 - rear, cap - 0.12}, "dark") ++
        box({x0, 0.15, 0.012}, {bw, y - 0.15, cap - 0.012}, "dark") ++
        rslab(:y, {cap, x0}, {h - cap, bw}, 0.015, 0, d, "gray")

    # The handle at each end of the cap: the gap under its bar, and the
    # gap for the hand on the top.
    gap = [{0.21, 0.215}, {0.79, 0.215}, {0.7, 0.13}, {0.3, 0.13}]

    handles = [
      face(for({a, f} <- gap, do: {x0 + a * bw, d + 0.002, h * (1 - f)}), {0, 1, 0}, "i-black"),
      face(for({a, f} <- gap, do: {x0 + a * bw, -0.002, h * (1 - f)}), {0, -1, 0}, "i-black"),
      top({x0 + 0.3 * bw, d - 0.06, h}, {0.4 * bw, 0.035}, "i-black", 0.002),
      top({x0 + 0.3 * bw, 0.025, h}, {0.4 * bw, 0.035}, "i-black", 0.002)
    ]

    # The plate of the front, the screen and its numbers, the USB ports
    # and the gold button.
    screen =
      [
        round_face(
          :front,
          {x0 + 0.18 * bw, y + 0.002, h * 0.14},
          {0.63 * bw, h * 0.625},
          0.01,
          "i-dark-t"
        ),
        rect.({0.2, 0.8}, {0.245, 0.4}, "i-black", 0.004),
        rect.({0.24, 0.36}, {0.28, 0.36}, "i-white-t", 0.005),
        dot.({0.5, 0.322}, 0.022, "i-cyan", 0.005),
        dot.({0.5, 0.322}, 0.017, "i-black", 0.006),
        rect.({0.62, 0.76}, {0.285, 0.3}, "i-white-t", 0.005),
        rect.({0.62, 0.76}, {0.33, 0.345}, "i-white-t", 0.005),
        rect.({0.3, 0.36}, {0.484, 0.496}, "i-black", 0.004),
        rect.({0.64, 0.7}, {0.484, 0.496}, "i-black", 0.004),
        dot.({0.5, 0.5}, 0.009, "i-light-wood-l", 0.004)
      ] ++
        for {c, class} <- [
              {0.33, "i-black"},
              {0.44, "i-black"},
              {0.55, "i-screen"},
              {0.66, "i-screen"}
            ] do
          rect.({c - 0.03, c + 0.03}, {0.423, 0.437}, class, 0.004)
        end

    # The plate of the AC outlets with its switch, the four outlets and the
    # TT-30, and the slot of the pull handle with its tab.
    ac =
      [
        rect.({0.2, 0.8}, {0.55, 0.85}, "i-dark-r", 0.004),
        rect.({0.47, 0.53}, {0.568, 0.582}, "i-white-t", 0.005),
        dot.({0.66, 0.69}, 0.028, "i-black", 0.005),
        dot.({0.66, 0.69}, 0.02, "i-dark-r", 0.006),
        rect.({0.24, 0.76}, {0.89, 0.955}, "i-black", 0.002),
        rect.({0.42, 0.55}, {0.9, 0.945}, "i-steel-l", 0.003)
      ] ++
        Enum.flat_map(for(c <- [0.31, 0.455], f <- [0.635, 0.72], do: {c, f}), fn {c, f} ->
          outlet(
            {x0 + (c - 0.055) * bw, y, h * (1 - f - 0.033)},
            {0.11 * bw, 0.066 * h},
            "i-dark-l",
            0.005
          )
        end)

    # The right side: two fans in the cap, the name, the badge PRO, the two
    # doors near the front, and the hub of the wheel.
    right =
      for(
        k <- [0.37, 0.61],
        do:
          round_face(
            :side,
            {x1 + 0.002, d * (1 - k) - 0.038, cap + 0.012},
            {0.076, 0.07},
            0.012,
            "i-black"
          )
      ) ++
        for(
          k <- [0.37, 0.61],
          do: disc({x1 + 0.003, d * (1 - k), cap + 0.047}, :side, 0.026, "i-dark-l")
        ) ++
        [
          side({x1, 0.22, 0.155}, {0.19, 0.022}, "i-gray-t", 0.002),
          side({x1, 0.3, 0.12}, {0.035, 0.014}, "i-light-wood-r", 0.002),
          side({x1, d * 0.87, 0.2}, {y - 0.01 - d * 0.87, 0.094}, "i-black", 0.002),
          side({x1, d * 0.87, 0.076}, {y - 0.01 - d * 0.87, 0.109}, "i-black", 0.002),
          disc({w + 0.002, 0.075, 0.056}, :side, 0.028, "i-gray-t")
        ]

    # The back: the strip of the inputs, the two ports for more batteries,
    # and the vent under them. The strip has the solar input, the switch
    # of the charge, the AC input and a button.
    back_side =
      [
        back({x0 + 0.12 * bw, rear, 0.255}, {0.76 * bw, 0.05}, "i-black", 0.002),
        back({x0 + 0.18 * bw, rear, 0.265}, {0.1 * bw, 0.03}, "i-dark-t", 0.003),
        back({x0 + 0.34 * bw, rear, 0.27}, {0.08 * bw, 0.02}, "i-dark-t", 0.003),
        back({x0 + 0.48 * bw, rear, 0.262}, {0.16 * bw, 0.036}, "i-dark-t", 0.003),
        disc_on(:back, {x0 + 0.76 * bw, rear - 0.003, 0.28}, 0.01, "i-dark-t"),
        back({x0 + 0.2 * bw, rear, 0.16}, {0.25 * bw, 0.07}, "i-dark-t", 0.002),
        back({x0 + 0.55 * bw, rear, 0.16}, {0.25 * bw, 0.07}, "i-dark-t", 0.002),
        back({0.05, rear, 0.025}, {w - 0.1, 0.08}, "i-black", 0.002)
      ] ++
        for i <- 0..2, j <- 0..6 do
          back({0.06 + j * 0.024, rear, 0.035 + i * 0.024}, {0.014, 0.014}, "i-dark-l", 0.003)
        end

    Enum.concat(wheels) ++
      Enum.concat(feet) ++ body ++ handles ++ screen ++ ac ++ right ++ back_side
  end

  # A power station as the EcoFlow DELTA Pro 3. The front is its short
  # end. The silver body has a dark hood over each end of its top: each
  # hood has a vent over the handle. The black frame of the front has the
  # light, the screen and the USB ports. Under them is the tray of the AC
  # outlets: four outlets, the 6-20 and the L14-30. The pull handle is at
  # its foot. The right side has a long slot, the name and a door. The
  # back has four doors of ports and a vent. Two wheels are at the back,
  # in wells of the body.
  defp delta_pro_3 do
    {w, d, h} = {0.341, 0.693, 0.41}
    {x0, x1, hood, y, rear} = {0.023, 0.318, 0.3, 0.673, 0.02}
    span = {0, w}
    rect = &at(span, h, y, &1, &2, &3, &4)
    dot = &dot(span, h, y, &1, &2, &3, &4)

    section = fn from, length, {z0, z1}, {a, b} ->
      rslab(:y, {z0, a}, {z1 - z0, b - a}, 0.03, from, length, "steel")
    end

    wheels = for x <- [0, w - 0.045], do: tube({x, 0.075, 0.062}, 0.062, 0.045, :x, "dark")
    feet = for x <- [0.05, w - 0.09], do: box({x, d - 0.12, 0}, {0.04, 0.05, 0.03}, "dark")

    body =
      box({0.045, rear, 0.03}, {w - 0.09, 0.16 - rear, 0.105}, "steel") ++
        section.(rear, 0.16 - rear, {0.135, hood}, {x0, x1}) ++
        section.(0.16, d - 0.32, {0.03, h}, {x0, x1}) ++
        section.(d - 0.16, 0.16 - rear, {0.03, hood}, {x0, x1}) ++
        rslab(:y, {hood, x0}, {h - hood, x1 - x0}, 0.03, 0, 0.16, "gray") ++
        rslab(:y, {hood, x0}, {h - hood, x1 - x0}, 0.03, d - 0.16, 0.16, "gray")

    # The gap of each hood, with its vent and its teeth.
    hoods =
      [
        round_face(:front, {0.17 * w, d + 0.002, hood}, {0.66 * w, 0.085}, 0.02, "i-black"),
        front({0.2 * w, d, h * 0.82}, {0.6 * w, h * 0.09}, "i-dark-r", 0.003),
        round_face(:back, {0.17 * w, -0.002, hood}, {0.66 * w, 0.085}, 0.02, "i-black"),
        back({0.2 * w, 0, h * 0.82}, {0.6 * w, h * 0.09}, "i-dark-r", 0.003)
      ] ++
        for k <- 0..11 do
          front({(0.2 + k * 0.05) * w, d, h * 0.79}, {0.025 * w, h * 0.03}, "i-dark-l", 0.003)
        end

    # The frame of the front with a silver line round it, the light, and
    # the screen: the numbers, the ring and its green marks. Then the USB
    # ports.
    screen =
      [
        round_face(:front, {0.155 * w, y + 0.001, 0.031}, {0.69 * w, 0.268}, 0.02, "i-steel-l"),
        round_face(:front, {0.165 * w, y + 0.002, 0.034}, {0.67 * w, 0.262}, 0.018, "i-black"),
        rect.({0.45, 0.55}, {0.285, 0.295}, "i-white-t", 0.003),
        rect.({0.26, 0.77}, {0.33, 0.48}, "i-dark-r", 0.003),
        rect.({0.29, 0.4}, {0.38, 0.42}, "i-white-t", 0.004),
        rect.({0.63, 0.74}, {0.38, 0.42}, "i-white-t", 0.004),
        dot.({0.515, 0.405}, 0.025, "i-cyan", 0.004),
        dot.({0.515, 0.405}, 0.02, "i-dark-r", 0.005),
        rect.({0.49, 0.54}, {0.39, 0.42}, "i-white-t", 0.006),
        rect.({0.47, 0.56}, {0.455, 0.465}, "i-led", 0.004)
      ] ++
        for {c, class} <- [
              {0.31, "i-steel-r"},
              {0.44, "i-steel-r"},
              {0.55, "i-screen"},
              {0.68, "i-screen"}
            ] do
          rect.({c - 0.03, c + 0.03}, {0.513, 0.527}, class, 0.003)
        end

    # The tray of the AC outlets with its two buttons, the outlets, and the
    # pull handle with the word PUSH.
    ac =
      [
        rect.({0.23, 0.77}, {0.55, 0.86}, "i-dark-l", 0.003),
        rect.({0.33, 0.43}, {0.565, 0.58}, "i-dark-t", 0.004),
        rect.({0.59, 0.69}, {0.565, 0.58}, "i-dark-t", 0.004),
        rect.({0.27, 0.5}, {0.59, 0.83}, "i-dark-r", 0.004),
        rect.({0.55, 0.73}, {0.59, 0.7}, "i-dark-r", 0.004),
        dot.({0.64, 0.77}, 0.026, "i-dark-r", 0.004),
        dot.({0.64, 0.77}, 0.02, "i-dark-t", 0.005),
        rect.({0.31, 0.69}, {0.87, 0.92}, "i-dark-l", 0.003),
        rect.({0.44, 0.56}, {0.89, 0.9}, "i-steel-l", 0.004)
      ] ++
        Enum.flat_map(
          for(c <- [0.31, 0.44], f <- [0.645, 0.78], do: {c, f}) ++ [{0.64, 0.645}],
          fn {c, f} ->
            outlet(
              {(c - 0.045) * w, y, h * (1 - f - 0.04)},
              {0.09 * w, 0.08 * h},
              "i-dark-t",
              0.005
            )
          end
        )

    # The right side: the long slot with its silver lip, the name and the
    # door. The dark band is at its foot, with the hub of the wheel.
    right = [
      side({x1, 0.17, h * 0.79}, {0.35, 0.006}, "i-steel-t", 0.002),
      side({x1, 0.17, h * 0.79 - 0.008}, {0.35, 0.008}, "i-black", 0.002),
      side({x1, 0.24, h * 0.5}, {0.21, 0.022}, "i-gray-l", 0.002),
      side({x1, 0.33, h * 0.46}, {0.03, 0.01}, "i-gray-l", 0.002),
      side({x1, d * 0.83, h * 0.29}, {d * 0.12, h * 0.26}, "i-steel-r", 0.002),
      side({x1, d * 0.83 + 0.01, h * 0.4}, {0.006, 0.03}, "i-steel-t", 0.003),
      side({x1, 0.16, 0.03}, {d - 0.32, 0.03}, "i-black", 0.002),
      disc({w + 0.002, 0.075, 0.062}, :side, 0.032, "i-gray-r")
    ]

    # The back: a black plate with four doors of ports, and the vent under
    # it. The doors are for the inputs, the AC power in and out, and two
    # ports for more batteries.
    back_side =
      [back({0.23 * w, rear, 0.145}, {0.54 * w, 0.145}, "i-black", 0.002)] ++
        for(
          a <- [0.25, 0.51],
          z <- [0.152, 0.222],
          do: back({a * w, rear, z}, {0.24 * w, 0.063}, "i-dark-l", 0.003)
        ) ++
        [back({0.25 * w, rear, 0.06}, {0.5 * w, 0.06}, "i-black", 0.002)] ++
        for k <- 0..4 do
          back({0.27 * w, rear, 0.068 + k * 0.011}, {0.46 * w, 0.004}, "i-dark-l", 0.003)
        end

    Enum.concat(wheels) ++
      Enum.concat(feet) ++ body ++ hoods ++ screen ++ ac ++ right ++ back_side
  end

  # A power station as the EcoFlow DELTA Pro Ultra: the inverter on one
  # battery. The inverter is black, with a dark lid. Its screen is at the
  # front of its top. Its front has a silver loop at each end with a door
  # in it, and four flaps over the AC outlets in the middle. Its back has
  # the loops, the name and two vents. Its right end has a grip and three
  # bays of ports. The black battery has a silver plate on its front and on
  # its back, with the name. Its right end has a grip, the port of the
  # battery, five lights and a button.
  defp delta_pro_ultra do
    {w, d, h} = {0.69, 0.481, 0.418}
    # The battery, the feet of the inverter, its body and its lid.
    {battery, feet, lid} = {0.204, 0.214, 0.39}
    {bx0, bx1, by0, by1} = {0.015, 0.675, 0.013, 0.468}
    {ix0, ix1} = {0.007, 0.683}

    foot =
      for x <- [0.05, w - 0.1], y <- [0.03, d - 0.08] do
        box({x, y, battery}, {0.05, 0.05, feet - battery}, "dark")
      end

    body =
      rbox({bx0, by0, 0}, {bx1 - bx0, by1 - by0, battery}, 0.015, "dark") ++
        Enum.concat(foot) ++
        rbox({ix0, 0, feet}, {ix1 - ix0, d, lid - feet}, 0.02, "dark") ++
        rbox({0, 0, lid}, {w, d, h - lid}, 0.02, "dark")

    # The screen at the front of the top, with its numbers.
    screen = [
      top({0.2 * w, d - 0.07, h}, {0.6 * w, 0.055}, "i-black", 0.002),
      top({0.27 * w, d - 0.05, h}, {0.07 * w, 0.015}, "i-white-t", 0.003),
      top({0.66 * w, d - 0.05, h}, {0.07 * w, 0.015}, "i-white-t", 0.003),
      top({0.46 * w, d - 0.055, h}, {0.08 * w, 0.025}, "i-white-t", 0.003),
      top({0.42 * w, d - 0.05, h}, {0.025 * w, 0.015}, "i-led", 0.003),
      top({0.555 * w, d - 0.05, h}, {0.025 * w, 0.015}, "i-led", 0.003)
    ]

    # A silver loop at each end of the front and of the back. On the
    # front, a door is in each loop.
    loops =
      Enum.flat_map([{0.05, 0.07, 0.115}, {0.8, 0.8, 0.785}], fn {loop, inner, door} ->
        [
          round_face(:front, {loop * w, d + 0.001, 0.225}, {0.15 * w, 0.155}, 0.03, "i-steel-l"),
          round_face(:front, {inner * w, d + 0.002, 0.24}, {0.13 * w, 0.125}, 0.022, "i-dark-r"),
          front({door * w, d, 0.25}, {0.1 * w, 0.105}, "i-black", 0.003),
          round_face(:back, {loop * w, -0.001, 0.225}, {0.15 * w, 0.155}, 0.03, "i-steel-l"),
          round_face(:back, {inner * w, -0.002, 0.24}, {0.13 * w, 0.125}, 0.022, "i-dark-r")
        ]
      end)

    # The panel of the AC outlets with its four flaps, and the row of
    # buttons over it.
    outlets =
      [front({0.25 * w, d, 0.235}, {0.52 * w, 0.135}, "i-dark-l", 0.002)] ++
        for(
          {a, b} <- [{0.27, 0.37}, {0.39, 0.5}, {0.51, 0.63}, {0.65, 0.76}],
          do: front({a * w, d, 0.25}, {(b - a) * w, 0.11}, "i-dark-t", 0.003)
        ) ++
        for a <- [0.3, 0.38, 0.47, 0.56, 0.64] do
          disc({a * w, d + 0.003, 0.38}, :front, 0.004, "i-steel-r")
        end

    # The back of the inverter: the name between the vents.
    inverter_back = [
      back({0.25 * w, 0, 0.36}, {0.5 * w, 0.012}, "i-black", 0.002),
      back({0.25 * w, 0, 0.225}, {0.5 * w, 0.012}, "i-black", 0.002),
      back({0.4 * w, 0, 0.29}, {0.2 * w, 0.02}, "i-white-t", 0.002)
    ]

    # The ends: the grip and the bays of the inverter, and the grip, the
    # port, the button and the lights of the battery.
    ends =
      [
        side({ix1, 0.08, lid - 0.04}, {d - 0.16, 0.025}, "i-black", 0.002),
        side({ix1, 0.07, feet + 0.015}, {0.1, 0.1}, "i-black", 0.002),
        side({ix1, 0.19, feet + 0.015}, {0.1, 0.1}, "i-black", 0.002),
        side({ix1, 0.31, feet + 0.015}, {0.1, 0.1}, "i-black", 0.002),
        disc({ix1 + 0.003, 0.24, feet + 0.065}, :side, 0.03, "i-dark-l"),
        side({bx1, 0.06, battery - 0.045}, {0.34, 0.025}, "i-black", 0.002),
        side({bx1, 0.33, 0.04}, {0.1, 0.09}, "i-black", 0.002),
        disc({bx1 + 0.002, 0.15, 0.08}, :side, 0.008, "i-steel-l")
      ] ++
        for k <- 0..4, do: side({bx1, 0.2 + k * 0.015, 0.075}, {0.01, 0.006}, "i-led", 0.002)

    # The silver plate and the name of the battery, on its front and on its
    # back.
    plates = [
      front({0.06 * w, by1, 0.0125}, {0.88 * w, 0.1675}, "i-steel-l", 0.002),
      front({0.4 * w, by1, 0.055}, {0.2 * w, 0.02}, "i-white-t", 0.003),
      back({0.06 * w, by0, 0.0125}, {0.88 * w, 0.1675}, "i-steel-l", 0.002),
      back({0.4 * w, by0, 0.055}, {0.2 * w, 0.02}, "i-white-t", 0.003)
    ]

    body ++ screen ++ loops ++ outlets ++ inverter_back ++ ends ++ plates
  end

  # A power station as the Anker SOLIX F3800 (or the F3800 Plus): a tall
  # box of warm gray on wheels. The front has the handle at its top, the
  # blue light, and the black panel. The panel has the car socket, the
  # screen with its ports, and the power button with its blue ring. The
  # name is near the foot, over a dark gap. The sides are dark panels. The
  # right side has a tall vent and the AC outlets: the 14-50 (the TT-30 on
  # the Plus), the L14-30 and six outlets. The left side has the inputs
  # and a tall vent. The back has the pull handle and a pad for the hand.
  # The top has a gap for the hand at the front and the well of the pull
  # handle at the back. Two casters are at the front, and two wheels at
  # the back. The Plus has a light top, blue solar inputs, a cover for a
  # generator, and a badge under the name.
  defp solix(plus) do
    {w, d, h} = {0.388, 0.395, 0.702}
    # The body is over the base, and the base is on the casters. The base
    # is narrower at the back, between the wheels.
    {back, base, body, wells} = {0.025, 0.065, 0.14, 0.13}
    span = {0, w}
    rect = &at(span, h, d, &1, &2, &3, &4)
    dot = &dot(span, h, d, &1, &2, &3, &4)

    # A place on a side, from a fraction of the depth (back from the
    # front) and of the height (down from the top).
    on_side = fn {a, b}, {f0, f1}, class, out ->
      side({w, d * (1 - b), h * (1 - f1)}, {(b - a) * d, (f1 - f0) * h}, class, out)
    end

    on_left = fn {a, b}, {f0, f1}, class, out ->
      left({0, d * (1 - b), h * (1 - f1)}, {(b - a) * d, (f1 - f0) * h}, class, out)
    end

    side_dot = fn {a, f}, r, class ->
      disc({w + 0.004, d * (1 - a), h * (1 - f)}, :side, r, class)
    end

    # A place on the back, from a fraction of the width and of the height.
    on_back = fn {a, b}, {f0, f1}, class, out ->
      back({a * w, back, h * (1 - f1)}, {(b - a) * w, (f1 - f0) * h}, class, out)
    end

    casters =
      for x <- [0.035, w - 0.06] do
        tube({x, d - 0.065, 0.025}, 0.025, 0.025, :x, "dark") ++
          box({x - 0.005, d - 0.085, 0.05}, {0.035, 0.04, base - 0.05}, "dark")
      end

    wheels = for x <- [0, w - 0.035], do: tube({x, 0.06, 0.06}, 0.06, 0.035, :x, "dark")

    shell =
      Enum.concat(casters) ++
        Enum.concat(wheels) ++
        box({0.04, back, base}, {w - 0.08, wells - back, body - base}, "titanium") ++
        box({0, wells, base}, {w, d - wells, body - base}, "titanium") ++
        rbox({0, back, body}, {w, d - back, h - body}, 0.03, "titanium")

    # The front: the gap of the handle, the blue light, the black panel,
    # the name, and the gap at its foot. The panel has the car socket, the
    # screen with its ports, and the power button.
    front_side =
      [
        round_face(
          :front,
          {0.19 * w, d + 0.002, h * 0.88},
          {0.62 * w, 0.085 * h},
          0.02,
          "i-black"
        ),
        rect.({0.2, 0.8}, {0.14, 0.15}, "i-cyan", 0.002),
        round_face(
          :front,
          {0.19 * w, d + 0.002, h * 0.72},
          {0.63 * w, 0.115 * h},
          0.008,
          "i-black"
        ),
        dot.({0.25, 0.21}, 0.016, "i-dark-l", 0.004),
        dot.({0.25, 0.262}, 0.005, "i-dark-l", 0.004),
        rect.({0.37, 0.65}, {0.18, 0.24}, "i-dark-r", 0.003),
        rect.({0.46, 0.56}, {0.19, 0.212}, "i-white-t", 0.004),
        rect.({0.44, 0.58}, {0.219, 0.226}, "i-cyan", 0.004),
        rect.({0.39, 0.44}, {0.195, 0.2}, "i-white-t", 0.004),
        rect.({0.59, 0.64}, {0.195, 0.2}, "i-white-t", 0.004),
        dot.({0.755, 0.218}, 0.0115, "i-cyan", 0.003),
        dot.({0.755, 0.218}, 0.009, "i-steel-l", 0.004),
        rect.({0.38, 0.62}, {0.715, 0.74}, "i-steel-t", 0.002),
        rect.({0.4, 0.6}, {0.755, 0.77}, "i-steel-l", 0.002),
        rect.({0.25, 0.76}, {0.875, 0.905}, "i-black", 0.002)
      ] ++
        for(
          c <- [0.35, 0.42, 0.48, 0.56, 0.64],
          do: rect.({c - 0.015, c + 0.015}, {0.262, 0.272}, "i-steel-r", 0.003)
        ) ++
        if(plus, do: [rect.({0.43, 0.57}, {0.78, 0.795}, "i-steel-t", 0.002)], else: [])

    # The right side: the dark panel, the grille at its front, the panel
    # of the AC outlets and the tall vent. The hub of the wheel too.
    right =
      [
        side(
          {w, back + 0.03, body + 0.03},
          {d - back - 0.06, h - body - 0.06},
          "i-dark-l",
          0.001
        ),
        on_side.({0.07, 0.21}, {0.07, 0.32}, "i-black", 0.002),
        on_side.({0.23, 0.52}, {0.065, 0.305}, "i-black", 0.002),
        on_side.({0.6, 0.8}, {0.07, 0.78}, "i-black", 0.002),
        on_side.({0.5, 0.52}, {0.065, 0.305}, "i-gray-t", 0.003),
        side_dot.({0.3, 0.11}, if(plus, do: 0.017, else: 0.024), "i-dark-t"),
        side_dot.({0.43, 0.11}, 0.02, "i-dark-t"),
        side_dot.({0.475, 0.2}, 0.008, "i-dark-t"),
        side_dot.({0.475, 0.25}, 0.008, "i-dark-t"),
        disc({w + 0.002, 0.06, 0.06}, :side, 0.03, "i-gray-r")
      ] ++
        for(
          {a, f} <- for(a <- [0.28, 0.36], f <- [0.17, 0.215, 0.26], do: {a, f}),
          do: on_side.({a - 0.03, a + 0.03}, {f - 0.016, f + 0.016}, "i-dark-t", 0.003)
        ) ++
        for(
          k <- 0..9,
          do: on_side.({0.08, 0.2}, {0.09 + k * 0.022, 0.1 + k * 0.022}, "i-dark-l", 0.003)
        ) ++
        for k <- 0..7 do
          on_side.({0.615 + k * 0.023, 0.625 + k * 0.023}, {0.09, 0.76}, "i-dark-l", 0.003)
        end

    # The left side: the dark panel, the grille at its front, the panel of
    # the inputs and the tall vent. The panel has the cover of the port of
    # a home panel, the AC input and the two solar inputs. It also has the
    # cover of the port for more batteries (and for a generator on the
    # Plus).
    solar = if plus, do: "i-screen", else: "i-orange-l"

    left_side =
      [
        left(
          {0, back + 0.03, body + 0.03},
          {d - back - 0.06, h - body - 0.06},
          "i-dark-l",
          0.001
        ),
        on_left.({0.07, 0.21}, {0.07, 0.32}, "i-black", 0.002),
        on_left.({0.26, 0.52}, {0.065, 0.4}, "i-black", 0.002),
        on_left.({0.28, 0.5}, {0.075, 0.165}, "i-dark-r", 0.003),
        on_left.({0.4, 0.48}, {0.18, 0.21}, "i-dark-t", 0.003),
        on_left.({0.3, 0.36}, {0.235, 0.265}, solar, 0.003),
        on_left.({0.4, 0.46}, {0.235, 0.265}, solar, 0.003),
        on_left.({0.28, 0.5}, {0.31, 0.395}, "i-dark-t", 0.003),
        on_left.({0.6, 0.8}, {0.07, 0.78}, "i-black", 0.002)
      ] ++
        if(plus, do: [on_left.({0.28, 0.5}, {0.42, 0.51}, "i-dark-t", 0.002)], else: []) ++
        for(
          k <- 0..9,
          do: on_left.({0.08, 0.2}, {0.09 + k * 0.022, 0.1 + k * 0.022}, "i-dark-l", 0.003)
        ) ++
        for k <- 0..7 do
          on_left.({0.615 + k * 0.023, 0.625 + k * 0.023}, {0.09, 0.76}, "i-dark-l", 0.003)
        end

    # The back: the dark panel, the grip of the pull handle with its blue
    # button, the label, and the pad for the hand.
    back_side =
      [
        on_back.({0.1, 0.9}, {0.055, 0.775}, "i-dark-l", 0.001),
        on_back.({0.23, 0.77}, {0.06, 0.12}, "i-black", 0.002),
        on_back.({0.47, 0.53}, {0.08, 0.1}, "i-screen", 0.003),
        on_back.({0.33, 0.67}, {0.49, 0.585}, "i-dark-t", 0.002),
        on_back.({0.13, 0.86}, {0.66, 0.77}, "i-black", 0.002)
      ] ++
        for k <- 0..13 do
          on_back.({0.15 + k * 0.05, 0.17 + k * 0.05}, {0.67, 0.76}, "i-dark-l", 0.003)
        end

    # The top: the inlay, the gap for the hand, and the pull handle in its
    # well.
    top_side = [
      top(
        {0.012, back + 0.012, h},
        {w - 0.024, d - back - 0.024},
        if(plus, do: "i-steel-l", else: "i-dark-l"),
        0.001
      ),
      round_face(:top, {0.15 * w, d * 0.73, h + 0.002}, {0.7 * w, d * 0.15}, 0.02, "i-black"),
      round_face(:top, {0.22 * w, d * 0.08, h + 0.002}, {0.56 * w, d * 0.17}, 0.02, "i-black"),
      top({0.25 * w, d * 0.1, h}, {0.5 * w, d * 0.04}, "i-dark-t", 0.003)
    ]

    shell ++ front_side ++ right ++ left_side ++ back_side ++ top_side
  end
end
