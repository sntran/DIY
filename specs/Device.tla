------------------------------- MODULE Device -------------------------------
(***************************************************************************)
(* The build on the device (docs/design.md, "The build on the device").    *)
(*                                                                         *)
(* The tabs of one browser share one store (IndexedDB). Each tab has a     *)
(* LiveView, which holds a build, and a hook, which writes the build to    *)
(* the store. After each edit, the LiveView sends a save to its hook, with *)
(* the key of the stored build that the edit comes from (the base), and    *)
(* does not wait for the answer. The hook takes the saves in order. For    *)
(* each one, it reads and writes in one transaction of the store (compare  *)
(* and set): it writes only if the stored key is the base. Else it sends   *)
(* the stored build back (a conflict), and the LiveView shows that build.  *)
(* After a write, the hook tells the other tabs (a BroadcastChannel).      *)
(*                                                                         *)
(* The hook sends all that it sees of the store on one channel, in the     *)
(* order that it sees it: a conflict, a write of a different tab, the      *)
(* store at a restore. So toView is one queue for each tab.                *)
(*                                                                         *)
(* The key must name one build: the stamp of the build, which each edit    *)
(* makes new. With the revision as the key (ByStamp = FALSE), two saves of *)
(* one tab can lose an edit of a different tab.                            *)
(*                                                                         *)
(* When a LiveView takes a build from outside, the saves that it sent      *)
(* before come from a build that it does not show now. Their answers are   *)
(* old news. Each LiveView has an epoch, which it changes when it takes a  *)
(* build from outside, and a new LiveView has a new epoch. A conflict or   *)
(* an error of an old epoch changes nothing (ByEpoch = FALSE: each one     *)
(* does, and a tab can show an old build in the end).                      *)
(*                                                                         *)
(* Other events:                                                           *)
(* - Reconnect: the LiveView stops and a new one starts (the network, a    *)
(*   new deploy). The hook stays, with its queue. It reads the store after *)
(*   the saves of its queue, and sends it (a restore). A new read removes  *)
(*   the reads before it from the queue: an old read can come before saves *)
(*   of the queue, and then its restore is old. A LiveView takes only the  *)
(*   first restore.                                                        *)
(* - Reload: the page loads again. The hook and its queue go away.         *)
(* - Fail: a write fails (the device has no space). The LiveView keeps its *)
(*   build, and takes the stored key as the base: the next edit saves all  *)
(*   the build again.                                                      *)
(* - Clear: the user removes the data of the site. A conflict with an      *)
(*   empty store does not empty the build: the LiveView saves its build    *)
(*   again on the empty store.                                             *)
(*                                                                         *)
(* An edit here is a number. A build is the set of its edits, with a       *)
(* revision and a stamp. The stamp of a build is the number of the edit    *)
(* that made it: it is unique.                                             *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
  Tabs,         \* the open tabs of the browser
  MaxEdits,     \* the number of edits in a behavior
  MaxRestarts,  \* the number of reconnects and reloads in a behavior
  MaxFails,     \* the number of failed writes in a behavior
  MaxClears,    \* the number of clears of the store in a behavior
  ByStamp,      \* TRUE: the key of a build is its stamp. FALSE: its revision.
  ByEpoch,      \* TRUE: an answer of an old epoch changes nothing.
  ByReads       \* TRUE: a new read removes the old reads of the queue.

VARIABLES
  store,      \* the stored build
  view,       \* view[t]: the build in the LiveView of tab t
  base,       \* base[t]: the key of the stored build that the next save of t comes from
  epoch,      \* epoch[t]: the epoch of the LiveView of t
  restoring,  \* restoring[t]: the LiveView of t waits for the restore
  toHook,     \* toHook[t]: the saves and the reads of the hook of t, in order
  toView,     \* toView[t]: what the hook of t saw of the store, in order
  next,       \* the number of the next edit
  fresh,      \* the number of the next epoch
  counts,     \* the restarts, fails and clears so far
  stored      \* each edit that was in the store after the last clear (a history)

vars == <<store, view, base, epoch, restoring, toHook, toView, next, fresh, counts, stored>>

Empty == [rev |-> 0, stamp |-> 0, edits |-> {}]
Key(b) == IF ByStamp THEN b.stamp ELSE b.rev
Read == [kind |-> "read"]

Init ==
  /\ store = Empty
  /\ view = [t \in Tabs |-> Empty]
  /\ base = [t \in Tabs |-> Key(Empty)]
  /\ epoch = [t \in Tabs |-> 0]
  /\ restoring = [t \in Tabs |-> TRUE]
  /\ toHook = [t \in Tabs |-> <<Read>>]
  /\ toView = [t \in Tabs |-> <<>>]
  /\ next = 1
  /\ fresh = 1
  /\ counts = [restarts |-> 0, fails |-> 0, clears |-> 0]
  /\ stored = {}

Save(t, b, e) == [kind |-> "save", build |-> b, base |-> base[t], epoch |-> e]

\* A person changes the build in tab t. The LiveView sends the save at once,
\* and takes the new build as the base of the next save.
Edit(t) ==
  /\ ~restoring[t]
  /\ next <= MaxEdits
  /\ LET b == [rev |-> view[t].rev + 1, stamp |-> next, edits |-> view[t].edits \cup {next}]
     IN /\ view' = [view EXCEPT ![t] = b]
        /\ toHook' = [toHook EXCEPT ![t] = Append(@, Save(t, b, epoch[t]))]
        /\ base' = [base EXCEPT ![t] = Key(b)]
  /\ next' = next + 1
  /\ UNCHANGED <<store, epoch, restoring, toView, fresh, counts, stored>>

Tell(t, m) == Append(toView[t], m)

\* The hook of t takes the next save or read, in one transaction.
Hook(t) ==
  /\ toHook[t] /= <<>>
  /\ LET m == Head(toHook[t]) IN
       CASE m.kind = "read" ->
              /\ toView' = [toView EXCEPT ![t] = Tell(t, [kind |-> "restore", build |-> store])]
              /\ UNCHANGED <<store, stored>>
         [] Key(store) = m.base ->
              /\ store' = m.build
              /\ stored' = stored \cup m.build.edits
              /\ toView' = [u \in Tabs |->
                   IF u = t THEN toView[u]
                   ELSE Append(toView[u], [kind |-> "changed", build |-> m.build])]
         [] OTHER ->
              /\ toView' = [toView EXCEPT ![t] =
                   Tell(t, [kind |-> "conflict", build |-> store, epoch |-> m.epoch])]
              /\ UNCHANGED <<store, stored>>
  /\ toHook' = [toHook EXCEPT ![t] = Tail(@)]
  /\ UNCHANGED <<view, base, epoch, restoring, next, fresh, counts>>

