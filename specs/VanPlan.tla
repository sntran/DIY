------------------------------ MODULE VanPlan ------------------------------
(***************************************************************************)
(* The zones of a van along the van, on a small grid (see DIY.Layout:      *)
(* van_box/1, van_draft/2 and fill/1, and DIY.Build.move_room/4). A zone   *)
(* is a part of the length of the van: from y to y + d.                    *)
(*                                                                         *)
(* The box of the van has the length of its model. The cab is fixed: it    *)
(* is at the front of the box. The bed and the galley move. The person     *)
(* does these steps in any order:                                          *)
(* - move a zone, or give it a new depth;                                  *)
(* - choose a different model: the box gets a different length.            *)
(* The rules of the app:                                                   *)
(* - A zone moves only to a place in the box where no zone is.             *)
(* - The cab does not move.                                                *)
(* - After a change, the fill keeps the plans when these rules hold. Each *)
(*   zone is in the box, no two zones overlap, and the cab is at its       *)
(*   place. Else all the zones get the draft of the model.                 *)
(*                                                                         *)
(* Two modes have a fault:                                                 *)
(* - "nobox": a zone moves out of the box (VanPlan.nobox.cfg);             *)
(* - "nocab": the fill does not check the place of the cab, so a new      *)
(*   model keeps the old cab (VanPlan.nocab.cfg).                          *)
(***************************************************************************)
EXTENDS Integers

CONSTANTS Lengths,  \* the lengths of the models (3 or more)
          Mode      \* "ok", "nobox" or "nocab"

VARIABLES len,      \* the length of the box of the van
          plan      \* the plan of each zone: [y, d]

vars == <<len, plan>>

Zones == {"bed", "galley", "cab"}
Moving == {"bed", "galley"}
Span == [y : 0..(2 * 10), d : 1..10]

In(p, l) == p.y >= 0 /\ p.y + p.d <= l
Overlap(p, q) == p.y < q.y + q.d /\ q.y < p.y + p.d

\* The draft of a model: the bed at the back, the galley, and the cab of
\* depth 1 at the front.
Draft(l) == [z \in Zones |->
               CASE z = "bed" -> [y |-> 0, d |-> 1]
                 [] z = "galley" -> [y |-> 1, d |-> l - 2]
                 [] z = "cab" -> [y |-> l - 1, d |-> 1]]

Good(p, l) ==
  /\ \A z \in Zones : In(p[z], l)
  /\ \A z, w \in Zones : z # w => ~Overlap(p[z], p[w])
  /\ Mode = "nocab" \/ p["cab"] = Draft(l)["cab"]

Fill(p, l) == IF Good(p, l) THEN p ELSE Draft(l)

TypeOK ==
  /\ len \in Lengths
  /\ plan \in [Zones -> Span]

\* Each zone is in the box of the van.
InBox == \A z \in Zones : In(plan[z], len)

\* No two zones overlap.
NoOverlap == \A z, w \in Zones : z # w => ~Overlap(plan[z], plan[w])

\* The cab is at the front of the box.
CabAtFront == plan["cab"] = Draft(len)["cab"]

\* A stored build can have any plans: the fill makes them whole.
Stored == [y : 0..5, d : 1..3]

Init ==
  /\ len \in Lengths
  /\ \E p \in [Zones -> Stored] : plan = Fill(p, len)

\* Move a zone, or give it a new depth (DIY.Build.move_room/4, size_room/3).
Change(z, p) ==
  /\ Mode = "nobox" \/ In(p, len)
  /\ \A w \in Zones \ {z} : ~Overlap(p, plan[w])
  /\ plan' = [plan EXCEPT ![z] = p]
  /\ UNCHANGED len

\* Choose a different model: the fill makes the plan whole again.
NewModel(l) ==
  /\ len' = l
  /\ plan' = Fill(plan, l)

Next ==
  \/ \E z \in Moving, p \in Span : p.y < 10 /\ Change(z, p)
  \/ \E l \in Lengths : NewModel(l)

Spec == Init /\ [][Next]_vars
=============================================================================
