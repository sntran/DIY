------------------------------- MODULE Device -------------------------------
(***************************************************************************)
(* The build on the device (docs/design.md, "The build on the device").    *)
(*                                                                         *)
(* The tabs of one browser share one storage (localStorage). Each tab has  *)
(* a LiveView, which holds a build, and a hook, which writes the build to  *)
(* the storage. After each edit, the LiveView sends a save to its hook,    *)
(* with the key of the stored build that the edit comes from (the base).   *)
(* The hook writes only if the stored key is the base (compare and set,    *)
(* in a Web Lock). Else it sends the stored build back (a conflict), and   *)
(* the LiveView shows that build. When a tab writes, the browser tells the *)
(* other tabs later (the "storage" event), and a tab shows a newer build.  *)
(*                                                                         *)
(* A conflict and a "storage" event come by different paths, so a tab can *)
(* get them in either order. Each LiveView keeps the newest stored build   *)
(* that it knows (latest). After a conflict, it shows that build, not the  *)
(* build of the conflict, which can be older.                              *)
(*                                                                         *)
(* When a LiveView takes a build from outside, the saves that it sent      *)
(* before come from a build that it does not show now. Their conflicts are *)
(* old news. The LiveView counts the builds that it takes (epoch), each    *)
(* save has the epoch, and a conflict of an old epoch changes no view.     *)
(*                                                                         *)
(* The LiveView sends the next save before the hook answers the last one.  *)
(* So the key must name one build: the stamp of the build, which each      *)
(* change makes new. With the revision as the key (ByStamp = FALSE), two   *)
(* saves of one tab can lose an edit of a different tab.                   *)
(*                                                                         *)
(* An edit here is a number. A build is the set of its edits, with a       *)
(* revision and a stamp. The stamp of a build is the number of the edit    *)
(* that made it: it is unique.                                             *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
  Tabs,      \* the open tabs of the browser
  MaxEdits,  \* the number of edits in a behavior
  ByStamp,   \* TRUE: the key of a build is its stamp. FALSE: its revision.
  ByEpoch    \* TRUE: a conflict of an old epoch changes no view. FALSE: each one does.

VARIABLES
  storage,   \* the stored build
  view,      \* view[t]: the build in the LiveView of tab t
  base,      \* base[t]: the key of the stored build that the next save of t comes from
  latest,    \* latest[t]: the newest stored build that the LiveView of t knows
  epoch,     \* epoch[t]: the number of builds that the LiveView of t took from outside
  toHook,    \* toHook[t]: the saves from the LiveView of t to its hook, in order
  toView,    \* toView[t]: the conflicts from the hook of t to its LiveView, in order
  events,    \* events[t]: the "storage" events that the browser has not given to t yet
  nextEdit,  \* the number of the next edit
  stored     \* each edit that was in the storage at some time (a history)

vars == <<storage, view, base, latest, epoch, toHook, toView, events, nextEdit, stored>>

Empty == [rev |-> 0, stamp |-> 0, edits |-> {}]
Key(b) == IF ByStamp THEN b.stamp ELSE b.rev

\* Each write of the storage adds 1 to the stored revision, so of two stored
\* builds, the newer one has the larger revision.
Newer(a, b) == IF b.rev > a.rev THEN b ELSE a

Init ==
  /\ storage = Empty
  /\ view = [t \in Tabs |-> Empty]
  /\ base = [t \in Tabs |-> Key(Empty)]
  /\ latest = [t \in Tabs |-> Empty]
  /\ epoch = [t \in Tabs |-> 0]
  /\ toHook = [t \in Tabs |-> <<>>]
  /\ toView = [t \in Tabs |-> <<>>]
  /\ events = [t \in Tabs |-> <<>>]
  /\ nextEdit = 1
  /\ stored = {}

\* A person changes the build in tab t. The LiveView sends the save at once,
\* and takes the new build as the base of the next save.
Edit(t) ==
  /\ nextEdit <= MaxEdits
  /\ LET b == [rev |-> view[t].rev + 1, stamp |-> nextEdit,
               edits |-> view[t].edits \cup {nextEdit}]
     IN /\ view' = [view EXCEPT ![t] = b]
        /\ toHook' = [toHook EXCEPT ![t] =
                        Append(@, [build |-> b, base |-> base[t], epoch |-> epoch[t]])]
        /\ base' = [base EXCEPT ![t] = Key(b)]
  /\ nextEdit' = nextEdit + 1
  /\ UNCHANGED <<storage, latest, epoch, toView, events, stored>>