\* A write of the hook of t fails: the store does not change.
Fail(t) ==
  /\ counts.fails < MaxFails
  /\ toHook[t] /= <<>>
  /\ Head(toHook[t]).kind = "save"
  /\ Key(store) = Head(toHook[t]).base
  /\ toView' = [toView EXCEPT ![t] =
       Tell(t, [kind |-> "error", build |-> store, epoch |-> Head(toHook[t]).epoch])]
  /\ toHook' = [toHook EXCEPT ![t] = Tail(@)]
  /\ counts' = [counts EXCEPT !.fails = @ + 1]
  /\ UNCHANGED <<store, view, base, epoch, restoring, next, fresh, stored>>

Current(t, m) == m.epoch = epoch[t] \/ ~ByEpoch

\* Takes a build from outside: a new epoch.
Take(t, b) ==
  /\ view' = [view EXCEPT ![t] = b]
  /\ base' = [base EXCEPT ![t] = Key(b)]
  /\ epoch' = [epoch EXCEPT ![t] = fresh]
  /\ fresh' = fresh + 1

\* The LiveView of t takes the next message of its hook.
View(t) ==
  /\ toView[t] /= <<>>
  /\ LET m == Head(toView[t]) IN
       CASE m.kind = "restore" /\ restoring[t] ->
              /\ view' = [view EXCEPT ![t] = m.build]
              /\ base' = [base EXCEPT ![t] = Key(m.build)]
              /\ restoring' = [restoring EXCEPT ![t] = FALSE]
              /\ toView' = [toView EXCEPT ![t] = Tail(@)]
              /\ UNCHANGED <<epoch, fresh, toHook>>
         [] m.kind = "changed" ->
              \* While it waits for the restore, the LiveView takes no write
              \* of a different tab: the restore comes after it, with it.
              /\ IF ~restoring[t] /\ m.build.rev > view[t].rev
                 THEN Take(t, m.build)
                 ELSE UNCHANGED <<view, base, epoch, fresh>>
              /\ toView' = [toView EXCEPT ![t] = Tail(@)]
              /\ UNCHANGED <<restoring, toHook>>
         [] m.kind = "conflict" /\ Current(t, m) /\ m.build = Empty /\ ~restoring[t] ->
              \* The store is empty: save the build again on it.
              /\ base' = [base EXCEPT ![t] = Key(Empty)]
              /\ epoch' = [epoch EXCEPT ![t] = fresh]
              /\ fresh' = fresh + 1
              /\ toHook' = [toHook EXCEPT ![t] =
                   Append(@, [kind |-> "save", build |-> view[t], base |-> Key(Empty), epoch |-> fresh])]
              /\ toView' = [toView EXCEPT ![t] = Tail(@)]
              /\ UNCHANGED <<view, restoring>>
         [] m.kind = "conflict" /\ Current(t, m) ->
              /\ Take(t, m.build)
              /\ toView' = [toView EXCEPT ![t] = Tail(@)]
              /\ UNCHANGED <<restoring, toHook>>
         [] m.kind = "error" /\ Current(t, m) ->
              \* Keep the build. The next save comes from the stored build.
              /\ base' = [base EXCEPT ![t] = Key(m.build)]
              /\ epoch' = [epoch EXCEPT ![t] = fresh]
              /\ fresh' = fresh + 1
              /\ toView' = [toView EXCEPT ![t] = Tail(@)]
              /\ UNCHANGED <<view, restoring, toHook>>
         [] OTHER ->
              \* An answer of an old epoch, or a second restore.
              /\ toView' = [toView EXCEPT ![t] = Tail(@)]
              /\ UNCHANGED <<view, base, epoch, fresh, restoring, toHook>>
  /\ UNCHANGED <<store, next, counts, stored>>

