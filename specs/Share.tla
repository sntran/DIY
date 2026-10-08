------------------------------- MODULE Share -------------------------------
(***************************************************************************)
(* A power station that goes from the house to a camper van and back (see *)
(* DIY.Build.take_to_van/3, bring_home/2, delete_item/2 and               *)
(* delete_room/2). The station is in one place at a time: a room of the    *)
(* house, or the electrical bay of a van. In the van, it keeps its room of *)
(* the house as its home.                                                  *)
(*                                                                         *)
(* The person can take the station, bring it home, and remove a room or a  *)
(* van at any time, in any order. The removal of a van sends the station   *)
(* home when its home is there; else the station goes with the van. The   *)
(* removal of a room removes the station in it, and clears the home of a  *)
(* station that is away.                                                   *)
(*                                                                         *)
(* With ClearHomes = FALSE (a fault), the removal of a room does not clear *)
(* the home: the station can have a home that is not there                *)
(* (Share.home.cfg).                                                       *)
(***************************************************************************)

CONSTANTS Rooms, Vans, ClearHomes

VARIABLES rooms,  \* the rooms of the house that are there
          vans,   \* the vans that are there
          place,  \* where the station is: <<"room", r>>, <<"bay", v>>, or Gone
          home    \* the home of the station in a van: a room, or "none"

vars == <<rooms, vans, place, home>>

Bays == {<<"bay", v>> : v \in Vans}
InRooms == {<<"room", r>> : r \in Rooms}
Gone == <<"gone", "gone">>
Room(r) == <<"room", r>>

TypeOK ==
  /\ rooms \subseteq Rooms
  /\ vans \subseteq Vans
  /\ place \in InRooms \cup Bays \cup {Gone}
  /\ home \in Rooms \cup {"none"}

Away == place \in Bays

\* The station is never in a room or a van that is not there.
InPlace ==
  \/ place = Gone
  \/ \E r \in rooms : place = Room(r)
  \/ \E v \in vans : place = <<"bay", v>>

\* Only a station in a van has a home, and its home is there.
HomeThere == home # "none" => (Away /\ home \in rooms)

Init ==
  /\ rooms = Rooms
  /\ vans = Vans
  /\ place \in InRooms
  /\ home = "none"

\* Take the station to the bay of a van: it keeps its room as its home.
Take(v) ==
  /\ \E r \in rooms : place = Room(r)
  /\ v \in vans
  /\ place' = <<"bay", v>>
  /\ home' = place[2]
  /\ UNCHANGED <<rooms, vans>>

\* Bring it home: to its home, else to an other room of the house.
Bring ==
  /\ Away
  /\ rooms # {}
  /\ place' = IF home \in rooms THEN Room(home) ELSE Room(CHOOSE r \in rooms : TRUE)
  /\ home' = "none"
  /\ UNCHANGED <<rooms, vans>>

\* Remove a van: the station in it goes home, else it goes with the van.
RemoveVan(v) ==
  /\ v \in vans
  /\ vans' = vans \ {v}
  /\ IF place = <<"bay", v>>
       THEN IF home \in rooms
              THEN place' = Room(home) /\ home' = "none"
              ELSE place' = Gone /\ home' = "none"
       ELSE UNCHANGED <<place, home>>
  /\ UNCHANGED rooms

\* Remove a room: the station in it goes with it, and a station away loses
\* its home (when the app clears it).
RemoveRoom(r) ==
  /\ r \in rooms
  /\ rooms' = rooms \ {r}
  /\ place' = IF place = Room(r) THEN Gone ELSE place
  /\ home' = IF home = r /\ ClearHomes THEN "none" ELSE home
  /\ UNCHANGED vans

Next ==
  \/ \E v \in Vans : Take(v)
  \/ Bring
  \/ \E v \in Vans : RemoveVan(v)
  \/ \E r \in Rooms : RemoveRoom(r)

Spec == Init /\ [][Next]_vars
=============================================================================
