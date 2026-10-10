----------------------------- MODULE RoomSync ------------------------------
(***************************************************************************)
(* The match of the rooms with Home Assistant. The hook adds an area in    *)
(* Home Assistant for each room that the person chose (addAreas in         *)
(* assets/js/home_assistant.js).                                           *)
(*                                                                         *)
(* Two tabs can do the match at the same time, and a person can add an     *)
(* area in Home Assistant. Each tab reads the areas when its sheet opens   *)
(* (a snapshot). Home Assistant refuses a second area with the same name   *)
(* ("invalid_info"). The names of two rooms can be the same.               *)
(*                                                                         *)
(* The rules:                                                              *)
(* - The hook: Home Assistant refuses the name. Then the tab reads the     *)
(*   areas again. It links the room to the area of that name. The hook     *)
(*   adds the floors with the same rule (and the same level).              *)
(* - The server: the person can choose a room only when no area and no     *)
(*   room before it has its name (DIY.HomeAssistant.blocked). An area has  *)
(*   one room at most (DIY.Build.link_area).                               *)
(*                                                                         *)
(* Three modes have a fault:                                               *)
(* - "suffix": the tab adds the area with a new name ("Den 2"). Home       *)
(*   Assistant then has two areas for one room (RoomSync.suffix.cfg).      *)
(* - "snapshot": the tab looks for the area in its snapshot. The area of a *)
(*   different tab is not there, so the room gets no area                  *)
(*   (RoomSync.snapshot.cfg).                                              *)
(* - "twins": the server has no rules for the names. Two rooms with one    *)
(*   name then get one area (RoomSync.twins.cfg).                          *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

\* None is a model value: no room, or no area.
CONSTANTS Tabs, Names, Twins, MaxCopy, MaxPerson, Mode, None

\* A room has a name and a number. Two rooms with the same name are twins,
\* for example "Den" and "den". Home Assistant compares names with no case.
Rooms == Names \X (1..Twins)
NameOf(r) == r[1]

\* An area has a name and a copy number. Copy 0 has the name itself. A
\* higher copy has a new name, for example "Den 2".
Areas == [name : Names, copy : 0..MaxCopy]
Area(n) == [name |-> n, copy |-> 0]

VARIABLES areas,   \* the areas in Home Assistant
          link,    \* the area of each room in the build, or None
          snap,    \* the areas that each tab read when its sheet opened
          todo,    \* the rooms that each tab must still add
          cur,     \* the room of a refused name: the tab reads the areas again
          pc,      \* the step of each tab: "idle", "work" or "done"
          failed,  \* the rooms that a tab told as not added
          person   \* the count of the areas that the person added

vars == <<areas, link, snap, todo, cur, pc, failed, person>>

TypeOK ==
  /\ areas \subseteq Areas
  /\ link \in [Rooms -> Areas \cup {None}]
  /\ snap \in [Tabs -> SUBSET Areas]
  /\ todo \in [Tabs -> SUBSET Rooms]
  /\ cur \in [Tabs -> Rooms \cup {None}]
  /\ pc \in [Tabs -> {"idle", "work", "done"}]
  /\ failed \subseteq Rooms
  /\ person \in 0..MaxPerson

Init ==
  /\ areas = {}
  /\ link = [r \in Rooms |-> None]
  /\ snap = [t \in Tabs |-> {}]
  /\ todo = [t \in Tabs |-> {}]
  /\ cur = [t \in Tabs |-> None]
  /\ pc = [t \in Tabs |-> "idle"]
  /\ failed = {}
  /\ person = 0

\* The rooms with no link to an area of a list, and no area of their name.
Free(list) == {r \in Rooms : link[r] \notin list /\ Area(NameOf(r)) \notin list}

\* The rooms that the person can choose for a list of areas: the first room
\* of each name in Free (DIY.HomeAssistant.blocked). In the mode "twins",
\* each room with no link to an area of the list.
Offered(list) ==
  IF Mode = "twins"
    THEN {r \in Rooms : link[r] \notin list}
    ELSE {r \in Free(list) : \A s \in Free(list) : NameOf(s) = NameOf(r) => r[2] <= s[2]}

\* The server links a room to an area (DIYWeb.HomeAssistant.areas_added).
\* It refuses an area of a different room: the room gets no area. The mode
\* "twins" has no such check.
Link(r, a) ==
  IF Mode # "twins" /\ \E s \in Rooms \ {r} : link[s] = a
    THEN /\ failed' = failed \cup {r}
         /\ UNCHANGED link
    ELSE /\ link' = [link EXCEPT ![r] = a]
         /\ UNCHANGED failed

\* The sheet of a tab opens: the tab reads the areas, and the person
\* chooses some of the rooms.
Open(t) ==
  /\ pc[t] = "idle"
  /\ \E chosen \in SUBSET Offered(areas) :
       /\ snap' = [snap EXCEPT ![t] = areas]
       /\ todo' = [todo EXCEPT ![t] = chosen]
  /\ pc' = [pc EXCEPT ![t] = "work"]
  /\ UNCHANGED <<areas, link, cur, failed, person>>

\* The tab asks Home Assistant to add the area of a room. Home Assistant
\* adds it, or refuses the name.
Create(t) ==
  /\ pc[t] = "work"
  /\ cur[t] = None
  /\ \E r \in todo[t] :
       /\ todo' = [todo EXCEPT ![t] = @ \ {r}]
       /\ IF Area(NameOf(r)) \notin areas
            THEN /\ areas' = areas \cup {Area(NameOf(r))}
                 /\ Link(r, Area(NameOf(r)))
                 /\ UNCHANGED cur
            ELSE CASE Mode \in {"ok", "twins"} ->
                        /\ cur' = [cur EXCEPT ![t] = r]
                        /\ UNCHANGED <<areas, link, failed>>
                   [] Mode = "snapshot" ->
                        /\ IF Area(NameOf(r)) \in snap[t]
                             THEN Link(r, Area(NameOf(r)))
                             ELSE /\ failed' = failed \cup {r}
                                  /\ UNCHANGED link
                        /\ UNCHANGED <<areas, cur>>
                   [] Mode = "suffix" ->
                        \E k \in 1..MaxCopy :
                          /\ [name |-> NameOf(r), copy |-> k] \notin areas
                          /\ areas' = areas \cup {[name |-> NameOf(r), copy |-> k]}
                          /\ Link(r, [name |-> NameOf(r), copy |-> k])
                          /\ UNCHANGED cur
  /\ UNCHANGED <<snap, pc, person>>

\* Home Assistant refused the name: the tab reads the areas again, and
\* links the room to the area of that name.
Relist(t) ==
  /\ cur[t] # None
  /\ IF Area(NameOf(cur[t])) \in areas
       THEN Link(cur[t], Area(NameOf(cur[t])))
       ELSE /\ failed' = failed \cup {cur[t]}
            /\ UNCHANGED link
  /\ cur' = [cur EXCEPT ![t] = None]
  /\ UNCHANGED <<areas, snap, todo, pc, person>>

\* The tab added all its rooms: it tells the LiveView (ha:areas_added).
Finish(t) ==
  /\ pc[t] = "work"
  /\ todo[t] = {}
  /\ cur[t] = None
  /\ pc' = [pc EXCEPT ![t] = "done"]
  /\ UNCHANGED <<areas, link, snap, todo, cur, failed, person>>

\* A person adds an area in Home Assistant.
Person(n) ==
  /\ person < MaxPerson
  /\ Area(n) \notin areas
  /\ areas' = areas \cup {Area(n)}
  /\ person' = person + 1
  /\ UNCHANGED <<link, snap, todo, cur, pc, failed>>

Step(t) == Create(t) \/ Relist(t) \/ Finish(t)

Next ==
  \/ \E t \in Tabs : Open(t) \/ Step(t)
  \/ \E n \in Names : Person(n)

Spec == Init /\ [][Next]_vars /\ \A t \in Tabs : WF_vars(Step(t))

\* Home Assistant has one area for each name: no copies.
OneAreaEach == \A a, b \in areas : a.name = b.name => a = b

\* Each room that the person chose gets an area.
NoneFailed == failed = {}

\* An area has one room at most.
OneRoomEach == \A r, s \in Rooms : link[r] = link[s] /\ link[r] # None => r = s

\* The area of a room has the name of the room.
SameName == \A r \in Rooms : link[r] # None => link[r] = Area(NameOf(r))

\* Each tab that starts the match ends it.
Ends == \A t \in Tabs : pc[t] = "work" ~> pc[t] = "done"
=============================================================================
