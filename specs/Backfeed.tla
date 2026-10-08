------------------------------ MODULE Backfeed ------------------------------
(***************************************************************************)
(* A power station that powers circuits of a house through an inlet (see   *)
(* DIY.Power.warnings/1). The station must never send power to the grid   *)
(* (backfeed): in an outage, the lines of the utility are dead, and a      *)
(* worker can touch them. And when the grid is up, the station must not   *)
(* connect to it.                                                          *)
(*                                                                         *)
(* The main breaker connects the house to the grid. The inlet connects the *)
(* station. A device keeps them apart:                                     *)
(*                                                                         *)
(* - "interlock": a plate on the main panel. The inlet breaker turns on    *)
(*   only when the main breaker is off, and the main breaker only when the *)
(*   inlet breaker is off.                                                 *)
(* - "transfer": a transfer switch (or a subpanel with one). The backup    *)
(*   circuits are on the switch. It moves them from the grid to the        *)
(*   station, and it breaks one side before it makes the other. The main   *)
(*   breaker stays on.                                                     *)
(* - "none": no device (for example, a cord with a plug at each end). Each *)
(*   breaker turns on and off alone.                                       *)
(* - "makefirst": a switch that makes the new side before it breaks the   *)
(*   old one (a fault).                                                    *)
(*                                                                         *)
(* With Free = TRUE, the person can change any breaker, the switch, or the *)
(* station at any time (a mistake included). With Free = FALSE, the person *)
(* does only the steps of the page for the device, in their order.        *)
(*                                                                         *)
(* What the model checks: the rule of each device is enough to stop a      *)
(* backfeed, with any mistake of a person; and the steps of the page give  *)
(* the backup in an outage, and the grid when it comes back. The app       *)
(* shows a danger for a station that powers the panel with no device      *)
(* (Backfeed.none.cfg shows why). The model has one station and one inlet; *)
(* the app adds the stations of a house as one.                            *)
(***************************************************************************)

CONSTANTS Device, Free

VARIABLES grid,    \* "up" or "down": the power of the utility
          main,    \* "on" or "off": the main breaker
          inlet,   \* "on" or "off": the inlet (its breaker, or its cord)
          switch,  \* "grid", "both" or "station": the transfer switch
          station  \* "on" or "off": the output of the station

vars == <<grid, main, inlet, switch, station>>

Switched == Device \in {"transfer", "makefirst"}

TypeOK ==
  /\ grid \in {"up", "down"}
  /\ main \in {"on", "off"}
  /\ inlet \in {"on", "off"}
  /\ switch \in {"grid", "both", "station"}
  /\ station \in {"on", "off"}

\* The backup circuits connect to the grid, and to the station.
ToGrid == main = "on" /\ (~Switched \/ switch \in {"grid", "both"})
ToStation == inlet = "on" /\ (~Switched \/ switch \in {"station", "both"})

\* The power of the station goes to the lines of the utility.
Backfeed == station = "on" /\ ToStation /\ ToGrid

NoBackfeed == ~Backfeed

\* The station powers the backup circuits in an outage.
Backup == station = "on" /\ ToStation /\ ~ToGrid

\* The house is on the grid again.
OnGrid == main = "on" /\ (~Switched \/ switch = "grid")

Init ==
  /\ grid = "up"
  /\ main = "on"
  /\ inlet = "off"
  /\ switch = "grid"
  /\ station = "off"

\* The utility.
GridFails == grid = "up" /\ grid' = "down" /\ UNCHANGED <<main, inlet, switch, station>>
GridComes == grid = "down" /\ grid' = "up" /\ UNCHANGED <<main, inlet, switch, station>>

\* The breakers, as the device lets them change.
MainOn ==
  /\ main = "off"
  /\ Device = "interlock" => inlet = "off"
  /\ main' = "on"
  /\ UNCHANGED <<grid, inlet, switch, station>>

MainOff == main = "on" /\ main' = "off" /\ UNCHANGED <<grid, inlet, switch, station>>

InletOn ==
  /\ inlet = "off"
  /\ Device = "interlock" => main = "off"
  /\ inlet' = "on"
  /\ UNCHANGED <<grid, main, switch, station>>

