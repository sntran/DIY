------------------------------ MODULE Labels -------------------------------
(***************************************************************************)
(* The places of the labels in the picture of a shared house               *)
(* (DIYWeb.Picture.Labels, place/2).                                       *)
(*                                                                         *)
(* The labels come in their order. Each label has the top center of its   *)
(* item (x, y) and its size (w, h). The box of the picture is from 0 to W  *)
(* and from 0 to H. A label goes to a free place above its item:           *)
(* - its first height is just above the item, in the box;                  *)
(* - its other heights are just above each label that has its place;       *)
(* - at each height, it is at the center of the item, at its left or at    *)
(*   its right, in the box.                                                *)
(* A place is free when it overlaps no label that has its place. The code  *)
(* takes the nearest free place. The model takes any free place: so each   *)
(* choice of the code is a choice of the model. When no place is free, the *)
(* label has no place.                                                     *)
(*                                                                         *)
(* The numbers are whole numbers: one unit is a step of the model. Each    *)
(* step of the model is a new label, at any item and with any size, up to  *)
(* N labels.                                                               *)
(*                                                                         *)
(* Two modes have a fault:                                                 *)
(* - "nocheck": a label takes a place that is not free. Two labels then    *)
(*   overlap (Labels.nocheck.cfg).                                         *)
(* - "noclamp": a place is not kept in the box. A label near the end of    *)
(*   the box is then out of it (Labels.noclamp.cfg).                       *)
(***************************************************************************)
EXTENDS Integers

CONSTANTS W, H, N, Mode

\* The space between a label and its item, and between two labels. Then
\* the part of a label at the side of an item that is over the item.
Gap == 1
Side == 1

VARIABLES count,   \* the count of the labels that came
          first,   \* TRUE when the first label fits in the box
          placed   \* the labels in their places: [n, left, top, w, h]

vars == <<count, first, placed>>

\* A label can be wider than the box: then it has no place. An item can be
\* under the box: then the label is at the bottom of the box.
Label == [x : 0..W, y : 0..(H + 2), w : 1..(W + 1), h : 1..2]

Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a > b THEN a ELSE b

\* A number in the range lo..hi. The mode "noclamp" does not keep it there.
Clamp(v, lo, hi) == IF Mode = "noclamp" THEN v ELSE Max(Min(v, hi), lo)

Overlap(a, b) ==
  /\ a.left < b.left + b.w /\ b.left < a.left + a.w
  /\ a.top < b.top + b.h /\ b.top < a.top + a.h

Free(box) == Mode = "nocheck" \/ \A p \in placed : ~Overlap(box, p)

Fits(l) == l.w <= W /\ l.h <= H

\* The places of a label: its heights and its sides.
Places(l) ==
  LET start == Clamp(l.y - l.h - Gap, 0, H - l.h)
      tops == {start} \cup {p.top - l.h - Gap : p \in placed}
      sides == {Clamp(s, 0, W - l.w) :
                  s \in {l.x - l.w \div 2, l.x - l.w + Side, l.x - Side}}
  IN {[left |-> s, top |-> t, w |-> l.w, h |-> l.h] :
        s \in sides, t \in {t \in tops : (Mode = "noclamp" \/ t >= 0) /\ t <= start}}

Init ==
  /\ count = 0
  /\ first = FALSE
  /\ placed = {}

\* The next label comes, at any item and with any size. It takes a free
\* place, or it has no place.
Place(l) ==
  /\ count < N
  /\ LET free == {b \in Places(l) : Fits(l) /\ Free(b)}
         n == count + 1
     IN \/ \E b \in free :
             placed' = placed \cup {[n |-> n, left |-> b.left, top |-> b.top, w |-> l.w, h |-> l.h]}
        \/ free = {} /\ placed' = placed
  /\ count' = count + 1
  /\ first' = IF count = 0 THEN Fits(l) ELSE first

\* After N labels, nothing changes.
Done == count = N /\ UNCHANGED vars

Next == (\E l \in Label : Place(l)) \/ Done

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ count \in 0..N
  /\ first \in BOOLEAN
  /\ \A p \in placed : p.n \in 1..count

\* Two labels never overlap.
NoOverlap == \A a, b \in placed : a.n # b.n => ~Overlap(a, b)

\* Each label is in the box.
Inside == \A p \in placed : p.left >= 0 /\ p.left + p.w <= W /\ p.top >= 0 /\ p.top + p.h <= H

\* The first label takes its place when it fits in the box.
First == first => \E p \in placed : p.n = 1
=============================================================================