\* A new LiveView for tab t, with a new epoch. keep: the hook stays, with
\* its queue (a reconnect), or goes away (a reload).
Restart(t, keep) ==
  /\ counts.restarts < MaxRestarts
  /\ view' = [view EXCEPT ![t] = Empty]
  /\ base' = [base EXCEPT ![t] = Key(Empty)]
  /\ epoch' = [epoch EXCEPT ![t] = fresh]
  /\ fresh' = fresh + 1
  /\ restoring' = [restoring EXCEPT ![t] = TRUE]
  /\ toHook' = [toHook EXCEPT ![t] =
       IF ~keep THEN <<Read>>
       ELSE IF ByReads THEN Append(SelectSeq(@, LAMBDA m : m.kind /= "read"), Read)
       ELSE Append(@, Read)]
  /\ toView' = [toView EXCEPT ![t] = <<>>]
  /\ counts' = [counts EXCEPT !.restarts = @ + 1]
  /\ UNCHANGED <<store, next, stored>>

\* The user removes the data of the site.
Clear ==
  /\ counts.clears < MaxClears
  /\ store' = Empty
  /\ stored' = {}
  /\ counts' = [counts EXCEPT !.clears = @ + 1]
  /\ UNCHANGED <<view, base, epoch, restoring, toHook, toView, next, fresh>>

Next ==
  \/ \E t \in Tabs :
       Edit(t) \/ Hook(t) \/ Fail(t) \/ View(t) \/ Restart(t, TRUE) \/ Restart(t, FALSE)
  \/ Clear

Spec == Init /\ [][Next]_vars /\ \A t \in Tabs : WF_vars(Hook(t)) /\ WF_vars(View(t))

TypeOK ==
  /\ store.edits \subseteq 1..MaxEdits
  /\ \A t \in Tabs : view[t].edits \subseteq 1..MaxEdits
  /\ \A t \in Tabs : restoring[t] \in BOOLEAN

\* An edit that was in the store stays in the store (until a clear).
NoLostUpdate == stored \subseteq store.edits

\* When the edits stop and the messages arrive, each tab shows the stored
\* build. Only with no fail and no clear: then a tab keeps its build until
\* its next edit.
Converge == <>[](\A t \in Tabs : view[t] = store)
=============================================================================
