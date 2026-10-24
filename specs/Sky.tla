------------------------------- MODULE Sky --------------------------------
(***************************************************************************)
(* The sky at the house on the page House (DIYWeb.HomeLive, load_sky).     *)
(*                                                                         *)
(* The build has a ZIP code, or none. The person can change it at any      *)
(* time. For a new ZIP code, the page asks Open-Meteo for its sky, and it  *)
(* shows no sky until the answer comes. The answers come in any order. An  *)
(* answer can be an error: then the page keeps the sky of before. After an *)
(* answer, a timer asks again. Then the page keeps the sky of before until *)
(* the new answer comes.                                                   *)
(*                                                                         *)
(* A timer that ends puts a message in the mailbox of the page. A cancel   *)
(* stops a timer, but it cannot take back its message.                     *)
(*                                                                         *)
(* The rules:                                                              *)
(* - An answer is for the ZIP code of the page, or the page ignores it.    *)
(* - A new timer cancels the timer before. A new ZIP code cancels it too.  *)
(* - A message of a timer for a different ZIP code asks nothing.           *)
(*                                                                         *)
(* Two modes have a fault:                                                 *)
(* - "nocheck": the page takes each answer. The sky of an old ZIP code     *)
(*   then shows for a new ZIP code (Sky.nocheck.cfg).                      *)
(* - "nocancel": a timer stays when a new one starts. After a ZIP code     *)
(*   changes and comes back, two timers ask again (Sky.nocancel.cfg).      *)
(***************************************************************************)
EXTENDS Naturals

\* None is a model value: no ZIP code, or no sky. The sky of a ZIP code is
\* the ZIP code itself. The counts stop at Max: the model does not count
\* more than Max requests, timers or messages for a ZIP code.
CONSTANTS Zips, Max, Mode, None

VARIABLES zip,     \* the ZIP code of the build, or None
          sky,     \* the ZIP code of the page and its sky (or None)
          asks,    \* the requests that wait for an answer, for each ZIP code
          timers,  \* the timers that wait, for each ZIP code
          mailbox  \* the messages of the timers that ended, for each ZIP code

vars == <<zip, sky, asks, timers, mailbox>>

Count == [Zips -> 0..Max]
Up(c, z) == [c EXCEPT ![z] = IF @ < Max THEN @ + 1 ELSE Max]
Down(c, z) == [c EXCEPT ![z] = @ - 1]
None0 == [z \in Zips |-> 0]

TypeOK ==
  /\ zip \in Zips \cup {None}
  /\ sky \in [zip : Zips \cup {None}, now : Zips \cup {None}]
  /\ asks \in Count /\ timers \in Count /\ mailbox \in Count

Init ==
  /\ zip = None
  /\ sky = [zip |-> None, now |-> None]
  /\ asks = None0 /\ timers = None0 /\ mailbox = None0

\* The cancel of the timer of the page: the mode "nocancel" keeps it.
Cancel(t) == IF Mode = "nocancel" THEN t ELSE None0

\* The person changes the ZIP code of the build (load_sky).
SetZip(z) ==
  /\ z # zip
  /\ zip' = z
  /\ timers' = Cancel(timers)
  /\ IF z = None
       THEN /\ sky' = [zip |-> None, now |-> None]
            /\ UNCHANGED asks
       ELSE /\ sky' = [zip |-> z, now |-> None]
            /\ asks' = Up(asks, z)
  /\ UNCHANGED mailbox

\* An answer for z: the sky of z, or an error that keeps the sky of
\* before (handle_async). Then a new timer.
Answer(z, ok) ==
  /\ asks[z] > 0
  /\ asks' = Down(asks, z)
  /\ IF sky.zip = z \/ Mode = "nocheck"
       THEN /\ sky' = IF ok THEN [sky EXCEPT !.now = z] ELSE sky
            /\ timers' = Up(Cancel(timers), z)
       ELSE UNCHANGED <<sky, timers>>
  /\ UNCHANGED <<zip, mailbox>>

\* A timer for z ends: its message goes to the mailbox.
Fire(z) ==
  /\ timers[z] > 0
  /\ timers' = Down(timers, z)
  /\ mailbox' = Up(mailbox, z)
  /\ UNCHANGED <<zip, sky, asks>>

\* The page reads a message of a timer for z (handle_info, {:sky_again,
\* z}). For its ZIP code, it cancels its timer and asks again; the sky
\* stays.
Read(z) ==
  /\ mailbox[z] > 0
  /\ mailbox' = Down(mailbox, z)
  /\ IF sky.zip = z
       THEN /\ asks' = Up(asks, z)
            /\ timers' = Cancel(timers)
       ELSE UNCHANGED <<asks, timers>>
  /\ UNCHANGED <<zip, sky>>

Next ==
  \/ \E z \in Zips \cup {None} : SetZip(z)
  \/ \E z \in Zips, ok \in BOOLEAN : Answer(z, ok)
  \/ \E z \in Zips : Fire(z) \/ Read(z)

Spec == Init /\ [][Next]_vars

\* The page shows the sky of its ZIP code, or no sky.
Shown == sky.now \in {None, sky.zip}

\* At most one timer waits.
OneTimer ==
  /\ \A z \in Zips : timers[z] <= 1
  /\ \A a, b \in Zips : a # b => timers[a] + timers[b] <= 1
=============================================================================
