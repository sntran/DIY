------------------------------- MODULE Links -------------------------------
(***************************************************************************)
(* The short links of shared houses (see DIY.Links.create/2 and fetch/2). *)
(* A link keeps the day of its last visit. It ends when the day of today   *)
(* is more than Days after that day. A visit of a link that ended deletes  *)
(* it, and each new link first deletes all the links that ended. The day   *)
(* goes on at any time.                                                    *)
(*                                                                         *)
(* seen is not in the code: it is the day of the last visit that found the *)
(* link (or of its creation), for the check.                               *)
(*                                                                         *)
(* Two modes have a fault:                                                 *)
(* - "early": a link ends on the day Days after its last visit, one day    *)
(*   too soon (Links.early.cfg).                                           *)
(* - "noupdate": a visit does not keep its day, so a link that a person    *)
(*   visits each day still ends (Links.noupdate.cfg).                      *)
(***************************************************************************)
EXTENDS Integers

CONSTANTS Ids, Days, Last, Mode

VARIABLES today,  \* the day of today
          store,  \* the day of the last visit of each link, or None
          seen    \* the day of the last good visit of each link, or None

vars == <<today, store, seen>>

None == -1  \* no link (a number, so TLC can compare it with a day)
Day == 0..Last

TypeOK ==
  /\ today \in Day
  /\ store \in [Ids -> Day \cup {None}]
  /\ seen \in [Ids -> Day \cup {None}]

\* A link ended: more than Days after its last visit.
Ended(day) == IF Mode = "early" THEN today - day >= Days ELSE today - day > Days

\* A link that a person visited in the last Days days is there.
Kept == \A i \in Ids : (seen[i] # None /\ today - seen[i] <= Days) => store[i] # None

\* A link keeps the day of its last good visit.
Fresh == \A i \in Ids : store[i] # None => store[i] = seen[i]

Init ==
  /\ today = 0
  /\ store = [i \in Ids |-> None]
  /\ seen = [i \in Ids |-> None]

\* A new link (a new id). First, the links that ended go.
Create(i) ==
  /\ store[i] = None
  /\ seen[i] = None
  /\ store' = [j \in Ids |->
                 IF j = i THEN today
                 ELSE IF store[j] # None /\ Ended(store[j]) THEN None
                 ELSE store[j]]
  /\ seen' = [seen EXCEPT ![i] = today]
  /\ UNCHANGED today

\* A visit: a link that did not end gives its house and keeps the day. A
\* link that ended is deleted.
Visit(i) ==
  /\ store[i] # None
  /\ IF Ended(store[i])
       THEN /\ store' = [store EXCEPT ![i] = None]
            /\ UNCHANGED seen
       ELSE /\ store' = [store EXCEPT ![i] = IF Mode = "noupdate" THEN @ ELSE today]
            /\ seen' = [seen EXCEPT ![i] = today]
  /\ UNCHANGED today

Tick ==
  /\ today < Last
  /\ today' = today + 1
  /\ UNCHANGED <<store, seen>>

Next == Tick \/ \E i \in Ids : Create(i) \/ Visit(i)

Spec == Init /\ [][Next]_vars
=============================================================================
