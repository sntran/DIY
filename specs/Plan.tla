-------------------------------- MODULE Plan --------------------------------
(***************************************************************************)
(* The plan of a house at scale, on a small grid (see DIY.Layout and      *)
(* DIY.Build). The rooms of one layer are rectangles. The item is a       *)
(* rectangle of w by d, with a place in its room.                          *)
(*                                                                         *)
(* The person does these steps in any order: move a room, move the walls  *)
(* of a room, put the item at a place, turn the item, give the item a new  *)
(* size, remove a room, and add it again. The rules of the app:            *)
(* - a room moves, or gets new walls, only to a place where no room is;    *)
(*   else nothing changes (the page shows a message);                      *)
(* - the item moves with its room;                                         *)
(* - when the walls of its room move, the item keeps its place in the      *)
(*   house, and then comes back in the room (Clamp);                       *)
(* - a turn keeps the center of the item, and swaps w and d; a new size    *)
(*   keeps its corner. Then the item comes back in its room (Clamp).       *)
(*                                                                         *)
(* Three modes have a fault:                                               *)
(* - "nocheck": a room moves over a different room (Plan.nocheck.cfg);     *)
(* - "noclamp": a wall moves, and the item stays out of its room           *)
(*   (Plan.noclamp.cfg);                                                   *)
(* - "noturn": the item turns or gets a new size, and it stays out of its  *)
(*   room (Plan.noturn.cfg).                                               *)
(***************************************************************************)
EXTENDS Integers

CONSTANTS Rooms,  \* the rooms of one layer
          Size,   \* the grid is from 0 to Size - 1 on each side
          Sides,  \* the sides that the item can have
          Mode,   \* "ok", "nocheck", "noclamp" or "noturn"
          None    \* no room for the item

VARIABLES there,  \* the rooms that are there
          plan,   \* the plan of each room
          room,   \* the room of the item, or None
          at,     \* the place of the item in its room
          item    \* the size of the item: w by d

vars == <<there, plan, room, at, item>>

Cells == 0..(Size - 1)
Rect == [x : Cells, y : Cells, w : 1..Size, d : 1..Size]

InGrid(p) == p.x + p.w <= Size /\ p.y + p.d <= Size
Overlap(p, q) == p.x < q.x + q.w /\ q.x < p.x + p.w /\ p.y < q.y + q.d /\ q.y < p.y + p.d
Free(r, p) == \A s \in there \ {r} : ~Overlap(plan[s], p)

Max(a, b) == IF a > b THEN a ELSE b
Min(a, b) == IF a < b THEN a ELSE b

\* Half of a number, to 0 (as div in Elixir).
Half(n) == IF n >= 0 THEN n \div 2 ELSE -((-n) \div 2)

\* A place in a room of a side, for a side of the item: in the room, or at
\* 0 when the item is larger than the room.
Clamp(v, side, length) == Max(0, Min(v, side - length))

\* The place of the item in a room, for a size of the item.
In(p, r, s) == [x |-> Clamp(p.x, plan[r].w, s.w), y |-> Clamp(p.y, plan[r].d, s.d)]

TypeOK ==
  /\ there \subseteq Rooms
  /\ plan \in [Rooms -> Rect]
  /\ room \in Rooms \cup {None}
  /\ at \in [x : -2 * Size..2 * Size, y : -2 * Size..2 * Size]
  /\ item \in [w : Sides, d : Sides]

\* No two rooms of the layer overlap.
NoOverlap == \A r, s \in there : r # s => ~Overlap(plan[r], plan[s])

\* The item is in a room that is there, at a place in the room.
Inside ==
  room # None =>
    /\ room \in there
    /\ at = In(at, room, item)

Init ==
  /\ there = Rooms
  /\ plan \in {f \in [Rooms -> Rect] :
                 /\ \A r \in Rooms : InGrid(f[r])
                 /\ \A r, s \in Rooms : r # s => ~Overlap(f[r], f[s])}
  /\ room = None
  /\ at = [x |-> 0, y |-> 0]
  /\ item \in [w : Sides, d : Sides]

\* Move a room: its item goes with it.
MoveRoom(r, x, y) ==
  /\ r \in there
  /\ LET p == [plan[r] EXCEPT !.x = x, !.y = y]
     IN /\ InGrid(p)
        /\ Mode = "nocheck" \/ Free(r, p)
        /\ plan' = [plan EXCEPT ![r] = p]
  /\ UNCHANGED <<there, room, at, item>>

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
                       ELSE [x |-> Clamp(x, p.w, item.w), y |-> Clamp(y, p.d, item.d)]
       ELSE UNCHANGED at
  /\ UNCHANGED <<there, room, item>>

\* Put the item at a place in a room (a drag, an arrow key, or a new item).
PlaceItem(r, x, y) ==
  /\ r \in there
  /\ room' = r
  /\ at' = In([x |-> x, y |-> y], r, item)
  /\ UNCHANGED <<there, plan, item>>

\* A new place and size of the item in its room: it comes back in the room
\* (in the mode "noturn", it does not).
Fit(p, s) ==
  /\ at' = IF Mode = "noturn" THEN p ELSE In(p, room, s)
  /\ item' = s
  /\ UNCHANGED <<there, plan, room>>

\* Turn the item a quarter turn: its center stays, w and d swap.
TurnItem ==
  /\ room # None
  /\ Fit([x |-> at.x + Half(item.w - item.d), y |-> at.y + Half(item.d - item.w)],
          [w |-> item.d, d |-> item.w])

\* Give the item a new size: its corner stays.
SizeItem(s) ==
  /\ room # None
  /\ Fit(at, s)

\* Remove a room: the item in it goes too.
DeleteRoom(r) ==
  /\ r \in there
  /\ there' = there \ {r}
  /\ UNCHANGED plan
  /\ IF room = r
       THEN room' = None /\ at' = [x |-> 0, y |-> 0]
       ELSE UNCHANGED <<room, at>>
  /\ UNCHANGED item

\* Add the room again: it goes to a free place, if there is one.
AddRoom(r) ==
  /\ r \notin there
  /\ \E p \in Rect : InGrid(p) /\ Free(r, p) /\ plan' = [plan EXCEPT ![r] = p]
  /\ there' = there \cup {r}
  /\ UNCHANGED <<room, at, item>>

Next ==
  \/ \E r \in Rooms :
       \/ \E x, y \in Cells : MoveRoom(r, x, y)
       \/ \E p \in Rect : SizeRoom(r, p)
       \/ \E x, y \in -1..Size : PlaceItem(r, x, y)
       \/ DeleteRoom(r)
       \/ AddRoom(r)
  \/ TurnItem
  \/ \E s \in [w : Sides, d : Sides] : SizeItem(s)

Spec == Init /\ [][Next]_vars
=============================================================================