\* The hook of t takes the next save, in the lock of the storage.
Store(t) ==
  /\ toHook[t] /= <<>>
  /\ LET m == Head(toHook[t]) IN
       IF Key(storage) = m.base
       THEN /\ storage' = m.build
            /\ stored' = stored \cup m.build.edits
            /\ events' = [u \in Tabs |->
                            IF u = t THEN events[u] ELSE Append(events[u], m.build)]
            /\ UNCHANGED toView
       ELSE /\ toView' = [toView EXCEPT ![t] =
                             Append(@, [build |-> storage, epoch |-> m.epoch])]
            /\ UNCHANGED <<storage, stored, events>>
  /\ toHook' = [toHook EXCEPT ![t] = Tail(@)]
  /\ UNCHANGED <<view, base, latest, epoch, nextEdit>>

\* The LiveView of t gets a conflict. For a save of its epoch, it shows the
\* newest stored build that it knows. A conflict of an old epoch only tells
\* about the storage.
Conflict(t) ==
  /\ toView[t] /= <<>>
  /\ LET m == Head(toView[t])
         b == Newer(latest[t], m.build)
     IN /\ latest' = [latest EXCEPT ![t] = b]
        /\ IF m.epoch = epoch[t] \/ ~ByEpoch
           THEN /\ view' = [view EXCEPT ![t] = b]
                /\ base' = [base EXCEPT ![t] = Key(b)]
                /\ epoch' = [epoch EXCEPT ![t] = @ + 1]
           ELSE UNCHANGED <<view, base, epoch>>
  /\ toView' = [toView EXCEPT ![t] = Tail(@)]
  /\ UNCHANGED <<storage, toHook, events, nextEdit, stored>>

\* The browser gives a "storage" event to t, at any time after the write.
\* The LiveView shows the written build if it is newer.
Changed(t) ==
  /\ events[t] /= <<>>
  /\ LET b == Head(events[t]) IN
       /\ latest' = [latest EXCEPT ![t] = Newer(@, b)]
       /\ IF b.rev > view[t].rev
          THEN /\ view' = [view EXCEPT ![t] = b]
               /\ base' = [base EXCEPT ![t] = Key(b)]
               /\ epoch' = [epoch EXCEPT ![t] = @ + 1]
          ELSE UNCHANGED <<view, base, epoch>>
  /\ events' = [events EXCEPT ![t] = Tail(@)]
  /\ UNCHANGED <<storage, toHook, toView, nextEdit, stored>>

\* A person loads the page of t again. The old LiveView and hook stop, with
\* their messages. The new hook reads the storage.
Reload(t) ==
  /\ view' = [view EXCEPT ![t] = storage]
  /\ base' = [base EXCEPT ![t] = Key(storage)]
  /\ latest' = [latest EXCEPT ![t] = storage]
  /\ epoch' = [epoch EXCEPT ![t] = 0]
  /\ toHook' = [toHook EXCEPT ![t] = <<>>]
  /\ toView' = [toView EXCEPT ![t] = <<>>]
  /\ events' = [events EXCEPT ![t] = <<>>]
  /\ UNCHANGED <<storage, nextEdit, stored>>

Next == \E t \in Tabs : Edit(t) \/ Store(t) \/ Conflict(t) \/ Changed(t) \/ Reload(t)

Spec == Init /\ [][Next]_vars
  /\ \A t \in Tabs : WF_vars(Store(t)) /\ WF_vars(Conflict(t)) /\ WF_vars(Changed(t))

TypeOK ==
  /\ nextEdit \in 1..(MaxEdits + 1)
  /\ storage.edits \subseteq 1..MaxEdits
  /\ \A t \in Tabs : view[t].edits \subseteq 1..MaxEdits

\* An edit that was in the storage stays in the storage.
NoLostUpdate == stored \subseteq storage.edits

\* The storage holds a build that a tab made: its stamp is its last edit.
StampNamesBuild == storage.stamp = 0 \/ storage.stamp \in storage.edits

\* The next save of a tab comes from the build that the tab shows.
BaseIsView == \A t \in Tabs : base[t] = Key(view[t])

\* A tab knows no stored build that is newer than the storage.
LatestIsStored == \A t \in Tabs : latest[t].rev <= storage.rev

\* When the edits stop and the messages arrive, each tab shows the stored
\* build (a tab can reload at any time, so this needs no reload).
Converge == <>[](\A t \in Tabs : view[t] = storage)
=============================================================================
