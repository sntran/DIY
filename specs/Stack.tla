------------------------------ MODULE Stack --------------------------------
(***************************************************************************)
(* Items on other items (DIY.Stack, docs/design.md, "Items on items").     *)
(*                                                                         *)
(* Each item is in a room, at a spot of a short line (Spots). An item can  *)
(* be on an item (on[i]), or on the floor (None). The model keeps one size *)
(* for all the items: an item is over an item when the two are at the      *)
(* same spot. The code checks the center of the space of the item.         *)
(*                                                                         *)
(* The steps come in any order:                                            *)
(* - Drop: the person drops an item at a spot of a room (with a snap or    *)
(*   with the arrow keys). It goes on an item under it, or on the floor.   *)
(*   The items on it, and the items on them, move with it, by the same     *)
(*   distance, to its room. A spot stays on the line (the clamp). An item  *)
(*   that does not fit the room stays, with the items on it.               *)
(* - Move: the list of the sheet moves the item to a room, at any spot.    *)
(*   The items on it stay.                                                 *)
(* - Delete: the item goes away.                                           *)
(* After each step, an item that is not over the item under it, or that   *)
(* is in a different room, or in a loop, comes down to the floor           *)
(* (normalize/1).                                                          *)
(*                                                                         *)
(* Some items do not go in the room Out (InsideOnly): a TV does not go    *)
(* outside.                                                                *)
(*                                                                         *)
(* Three modes have a fault:                                               *)
(* - "noloop": a drop can put an item on an item that is on it, and the    *)
(*   check does not see a loop (Stack.noloop.cfg).                         *)
(* - "nodrop": a delete does not bring down the items on the item          *)
(*   (Stack.nodrop.cfg).                                                   *)
(* - "nofit": the items on an item go with it, also to a room that they do *)
(*   not fit (Stack.nofit.cfg).                                            *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS Items, Rooms, Out, InsideOnly, None, Mode

Spots == 0..2
N == Cardinality(Items)

VARIABLES present, \* the items that are there
          room,    \* the room of each item
          spot,    \* the spot of each item
          on       \* the item under each item, or None

vars == <<present, room, spot, on>>

Fits(i, r) == ~(i \in InsideOnly /\ r = Out)

Clamp(v) == IF v < 0 THEN 0 ELSE IF v > 2 THEN 2 ELSE v

\* The items under an item, down to the floor (at most k steps).
RECURSIVE Under(_, _, _)
Under(o, i, k) ==
  IF k = 0 \/ o[i] = None \/ o[i] \notin Items THEN {}
  ELSE {o[i]} \cup Under(o, o[i], k - 1)

\* The items on an item, and the items on them.
Above(o, i) == {j \in Items : i \in Under(o, j, N)}

\* An item stays on the item under it when the two still stack.
Valid(i, o, p, r, s) ==
  /\ o[i] \in p
  /\ o[i] # i
  /\ r[o[i]] = r[i]
  /\ s[o[i]] = s[i]
  /\ (Mode = "noloop" \/ i \notin Under(o, i, N))

Normalize(o, p, r, s) ==
  [i \in Items |-> IF o[i] # None /\ Valid(i, o, p, r, s) THEN o[i] ELSE None]

Init ==
  /\ present = Items
  /\ room \in {r \in [Items -> Rooms] : \A i \in Items : Fits(i, r[i])}
  /\ spot \in [Items -> Spots]
  /\ on = [i \in Items |-> None]

\* An item goes to spot x of room r. It goes on an item there, or on the
\* floor when no item there can take it. With a fault, it can go on an
\* item that is on it.
Drop(i, r, x) ==
  /\ i \in present
  /\ Fits(i, r)
  \* The items on i that go with it: each fits r, and each item between it
  \* and i fits r.
  /\ LET up == Above(on, i) \cap present
         carried == {j \in up : Mode = "nofit" \/
                       \A k \in ({j} \cup Under(on, j, N)) \cap up : Fits(k, r)}
         d == x - spot[i]
         bases == {b \in present : room[b] = r /\ spot[b] = x /\ b # i /\
                                   (Mode = "noloop" \/ b \notin carried)}
         r2 == [j \in Items |-> IF j = i \/ j \in carried THEN r ELSE room[j]]
         s2 == [j \in Items |-> IF j = i THEN x
                                ELSE IF j \in carried THEN Clamp(spot[j] + d)
                                ELSE spot[j]]
     IN \E b \in (IF bases = {} THEN {None} ELSE bases) :
          /\ room' = r2
          /\ spot' = s2
          /\ on' = Normalize([on EXCEPT ![i] = b], present, r2, s2)
  /\ UNCHANGED present

\* The list of the sheet: the item goes to a room, at any free spot.
Move(i, r) ==
  /\ i \in present
  /\ Fits(i, r)
  /\ \E x \in Spots :
       LET r2 == [room EXCEPT ![i] = r]
           s2 == [spot EXCEPT ![i] = x]
       IN /\ room' = r2
          /\ spot' = s2
          /\ on' = Normalize(on, present, r2, s2)
  /\ UNCHANGED present

\* The item goes away. With a fault, the items on it stay on it.
Delete(i) ==
  /\ i \in present
  /\ present' = present \ {i}
  /\ on' = IF Mode = "nodrop" THEN [on EXCEPT ![i] = None]
           ELSE Normalize([on EXCEPT ![i] = None], present', room, spot)
  /\ UNCHANGED <<room, spot>>

\* With no item, nothing changes.
Done == present = {} /\ UNCHANGED vars

Next ==
  \/ \E i \in Items, r \in Rooms, x \in Spots : Drop(i, r, x)
  \/ \E i \in Items, r \in Rooms : Move(i, r)
  \/ \E i \in Items : Delete(i)
  \/ Done

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ present \subseteq Items
  /\ room \in [Items -> Rooms]
  /\ spot \in [Items -> Spots]
  /\ on \in [Items -> Items \cup {None}]

\* The item under an item is there, in the same room, and under it.
OnExists ==
  \A i \in present : on[i] # None =>
    /\ on[i] \in present
    /\ room[on[i]] = room[i]
    /\ spot[on[i]] = spot[i]

\* Each item fits its room.
Fit == \A i \in present : Fits(i, room[i])

\* No item is under itself, also through other items.
NoLoop == \A i \in present : i \notin Under(on, i, N)
=============================================================================
