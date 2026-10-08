------------------------------- MODULE Share -------------------------------
(***************************************************************************)
(* A power station that goes from the house to a camper van and back (see *)
(* DIY.Build.take_to_van/3, bring_home/2, delete_item/2 and               *)
(* delete_room/2). The station is in one place at a time: a room of the    *)
(* house, or the electrical bay of a van. In the van, it keeps its room of *)
(* the house as its home. Each van is in a room of the house.             *)
(*                                                                         *)
(* The person can take the station, bring it home, and remove a room or a  *)
(* van at any time, in any order. The removal of a van sends the station   *)
(* home. The removal of a room removes the station in it and the vans in   *)
(* it, and gives a new home to a station that is away (Mode = "rehome").   *)
(* In the model, the station can go in each room; the code chooses the     *)
(* first room where its kind can go.                                       *)
(*                                                                         *)
(* Two modes have a fault:                                                 *)
(* - "clear": the removal of the home clears the home. A later removal of  *)
(*   the van then removes the station (Share.clear.cfg).                   *)
(* - "keep": the removal of the home keeps the home. The station then has  *)
(*   a home that is not there (Share.keep.cfg).                            *)
(***************************************************************************)

CONSTANTS Rooms, Vans, Mode

VARIABLES rooms,  \* the rooms of the house that are there
          vans,   \* the vans that are there
          at,     \* the room of each van
          place,  \* where the station is: <<"room", r>>, <<"bay", v>>, or Gone
          home,   \* the home of the station in a van: a room, or "none"
          why     \* why the station went: "here" (it did not), "room" (with
                  \* its room), "full" (no room was left), "lost"

vars == <<rooms, vans, at, place, home, why>>

Bays == {<<"bay", v>> : v \in Vans}
InRooms == {<<"room", r>> : r \in Rooms}
Gone == <<"gone", "gone">>
Room(r) == <<"room", r>>

TypeOK ==
  /\ rooms \subseteq Rooms
  /\ vans \subseteq Vans
  /\ at \in [Vans -> Rooms]
  /\ place \in InRooms \cup Bays \cup {Gone}
  /\ home \in Rooms \cup {"none"}
  /\ why \in {"here", "room", "full", "lost"}

Away == place \in Bays

\* The station is never in a room or a van that is not there, and each van
\* is in a room that is there.
InPlace ==
  /\ \/ place = Gone
     \/ \E r \in rooms : place = Room(r)
     \/ \E v \in vans : place = <<"bay", v>>
  /\ \A v \in vans : at[v] \in rooms

\* Only a station in a van has a home, and its home is there.
HomeThere == home # "none" => (Away /\ home \in rooms)

\* The station goes only with its own room, or when no room is left for it.
Kept == place = Gone => why \in {"room", "full"}

Init ==
  /\ rooms = Rooms
  /\ vans = Vans
  /\ at \in [Vans -> Rooms]
  /\ place \in InRooms
  /\ home = "none"
  /\ why = "here"

\* Take the station to the bay of a van: it keeps its room as its home.
Take(v) ==
  /\ \E r \in rooms : place = Room(r)
  /\ v \in vans
  /\ place' = <<"bay", v>>
  /\ home' = place[2]
  /\ UNCHANGED <<rooms, vans, at, why>>

\* Bring it home. A station with no home stays in the van.
Bring ==
  /\ Away
  /\ home \in rooms
  /\ place' = Room(home)
  /\ home' = "none"
  /\ UNCHANGED <<rooms, vans, at, why>>

\* The station leaves a van that goes: to its home, else it goes too.
Leave(left) ==
  IF home \in left
    THEN place' = Room(home) /\ home' = "none" /\ why' = why
    ELSE place' = Gone /\ home' = "none" /\ why' = IF left = {} THEN "full" ELSE "lost"

\* Remove a van: the station in it goes home.
RemoveVan(v) ==
  /\ v \in vans
  /\ vans' = vans \ {v}
  /\ IF place = <<"bay", v>>
       THEN Leave(rooms)
       ELSE UNCHANGED <<place, home, why>>
  /\ UNCHANGED <<rooms, at>>

\* The home of the station after the removal of a room.
NewHome(r, left) ==
  IF home # r THEN home
  ELSE CASE Mode = "rehome" -> IF left = {} THEN "none" ELSE CHOOSE x \in left : TRUE
         [] Mode = "clear" -> "none"
         [] Mode = "keep" -> home

\* Remove a room: the station in it goes with it, and the vans in it go. A
\* station away gets a new home when its home goes.
RemoveRoom(r) ==
  /\ r \in rooms
  /\ LET left == rooms \ {r}
         gone == {v \in vans : at[v] = r}
     IN /\ rooms' = left
        /\ vans' = vans \ gone
        /\ IF place = Room(r)
             THEN place' = Gone /\ home' = "none" /\ why' = "room"
             ELSE IF place \in {<<"bay", v>> : v \in gone}
               THEN IF NewHome(r, left) \in left
                      THEN place' = Room(NewHome(r, left)) /\ home' = "none" /\ why' = why
                      ELSE place' = Gone /\ home' = "none"
                             /\ why' = IF left = {} THEN "full" ELSE "lost"
               ELSE place' = place /\ home' = NewHome(r, left) /\ why' = why
  /\ UNCHANGED at

Next ==
  \/ \E v \in Vans : Take(v)
  \/ Bring
  \/ \E v \in Vans : RemoveVan(v)
  \/ \E r \in Rooms : RemoveRoom(r)

Spec == Init /\ [][Next]_vars
=============================================================================
