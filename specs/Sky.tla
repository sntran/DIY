------------------------------- MODULE Sky --------------------------------
(***************************************************************************)
(* The sky at the house on the page House (DIYWeb.HomeLive, load_sky).     *)
(*                                                                         *)
(* The build has a ZIP code, or none. The person can change it at any      *)
(* time. For a new ZIP code, the page asks Open-Meteo for its sky, and it  *)
(* shows no sky until the answer comes. The answers come in any order, and *)
(* an answer can be an error (no sky). After an answer, a timer asks again *)
(* in 30 minutes. Then the page keeps the sky of before until the new      *)
(* answer comes.                                                           *)
(*                                                                         *)
(* The rules:                                                              *)
(* - An answer is for the ZIP code of the page, or the page ignores it.    *)
(* - A new timer cancels the timer before. A new ZIP code cancels it too.  *)
(* - A timer for a different ZIP code asks nothing.                        *)
(*                                                                         *)
(* Two modes have a fault:                                                 *)
(* - "nocheck": the page takes each answer. The sky of an old ZIP code     *)
(*   then shows for a new ZIP code (Sky.nocheck.cfg).                      *)
(* - "nocancel": a timer stays when a new one starts. After a ZIP code     *)
(*   changes and comes back, two timers ask again (Sky.nocancel.cfg).      *)
(***************************************************************************)
EXTENDS Naturals

\* None is a model value: no ZIP code, or no sky. The sky of a ZIP code is
\* the ZIP code itself.
CONSTANTS Zips, MaxAsks, Mode, None

VARIABLES zip,     \* the ZIP code of the build, or None
          sky,     \* the ZIP code of the page and its sky (or None)
          asks,    \* the requests that wait for an answer, for each ZIP code
          timers   \* the timers that wait, for each ZIP code

vars == <<zip, sky, asks, timers>>

NoTimer == [z \in Zips |-> 0]

TypeOK ==
  /\ zip \in Zips \cup {None}
  /\ sky \in [zip : Zips \cup {None}, now : Zips \cup {None}]
  /\ asks \in [Zips -> 0..MaxAsks]
  /\ timers \in [Zips -> 0..2]

Init ==
  /\ zip = None
  /\ sky = [zip |-> None, now |-> None]
  /\ asks = [z \in Zips |-> 0]
  /\ timers = NoTimer

\* A new timer, or no timer: the mode "nocancel" keeps the timers before.
Cancel(t) == IF Mode = "nocancel" THEN t ELSE NoTimer

\* The person changes the ZIP code of the build (load_sky).
SetZip(z) ==
  /\ z # zip
  /\ zip' = z
  /\ IF z = None
       THEN /\ sky' = [zip |-> None, now |-> None]
            /\ timers' = Cancel(timers)
            /\ UNCHANGED asks
       ELSE /\ asks[z] < MaxAsks
            /\ sky' = [zip |-> z, now |-> None]
            /\ asks' = [asks EXCEPT ![z] = @ + 1]
            /\ timers' = Cancel(timers)

\* An answer for z: the sky of z, or an error (handle_async).
Answer(z, ok) ==
  /\ asks[z] > 0
  /\ asks' = [asks EXCEPT ![z] = @ - 1]
  /\ IF sky.zip = z \/ Mode = "nocheck"
       THEN /\ timers[z] < 2
            /\ sky' = [sky EXCEPT !.now = IF ok THEN z ELSE None]
            /\ timers' = [Cancel(timers) EXCEPT ![z] = @ + 1]
       ELSE UNCHANGED <<sky, timers>>
  /\ UNCHANGED zip

\* A timer for z ends (handle_info, {:sky_again, z}). The sky stays.
Fire(z) ==
  /\ timers[z] > 0
  /\ timers' = [timers EXCEPT ![z] = @ - 1]
  /\ IF sky.zip = z /\ asks[z] < MaxAsks
       THEN asks' = [asks EXCEPT ![z] = @ + 1]
       ELSE UNCHANGED asks
  /\ UNCHANGED <<zip, sky>>

Next ==
  \/ \E z \in Zips \cup {None} : SetZip(z)
  \/ \E z \in Zips, ok \in BOOLEAN : Answer(z, ok)
  \/ \E z \in Zips : Fire(z)

Spec == Init /\ [][Next]_vars

\* The page shows the sky of its ZIP code, or no sky.
Shown == sky.now \in {None, sky.zip}

\* At most one timer waits.
OneTimer == \A a, b \in Zips : a # b => timers[a] + timers[b] <= 1 /\ timers[a] <= 1
=============================================================================
