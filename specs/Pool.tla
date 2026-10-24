------------------------------- MODULE Pool --------------------------------
(***************************************************************************)
(* A pool room and the places of the items (DIY.Build, DIY.Catalog.fits?). *)
(*                                                                         *)
(* A room has a place: inside, outside or the roof. A room inside or       *)
(* outside can be a pool. An item of a kind goes in a room when the place  *)
(* of the room is a place of the kind. It also goes in a pool when the     *)
(* kind can go in a pool.                                                  *)
(*                                                                         *)
(* The rules:                                                              *)
(* - The person adds an item, or moves it, only to a room where it fits.   *)
(* - A room on the roof is never a pool.                                   *)
(* - A room stops being a pool only when each of its items still fits.     *)
(*                                                                         *)
(* Two modes have a fault:                                                 *)
(* - "nocheck": a room stops being a pool with no check of its items. A    *)
(*   hot tub then stays in a room inside that is not a pool                *)
(*   (Pool.nocheck.cfg).                                                   *)
(* - "roof": a room on the roof can be a pool. A pool pump then goes on    *)
(*   the roof (Pool.roof.cfg).                                             *)
(***************************************************************************)
EXTENDS TLC

\* Three rooms: one inside, one outside and one on the roof. None is a
\* model value: no item.
CONSTANTS Inside, Outside, Roof, Items, Mode, None

Rooms == {Inside, Outside, Roof}
Place == (Inside :> "indoor") @@ (Outside :> "outdoor") @@ (Roof :> "roof")

\* The kinds and their places, as in DIY.Catalog: a hot tub goes outside
\* or in a pool, a dishwasher goes inside, a light goes anywhere.
Kinds == {"hot_tub", "dishwasher", "light"}
Places(k) ==
  CASE k = "hot_tub" -> {"outdoor", "pool"}
    [] k = "dishwasher" -> {"indoor"}
    [] k = "light" -> {"indoor", "outdoor", "roof"}

VARIABLES pool,  \* the rooms that are a pool
          item   \* the kind and the room of each item, or None

vars == <<pool, item>>

Fits(k, r, p) == Place[r] \in Places(k) \/ ("pool" \in Places(k) /\ r \in p)

TypeOK ==
  /\ pool \subseteq Rooms
  /\ item \in [Items -> ([kind : Kinds, room : Rooms] \cup {None})]

Init ==
  /\ pool = {}
  /\ item = [i \in Items |-> None]

AddItem(i, k, r) ==
  /\ item[i] = None
  /\ Fits(k, r, pool)
  /\ item' = [item EXCEPT ![i] = [kind |-> k, room |-> r]]
  /\ UNCHANGED pool

MoveItem(i, r) ==
  /\ item[i] # None
  /\ Fits(item[i].kind, r, pool)
  /\ item' = [item EXCEPT ![i].room = r]
  /\ UNCHANGED pool

DeleteItem(i) ==
  /\ item[i] # None
  /\ item' = [item EXCEPT ![i] = None]
  /\ UNCHANGED pool

\* Build.set_pool(build, r, true).
PoolOn(r) ==
  /\ r \notin pool
  /\ Place[r] \in {"indoor", "outdoor"} \/ Mode = "roof"
  /\ pool' = pool \cup {r}
  /\ UNCHANGED item

\* Build.set_pool(build, r, false).
PoolOff(r) ==
  /\ r \in pool
  /\ \/ Mode = "nocheck"
     \/ \A i \in Items : item[i] # None /\ item[i].room = r =>
          Fits(item[i].kind, r, pool \ {r})
  /\ pool' = pool \ {r}
  /\ UNCHANGED item

Next ==
  \/ \E i \in Items, k \in Kinds, r \in Rooms : AddItem(i, k, r)
  \/ \E i \in Items, r \in Rooms : MoveItem(i, r)
  \/ \E i \in Items : DeleteItem(i)
  \/ \E r \in Rooms : PoolOn(r) \/ PoolOff(r)

Spec == Init /\ [][Next]_vars

\* Each item fits its room.
Fit == \A i \in Items : item[i] # None => Fits(item[i].kind, item[i].room, pool)

\* No room on the roof is a pool, and no hot tub is on the roof.
NoRoofPool ==
  /\ \A r \in pool : Place[r] # "roof"
  /\ \A i \in Items : item[i] # None /\ item[i].kind = "hot_tub" =>
       Place[item[i].room] # "roof"
=============================================================================
