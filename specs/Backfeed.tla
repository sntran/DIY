------------------------------ MODULE Backfeed ------------------------------
(***************************************************************************)
(* A power station that powers circuits of a house through an inlet (see   *)
(* DIY.Power.warnings/1). The station must never send power to the grid   *)
(* (backfeed): in an outage, the lines of the utility are dead, and a      *)
(* worker can touch them. And when the grid is up, the station must not   *)
(* connect to it.                                                          *)
(*                                                                         *)
(* The main breaker connects the house to the grid. The inlet breaker      *)
(* connects the station to the house. A device keeps them apart:          *)
(*                                                                         *)
(* - "interlock": a plate on the panel. The inlet breaker turns on only    *)
(*   when the main breaker is off, and the main breaker only when the      *)
(*   inlet breaker is off.                                                 *)
(* - "transfer": a transfer switch. It breaks one side before it makes     *)
(*   the other: for this model, the same rule as an interlock.             *)
(* - "none": no device (for example, a cord with a plug at each end). Each *)
(*   breaker turns on and off alone.                                       *)
(*                                                                         *)
(* With Free = TRUE, the person can turn any breaker on or off at any      *)
(* time (a mistake included). With Free = FALSE, the person does only the  *)
(* steps of the app, in their order.                                       *)
(*                                                                         *)
(* The app accepts a station that powers the panel only with an interlock *)
(* or a transfer switch. Backfeed.none.cfg shows why: with no device, one  *)
(* mistake sends the power of the station to the grid.                     *)
(***************************************************************************)

CONSTANTS Device, Free

VARIABLES grid,    \* "up" or "down": the power of the utility
          main,    \* "on" or "off": the main breaker
          inlet,   \* "on" or "off": the inlet breaker
          station  \* "on" or "off": the output of the station

vars == <<grid, main, inlet, station>>

TypeOK ==
  /\ grid \in {"up", "down"}
  /\ main \in {"on", "off"}
  /\ inlet \in {"on", "off"}
  /\ station \in {"on", "off"}

\* The power of the station goes to the lines of the utility.
Backfeed == station = "on" /\ inlet = "on" /\ main = "on"

NoBackfeed == ~Backfeed

\* The station powers the circuits of the house in an outage.
Backup == station = "on" /\ inlet = "on" /\ main = "off"

Init ==
  /\ grid = "up"
  /\ main = "on"
  /\ inlet = "off"
  /\ station = "off"

\* The utility.
GridFails == grid = "up" /\ grid' = "down" /\ UNCHANGED <<main, inlet, station>>
GridComes == grid = "down" /\ grid' = "up" /\ UNCHANGED <<main, inlet, station>>

\* The breakers, as the device lets them change.
MainOn ==
  /\ main = "off"
  /\ Device = "none" \/ inlet = "off"
  /\ main' = "on"
  /\ UNCHANGED <<grid, inlet, station>>

MainOff == main = "on" /\ main' = "off" /\ UNCHANGED <<grid, inlet, station>>

InletOn ==
  /\ inlet = "off"
  /\ Device = "none" \/ main = "off"
  /\ inlet' = "on"
  /\ UNCHANGED <<grid, main, station>>

InletOff == inlet = "on" /\ inlet' = "off" /\ UNCHANGED <<grid, main, station>>

StationOn == station = "off" /\ station' = "on" /\ UNCHANGED <<grid, main, inlet>>
StationOff == station = "on" /\ station' = "off" /\ UNCHANGED <<grid, main, inlet>>

\* The steps of the app. In an outage: turn off the main breaker, turn on
\* the inlet breaker, and turn on the station. When the grid comes back:
\* turn off the station, turn off the inlet breaker, and turn on the main
\* breaker.
Step1 == grid = "down" /\ MainOff
Step2 == grid = "down" /\ main = "off" /\ InletOn
Step3 == grid = "down" /\ inlet = "on" /\ StationOn
Step4 == grid = "up" /\ StationOff
Step5 == grid = "up" /\ station = "off" /\ InletOff
Step6 == grid = "up" /\ inlet = "off" /\ MainOn

Steps == Step1 \/ Step2 \/ Step3 \/ Step4 \/ Step5 \/ Step6

Mistakes == MainOn \/ MainOff \/ InletOn \/ InletOff \/ StationOn \/ StationOff

Next ==
  \/ GridFails
  \/ GridComes
  \/ Steps
  \/ (Free /\ Mistakes)

Fairness ==
  /\ WF_vars(Step1)
  /\ WF_vars(Step2)
  /\ WF_vars(Step3)
  /\ WF_vars(Step4)
  /\ WF_vars(Step5)
  /\ WF_vars(Step6)

Spec == Init /\ [][Next]_vars /\ Fairness

\* A person who can stop before the end of the steps.
SpecNoFairness == Init /\ [][Next]_vars

\* In an outage, the steps of the app give the backup (or the grid comes
\* back first).
OutageServed == (grid = "down") ~> (Backup \/ grid = "up")

\* When the grid comes back, the steps of the app give the grid to the
\* house again (or the grid fails first).
GridBack == (grid = "up") ~> (main = "on" \/ grid = "down")
=============================================================================
