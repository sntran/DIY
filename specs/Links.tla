------------------------------- MODULE Links -------------------------------
(***************************************************************************)
(* The short links of shared houses (see DIY.Links.create/2 and fetch/2). *)
(* A link keeps the day of its last visit. It ends when the day of today   *)
(* is more than Days after that day. The day goes on at any time.          *)
(*                                                                         *)
(* The storage of a Durable Object commits each statement alone, and the   *)
(* requests of the VM run at the same time. Thus each statement is one     *)
(* step, and other steps can come between the steps of a request:         *)
(* - Create: the delete of the links that ended, then the insert. Both use *)
(*   the day of today, so the model makes them one step.                   *)
(* - A visit has two steps. Read finds a link that did not end, and keeps  *)
(*   the day of the read. Write puts that day in the row with an upsert.   *)
(*   The row comes back when a different step deleted it. The row keeps   *)
(*   the later day.                                                        *)
(* - Expire: a visit of a link that ended deletes the row, only when the   *)
(*   row still has a day that ended.                                       *)
(*                                                                         *)
(* seen is not in the code: it is the day of the last visit that found the *)
(* link (or of its creation), for the check.                               *)
(*                                                                         *)
(* Two modes have a fault:                                                 *)
(* - "early": a link ends on the day Days after its last visit, one day    *)
(*   too soon (Links.early.cfg).                                           *)
(* - "noupdate": a visit does not keep its day, so a link that a person    *)
(*   visits each day still ends (Links.noupdate.cfg).                      *)
(* - "noupsert": Write is an update, not an upsert. A new link at midnight *)
(*   can delete the row between Read and Write (Links.noupsert.cfg).       *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS Ids, Days, Last, Mode

VARIABLES today,  \* the day of today
          store,  \* the day of the last visit of each link, or None
          seen,   \* the day of the last good visit of each link, or None
          reads   \* the visits between Read and Write: pairs of a link and a day

vars == <<today, store, seen, reads>>

None == -1  \* no link (a number, so TLC can compare it with a day)
Day == 0..Last
Max(a, b) == IF a >= b THEN a ELSE b

TypeOK ==
  /\ today \in Day
  /\ store \in [Ids -> Day \cup {None}]
  /\ seen \in [Ids -> Day \cup {None}]
  /\ reads \subseteq Ids \X Day

\* A link ended: more than Days after its last visit.
Ended(day) == IF Mode = "early" THEN today - day >= Days ELSE today - day > Days

\* A link that a person visited in the last Days days is there.
Kept == \A i \in Ids : (seen[i] # None /\ today - seen[i] <= Days) => store[i] # None

\* A link that did not end keeps the day of its last good visit.
Fresh == \A i \in Ids : (store[i] # None /\ ~Ended(store[i])) => store[i] = seen[i]

Init ==
  /\ today = 0
  /\ store = [i \in Ids |-> None]
  /\ seen = [i \in Ids |-> None]
  /\ reads = {}

\* A new link (a new id). First, the links that ended go.
Create(i) ==
  /\ store[i] = None
  /\ seen[i] = None
  /\ store' = [j \in Ids |->
                 IF j = i THEN today
                 ELSE IF store[j] # None /\ Ended(store[j]) THEN None
                 ELSE store[j]]
  /\ seen' = [seen EXCEPT ![i] = today]
  /\ UNCHANGED <<today, reads>>

\* A visit finds a link that did not end. Two visits at the same time at
\* most: this is enough for two visits that write different days.
Read(i) ==
  /\ Cardinality(reads) < 2
  /\ store[i] # None
  /\ ~Ended(store[i])
  /\ reads' = reads \cup {<<i, today>>}
  /\ UNCHANGED <<today, store, seen>>

\* The visit keeps its day (an upsert), and gives the house.
Write(r) ==
  LET i == r[1]
      d == r[2]
  IN /\ store' = [store EXCEPT ![i] =
                    IF Mode = "noupdate" /\ @ # None THEN @
                    ELSE IF @ = None THEN (IF Mode = "noupsert" THEN None ELSE d)
                    ELSE Max(@, d)]
     /\ seen' = [seen EXCEPT ![i] = IF @ = None THEN d ELSE Max(@, d)]
     /\ reads' = reads \ {r}
     /\ UNCHANGED today

\* A visit of a link that ended deletes it.
Expire(i) ==
  /\ store[i] # None
  /\ Ended(store[i])
  /\ store' = [store EXCEPT ![i] = None]
  /\ UNCHANGED <<today, seen, reads>>

Tick ==
  /\ today < Last
  /\ today' = today + 1
  /\ UNCHANGED <<store, seen, reads>>

Next ==
  \/ Tick
  \/ \E i \in Ids : Create(i) \/ Read(i) \/ Expire(i)
  \/ \E r \in reads : Write(r)

Spec == Init /\ [][Next]_vars
=============================================================================
