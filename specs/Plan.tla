-------------------------------- MODULE Plan --------------------------------
(***************************************************************************)
(* The plan of a house at scale, on a small grid (see DIY.Layout, and      *)
(* DIY.Build.move_room/4, size_room/3, place_item/4, delete_room/2 and     *)
(* add_room/4). The rooms of one layer are rectangles. The item has a      *)
(* size (a square of side Item) and a place in its room.                   *)
(*                                                                         *)
(* The person moves a room, moves the walls of a room, puts the item at a  *)
(* place in a room, removes a room and adds it again, in any order. The    *)
(* rules of the app:                                                       *)
(* - a room moves, or gets new walls, only to a place where no room is;    *)
(*   else nothing changes (the page shows a message);                      *)
(* - the item moves with its room;                                         *)
(* - when the walls of its room move, the item keeps its place in the      *)
(*   house, and then comes back in the room (Clamp).                       *)
(*                                                                         *)
(* Two modes have a fault:                                                 *)
(* - "nocheck": a room moves over a different room (Plan.nocheck.cfg);     *)
(* - "noclamp": a wall moves, and the item stays out of its room           *)
(*   (Plan.noclamp.cfg).                                                   *)
(***************************************************************************)
EXTENDS Integers

CONSTANTS Rooms,  \* the rooms of one layer
          Size,   \* the grid is from 0 to Size - 1 on each side
          Item,   \* the side of the item
          Mode,   \* "ok", "nocheck" or "noclamp"
          None    \* no room for the item

VARIABLES there,  \* the rooms that are there
          plan,   \* the plan of each room
          room,   \* the room of the item, or None
          at      \* the place of the item in its room

vars == <<there, plan, room, at>>

Cells == 0..(Size - 1)
Rect == [x : Cells, y : Cells, w : 1..Size, d : 1..Size]

InGrid(p) == p.x + p.w <= Size /\ p.y + p.d <= Size
Overlap(p, q) == p.x < q.x + q.w /\ q.x < p.x + p.w /\ p.y < q.y + q.d /\ q.y < p.y + p.d
Free(r, p) == \A s \in there \ {r} : ~Overlap(plan[s], p)

Max(a, b) == IF a > b THEN a ELSE b
Min(a, b) == IF a < b THEN a ELSE b

\* A place in a room of a side: in the room, or at 0 when the item is
\* larger than the room.
Clamp(v, side) == Max(0, Min(v, side - Item))

TypeOK ==
  /\ there \subseteq Rooms
  /\ plan \in [Rooms -> Rect]
  /\ room \in Rooms \cup {None}
  /\ at \in [x : -Size..Size, y : -Size..Size]

\* No two rooms of the layer overlap.
NoOverlap == \A r, s \in there : r # s => ~Overlap(plan[r], plan[s])

\* The item is in a room that is there, at a place in the room.
Inside ==
  room # None =>
    /\ room \in there
    /\ at.x = Clamp(at.x, plan[room].w)
    /\ at.y = Clamp(at.y, plan[room].d)

Init ==
  /\ there = Rooms
  /\ plan \in {f \in [Rooms -> Rect] :
                 /\ \A r \in Rooms : InGrid(f[r])
                 /\ \A r, s \in Rooms : r # s => ~Overlap(f[r], f[s])}
  /\ room = None
  /\ at = [x |-> 0, y |-> 0]

\* Move a room: its item goes with it.
MoveRoom(r, x, y) ==
  /\ r \in there
  /\ LET p == [plan[r] EXCEPT !.x = x, !.y = y]
     IN /\ InGrid(p)
        /\ Mode = "nocheck" \/ Free(r, p)
        /\ plan' = [plan EXCEPT ![r] = p]
  /\ UNCHANGED <<there, room, at>>

\* Move the walls of a room: the item keeps its place in the house, then
\* comes back in the room.
SizeRoom(r, p) ==
  /\ r \in there
  /\ InGrid(p)
  /\ Free(r, p)
  /\ plan' = [plan EXCEPT ![r] = p]
  /\ IF room = r
       THEN LET x == at.x - (p.x - plan[r].x)
                y == at.y - (p.y - plan[r].y)
            IN at' = IF Mode = "noclamp"
                       THEN [x |-> x, y |-> y]
                       ELSE [x |-> Clamp(x, p.w), y |-> Clamp(y, p.d)]
       ELSE UNCHANGED at
  /\ UNCHANGED <<there, room>>

\* Put the item at a place in a room (a drag, an arrow key, or a new item).
PlaceItem(r, x, y) ==
  /\ r \in there
  /\ room' = r
  /\ at' = [x |-> Clamp(x, plan[r].w), y |-> Clamp(y, plan[r].d)]
  /\ UNCHANGED <<there, plan>>

\* Remove a room: the item in it goes too.
DeleteRoom(r) ==
  /\ r \in there
  /\ there' = there \ {r}
  /\ UNCHANGED plan
  /\ IF room = r
       THEN room' = None /\ at' = [x |-> 0, y |-> 0]
       ELSE UNCHANGED <<room, at>>

\* Add the room again: it goes to a free place, if there is one.
AddRoom(r) ==
  /\ r \notin there
  /\ \E p \in Rect : InGrid(p) /\ Free(r, p) /\ plan' = [plan EXCEPT ![r] = p]
  /\ there' = there \cup {r}
  /\ UNCHANGED <<room, at>>

Next ==
  \E r \in Rooms :
    \/ \E x, y \in Cells : MoveRoom(r, x, y)
    \/ \E p \in Rect : SizeRoom(r, p)
    \/ \E x, y \in -1..Size : PlaceItem(r, x, y)
    \/ DeleteRoom(r)
    \/ AddRoom(r)

Spec == Init /\ [][Next]_vars
=============================================================================
