------------------------------- MODULE Pool --------------------------------
(***************************************************************************)
(* A pool and the places of the items (DIY.Build, DIY.Catalog.fits?).     *)
(*                                                                         *)
(* A pool is an item of a room inside or outside: a spa is a pool in a     *)
(* room inside. This is a decision of the owner (October 2026). A room has *)
(* a place: inside, outside or the roof. The attic is inside, on the level *)
(* of the roof. An item of a kind goes in a room when the place of the     *)
(* room is a place of the kind. A heavy kind (a pool, a hot tub) does not  *)
(* go on the level of the roof.                                            *)
(*                                                                         *)
(* The rules:                                                              *)
(* - The person adds an item, or moves it, only to a room where it fits.   *)
(* - No pool and no hot tub is on the roof or in the attic.                *)
(*                                                                         *)
(* Two modes have a fault:                                                 *)
(* - "nocheck": a move does not check the room. A dishwasher then goes     *)
(*   outside (Pool.nocheck.cfg).                                           *)
(* - "light": the check is on the place only. The attic is inside, so a    *)
(*   pool then goes in the attic (Pool.light.cfg).                         *)
(***************************************************************************)
EXTENDS TLC

\* Four rooms: one inside, one outside, one on the roof and the attic. None
\* is a model value: no item.
CONSTANTS Inside, Outside, Roof, Attic, Items, Mode, None

Rooms == {Inside, Outside, Roof, Attic}
Place == (Inside :> "indoor") @@ (Outside :> "outdoor") @@ (Roof :> "roof") @@ (Attic :> "indoor")
Level == (Inside :> "f1") @@ (Outside :> "outside") @@ (Roof :> "roof") @@ (Attic :> "roof")

\* The kinds and their places, as in DIY.Catalog. A pool and a hot tub go
\* inside or outside, and they are heavy. A dishwasher goes inside. The
\* kind "other" goes anywhere.
Kinds == {"pool", "hot_tub", "dishwasher", "other"}
Places(k) ==
  CASE k \in {"pool", "hot_tub"} -> {"indoor", "outdoor"}
    [] k = "dishwasher" -> {"indoor"}
    [] k = "other" -> {"indoor", "outdoor", "roof"}
Heavy(k) == k \in {"pool", "hot_tub"}

\* The rule of DIY.Catalog.fits?.
Fits(k, r) == Place[r] \in Places(k) /\ ~(Heavy(k) /\ Level[r] = "roof")

\* The check of a new place. The mode "light" checks the place only.
Check(k, r) == IF Mode = "light" THEN Place[r] \in Places(k) ELSE Fits(k, r)

VARIABLES item  \* the kind and the room of each item, or None

vars == <<item>>

TypeOK == item \in [Items -> ([kind : Kinds, room : Rooms] \cup {None})]

Init == item = [i \in Items |-> None]

AddItem(i, k, r) ==
  /\ item[i] = None
  /\ Check(k, r)
  /\ item' = [item EXCEPT ![i] = [kind |-> k, room |-> r]]

\* The mode "nocheck" moves an item to any room.
MoveItem(i, r) ==
  /\ item[i] # None
  /\ Mode = "nocheck" \/ Check(item[i].kind, r)
  /\ item' = [item EXCEPT ![i].room = r]

DeleteItem(i) ==
  /\ item[i] # None
  /\ item' = [item EXCEPT ![i] = None]

Next ==
  \/ \E i \in Items, k \in Kinds, r \in Rooms : AddItem(i, k, r)
  \/ \E i \in Items, r \in Rooms : MoveItem(i, r)
  \/ \E i \in Items : DeleteItem(i)

Spec == Init /\ [][Next]_vars

\* Each item fits its room.
Fit == \A i \in Items : item[i] # None => Fits(item[i].kind, item[i].room)

\* No pool and no hot tub is on the roof or in the attic.
NoRoofPool == \A i \in Items : item[i] # None /\ Heavy(item[i].kind) => Level[item[i].room] # "roof"
=============================================================================
