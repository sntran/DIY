------------------------------ MODULE VanPlan ------------------------------
(***************************************************************************)
(* The zones of a van along the van, on a small grid (see DIY.Layout:      *)
(* van_box/1, engine_box/1, van_draft/2 and fill/1, and                    *)
(* DIY.Build.move_room/4). A zone is a part of the length of the van: from *)
(* y to y + d.                                                             *)
(*                                                                         *)
(* The box of the van has the length of its model. The cab is fixed: it    *)
(* is at the front of the box. The engine bay is fixed too: it is in       *)
(* front of the box, on a layer of its own. The bed and the galley move.   *)
(* The person does these steps in any order:                               *)
(* - move a zone, or give it a new depth;                                  *)
(* - choose a different model: the box gets a different length.            *)
(* The rules of the app:                                                   *)
(* - A zone moves only to a place in the box where no zone is.             *)
(* - The cab and the engine bay do not move.                               *)
(* - After a change, the fill keeps the plans of the floor when these      *)
(*   rules hold. Each zone of the floor is in the box, no two of them      *)
(*   overlap, and the cab is at its place. Else all the zones of the floor *)
(*   get the draft of the model. The engine bay always gets its draft.     *)
(*                                                                         *)
(* A stored build can have any plans, or a van of an older version with no *)
(* engine bay: the fill makes them whole. The engine bay does not change   *)
(* the good plans of the floor (FillKeepsFloor).                           *)
(*                                                                         *)
(* Three modes have a fault:                                               *)
(* - "nobox": a zone moves out of the box (VanPlan.nobox.cfg);             *)
(* - "nocab": the fill does not check the place of the cab, so a new      *)
(*   model keeps the old cab (VanPlan.nocab.cfg);                          *)
(* - "noengine": the fill keeps the stored engine bay, so a new model     *)
(*   keeps the old engine bay (VanPlan.noengine.cfg).                      *)
(***************************************************************************)
EXTENDS Integers

CONSTANTS Lengths,  \* the lengths of the models (3 or more)
          Mode      \* "ok", "nobox", "nocab" or "noengine"

VARIABLES len,      \* the length of the box of the van
          plan      \* the plan of each zone: [y, d]

vars == <<len, plan>>

Floor == {"bed", "galley", "cab"}
Zones == Floor \union {"engine"}
Moving == {"bed", "galley"}
Span == [y : 0..(2 * 10), d : 1..10]

In(p, l) == p.y >= 0 /\ p.y + p.d <= l
Overlap(p, q) == p.y < q.y + q.d /\ q.y < p.y + p.d

\* The draft of a model: the bed at the back, the galley, and the cab of
\* depth 1 at the front. The engine bay of depth 1 is in front of the box.
Draft(l) == [z \in Zones |->
               CASE z = "bed" -> [y |-> 0, d |-> 1]
                 [] z = "galley" -> [y |-> 1, d |-> l - 2]
                 [] z = "cab" -> [y |-> l - 1, d |-> 1]
                 [] z = "engine" -> [y |-> l, d |-> 1]]

Good(p, l) ==
  /\ \A z \in Floor : In(p[z], l)
  /\ \A z, w \in Floor : z # w => ~Overlap(p[z], p[w])
  /\ Mode = "nocab" \/ p["cab"] = Draft(l)["cab"]

Fill(p, l) ==
  LET q == IF Good(p, l) THEN p ELSE Draft(l)
  IN  IF Mode = "noengine" THEN q ELSE [q EXCEPT !["engine"] = Draft(l)["engine"]]

TypeOK ==
  /\ len \in Lengths
  /\ plan \in [Zones -> Span]

\* Each zone of the floor is in the box of the van.
InBox == \A z \in Floor : In(plan[z], len)

\* No two zones of the floor overlap.
NoOverlap == \A z, w \in Floor : z # w => ~Overlap(plan[z], plan[w])

\* The cab is at the front of the box.
CabAtFront == plan["cab"] = Draft(len)["cab"]

\* The engine bay is in front of the box.
EngineAtFront == plan["engine"] = Draft(len)["engine"]

\* A stored build can have any plans: the fill makes them whole.
Stored == [y : 0..5, d : 1..3]

\* The fill keeps the good plans of the floor, with any engine bay.
FillKeepsFloor ==
  \A l \in Lengths, p \in [Zones -> Stored] :
    Good(p, l) => \A z \in Floor : Fill(p, l)[z] = p[z]

ASSUME FillKeepsFloor

Init ==
  /\ len \in Lengths
  /\ \E p \in [Zones -> Stored] : plan = Fill(p, len)

\* Move a zone, or give it a new depth (DIY.Build.move_room/4, size_room/3).
Change(z, p) ==
  /\ Mode = "nobox" \/ In(p, len)
  /\ \A w \in Floor \ {z} : ~Overlap(p, plan[w])
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
