------------------------------- MODULE Pool --------------------------------
(***************************************************************************)
(* A pool room and the places of the items (DIY.Build, DIY.Catalog.fits?). *)
(*                                                                         *)
(* A room has a place: inside, outside or the roof. A room inside or       *)
(* outside can be a pool, but not a room on the level of the roof and the  *)
(* attic (DIY.Build.pool_place?). An item of a kind goes in a room when    *)
(* the place of the room is a place of the kind. It also goes in a pool   *)
(* when the kind can go in a pool.                                         *)
(*                                                                         *)
(* The rules:                                                              *)
(* - The person adds an item, or moves it, only to a room where it fits.   *)
(* - A room on the roof or in the attic is never a pool.                   *)
(* - A room stops being a pool only when each of its items still fits.     *)
(*                                                                         *)
(* Two modes have a fault:                                                 *)
(* - "nocheck": a room stops being a pool with no check of its items. A    *)
(*   hot tub then stays in a room inside that is not a pool                *)
(*   (Pool.nocheck.cfg).                                                   *)
(* - "roof": the check is on the place only. The attic is inside, so it    *)
(*   can then be a pool, and a hot tub goes in the attic (Pool.roof.cfg).  *)
(***************************************************************************)
EXTENDS TLC

\* Four rooms: one inside, one outside, one on the roof and the attic. The
\* attic is inside, on the level of the roof. None is a model value: no
\* item.
CONSTANTS Inside, Outside, Roof, Attic, Items, Mode, None

Rooms == {Inside, Outside, Roof, Attic}
Place == (Inside :> "indoor") @@ (Outside :> "outdoor") @@ (Roof :> "roof") @@ (Attic :> "indoor")
Level == (Inside :> "f1") @@ (Outside :> "outside") @@ (Roof :> "roof") @@ (Attic :> "roof")

\* The kinds and their places, as in DIY.Catalog. A hot tub goes outside
\* or in a pool. A dishwasher goes inside. The kind "other" goes anywhere.
Kinds == {"hot_tub", "dishwasher", "other"}
Places(k) ==
  CASE k = "hot_tub" -> {"outdoor", "pool"}
    [] k = "dishwasher" -> {"indoor"}
    [] k = "other" -> {"indoor", "outdoor", "roof"}

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
  /\ Place[r] \in {"indoor", "outdoor"}
  /\ Level[r] # "roof" \/ Mode = "roof"
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

\* No room on the roof or in the attic is a pool, and no hot tub is there.
NoRoofPool ==
  /\ \A r \in pool : Level[r] # "roof"
  /\ \A i \in Items : item[i] # None /\ item[i].kind = "hot_tub" =>
       Level[item[i].room] # "roof"
=============================================================================
