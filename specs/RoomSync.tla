----------------------------- MODULE RoomSync ------------------------------
(***************************************************************************)
(* The match of the rooms with Home Assistant. The hook adds an area in    *)
(* Home Assistant for each room that the person chose (addAreas in         *)
(* assets/js/home_assistant.js).                                           *)
(*                                                                         *)
(* Two tabs can do the match at the same time, and a person can add an     *)
(* area in Home Assistant. Each tab reads the areas when its sheet opens   *)
(* (a snapshot). The person chooses the rooms with no area of the same     *)
(* name in the snapshot. Home Assistant refuses a second area with the     *)
(* same name ("invalid_info"). The names of two rooms can be the same.     *)
(*                                                                         *)
(* The rule of the hook: Home Assistant refuses the name. Then the tab     *)
(* reads the areas again. It links the room to the area of that name. The  *)
(* hook adds the floors with the same rule.                                *)
(*                                                                         *)
(* Two modes have a fault:                                                 *)
(* - "suffix": the tab adds the area with a new name ("Den 2"). Home       *)
(*   Assistant then has two areas for one room (RoomSync.suffix.cfg).      *)
(* - "snapshot": the tab looks for the area in its snapshot. The area of a *)
(*   different tab is not there, so the room gets no area                  *)
(*   (RoomSync.snapshot.cfg).                                              *)
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

\* The rooms only in the app for a list of areas (DIY.HomeAssistant.match).
\* A room has no link to an area of the list, and no area of its name.
OnlyApp(list) == {r \in Rooms : link[r] \notin list /\ Area(NameOf(r)) \notin list}

\* The sheet of a tab opens: the tab reads the areas, and the person
\* chooses some of the rooms only in the app.
Open(t) ==
  /\ pc[t] = "idle"
  /\ \E chosen \in SUBSET OnlyApp(areas) :
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
                 /\ link' = [link EXCEPT ![r] = Area(NameOf(r))]
                 /\ UNCHANGED <<cur, failed>>
            ELSE CASE Mode = "ok" ->
                        /\ cur' = [cur EXCEPT ![t] = r]
                        /\ UNCHANGED <<areas, link, failed>>
                   [] Mode = "snapshot" ->
                        /\ IF Area(NameOf(r)) \in snap[t]
                             THEN /\ link' = [link EXCEPT ![r] = Area(NameOf(r))]
                                  /\ UNCHANGED failed
                             ELSE /\ failed' = failed \cup {r}
                                  /\ UNCHANGED link
                        /\ UNCHANGED <<areas, cur>>
                   [] Mode = "suffix" ->
                        \E k \in 1..MaxCopy :
                          /\ [name |-> NameOf(r), copy |-> k] \notin areas
                          /\ areas' = areas \cup {[name |-> NameOf(r), copy |-> k]}
                          /\ link' = [link EXCEPT ![r] = [name |-> NameOf(r), copy |-> k]]
                          /\ UNCHANGED <<cur, failed>>
  /\ UNCHANGED <<snap, pc, person>>

\* Home Assistant refused the name: the tab reads the areas again, and
\* links the room to the area of that name.
Relist(t) ==
  /\ cur[t] # None
  /\ IF Area(NameOf(cur[t])) \in areas
       THEN /\ link' = [link EXCEPT ![cur[t]] = Area(NameOf(cur[t]))]
            /\ UNCHANGED failed
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

\* The area of a room has the name of the room.
SameName == \A r \in Rooms : link[r] # None => link[r] = Area(NameOf(r))

\* Each tab that starts the match ends it.
Ends == \A t \in Tabs : pc[t] = "work" ~> pc[t] = "done"
=============================================================================