InletOff == inlet = "on" /\ inlet' = "off" /\ UNCHANGED <<grid, main, switch, station>>

\* The switch moves one position: a transfer switch from "grid" to
\* "station" (or back) in one move, a "makefirst" switch through "both".
Forward(p) ==
  IF Device = "transfer"
  THEN CASE p = "grid" -> "station" [] OTHER -> "grid"
  ELSE CASE p = "grid" -> "both" [] p = "both" -> "station" [] OTHER -> p

Backward(p) ==
  IF Device = "transfer"
  THEN CASE p = "station" -> "grid" [] OTHER -> "station"
  ELSE CASE p = "station" -> "both" [] p = "both" -> "grid" [] OTHER -> p

ToStationMove ==
  /\ Switched
  /\ switch # "station"
  /\ switch' = Forward(switch)
  /\ UNCHANGED <<grid, main, inlet, station>>

ToGridMove ==
  /\ Switched
  /\ switch # "grid"
  /\ switch' = Backward(switch)
  /\ UNCHANGED <<grid, main, inlet, station>>

StationOn == station = "off" /\ station' = "on" /\ UNCHANGED <<grid, main, inlet, switch>>
StationOff == station = "on" /\ station' = "off" /\ UNCHANGED <<grid, main, inlet, switch>>

\* The steps of the page for an interlock. In an outage: turn off the main
\* breaker, turn on the inlet breaker, and turn on the station. When the
\* grid comes back: turn off the station, turn off the inlet breaker, and
\* turn on the main breaker.
Step1 == ~Switched /\ grid = "down" /\ MainOff
Step2 == ~Switched /\ grid = "down" /\ main = "off" /\ InletOn
Step3 == ~Switched /\ grid = "down" /\ inlet = "on" /\ StationOn
Step4 == ~Switched /\ grid = "up" /\ StationOff
Step5 == ~Switched /\ grid = "up" /\ station = "off" /\ InletOff
Step6 == ~Switched /\ grid = "up" /\ inlet = "off" /\ MainOn

\* The steps of the page for a transfer switch. In an outage: connect the
\* station to the inlet, turn on the station, and move the switch to the
\* station. When the grid comes back: move the switch to the grid, turn off
\* the station, and disconnect it.
Move1 == Switched /\ grid = "down" /\ InletOn
Move2 == Switched /\ grid = "down" /\ inlet = "on" /\ StationOn
Move3 == Switched /\ grid = "down" /\ station = "on" /\ ToStationMove
Move4 == Switched /\ grid = "up" /\ ToGridMove
Move5 == Switched /\ grid = "up" /\ switch = "grid" /\ StationOff
Move6 == Switched /\ grid = "up" /\ station = "off" /\ InletOff

Steps ==
  \/ Step1 \/ Step2 \/ Step3 \/ Step4 \/ Step5 \/ Step6
  \/ Move1 \/ Move2 \/ Move3 \/ Move4 \/ Move5 \/ Move6

Mistakes ==
  \/ MainOn \/ MainOff \/ InletOn \/ InletOff
  \/ ToStationMove \/ ToGridMove \/ StationOn \/ StationOff

Next ==
  \/ GridFails
  \/ GridComes
  \/ Steps
  \/ (Free /\ Mistakes)

Fairness ==
  /\ WF_vars(Step1) /\ WF_vars(Step2) /\ WF_vars(Step3)
  /\ WF_vars(Step4) /\ WF_vars(Step5) /\ WF_vars(Step6)
  /\ WF_vars(Move1) /\ WF_vars(Move2) /\ WF_vars(Move3)
  /\ WF_vars(Move4) /\ WF_vars(Move5) /\ WF_vars(Move6)

Spec == Init /\ [][Next]_vars /\ Fairness

\* A person who can stop before the end of the steps.
SpecNoFairness == Init /\ [][Next]_vars

\* In an outage, the steps of the page give the backup (or the grid comes
\* back first).
OutageServed == (grid = "down") ~> (Backup \/ grid = "up")

\* When the grid comes back, the steps of the page give the grid to the
\* house again (or the grid fails first).
GridBack == (grid = "up") ~> (OnGrid \/ grid = "down")
=============================================================================
