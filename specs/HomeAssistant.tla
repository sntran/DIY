--------------------------- MODULE HomeAssistant ---------------------------
(***************************************************************************)
(* The sign-in to Home Assistant on the device (assets/js/home_assistant.js *)
(* and DIYWeb.HomeAssistant). The tokens of a sign-in (a session) are in   *)
(* IndexedDB, for all the tabs of the browser. Each tab has its own socket *)
(* to Home Assistant.                                                      *)
(*                                                                         *)
(* A tab asks Home Assistant for tokens in two cases: the exchange of the  *)
(* code after a sign-in, and the refresh of the access token. Each answer  *)
(* can come late: after a disconnect, or after a different tab changed    *)
(* the store. A disconnect clears the store, and revokes its session on    *)
(* Home Assistant. A new sign-in revokes the session that it replaces.     *)
(* The other tabs then read the store (Notice: the BroadcastChannel, or a  *)
(* reconnect). Home Assistant refuses a refresh of a revoked session.      *)
(*                                                                         *)
(* The rules of the hook:                                                  *)
(* - The epoch: a disconnect makes a new epoch of its tab. An exchange of  *)
(*   an old epoch keeps nothing, and the tab revokes its session.          *)
(* - The compare and set: a refresh writes its access token only when the *)
(*   store still has the session of the refresh.                          *)
(* - The owner: a refused refresh ends only the socket of its own session. *)
(*                                                                         *)
(* Three modes have a fault:                                                 *)
(* - "noepoch": the tab keeps each exchange. A disconnect while a sign-in *)
(*   finishes then gives a socket in a tab where the person disconnected   *)
(*   (HomeAssistant.noepoch.cfg).                                          *)
(* - "nocas": a refresh writes its session with no check. A refresh that  *)
(*   was in flight then puts back a session that a disconnect revoked     *)
(*   (HomeAssistant.nocas.cfg).                                            *)
(* - "noowner": a refused refresh ends the socket of the tab with no      *)
(*   check. A late refusal of an old session then closes the socket of    *)
(*   the new session (HomeAssistant.noowner.cfg).                          *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Tabs, Sessions, MaxAccess, MaxEpoch, Mode

None == "none"

VARIABLES store,    \* the session in IndexedDB and the count of its access
                    \* tokens: [s |-> a session or None, a |-> a number]
          revoked,  \* the sessions that a tab revoked
          epoch,    \* the epoch of each tab
          uses,     \* the session of the socket of each tab, or None
          off,      \* the tabs where the last step of the person was a
                    \* disconnect, with no session in the store after it
          answers,  \* the answers of Home Assistant in flight
          fresh,    \* the sessions that Home Assistant did not give yet
          lost      \* the tabs where a refusal closed the socket of a
                    \* session that is not revoked

vars == <<store, revoked, epoch, uses, off, answers, fresh, lost>>

Answers == [t : Tabs, kind : {"exchange", "refresh"}, s : Sessions, e : 0..MaxEpoch, ok : BOOLEAN]

TypeOK ==
  /\ store \in [s : Sessions \cup {None}, a : 0..MaxAccess]
  /\ revoked \subseteq Sessions
  /\ epoch \in [Tabs -> 0..MaxEpoch]
  /\ uses \in [Tabs -> Sessions \cup {None}]
  /\ off \subseteq Tabs
  /\ answers \subseteq Answers
  /\ fresh \subseteq Sessions
  /\ lost \subseteq Tabs

Init ==
  /\ store = [s |-> None, a |-> 0]
  /\ revoked = {}
  /\ epoch = [t \in Tabs |-> 0]
  /\ uses = [t \in Tabs |-> None]
  /\ off = {}
  /\ answers = {}
  /\ fresh = Sessions
  /\ lost = {}

\* The person signs in on a tab. Home Assistant gives a new session, and
\* the tab asks for its tokens (the exchange of the code).
SignIn(t) ==
  /\ \E s \in fresh :
       /\ fresh' = fresh \ {s}
       /\ answers' = answers \cup {[t |-> t, kind |-> "exchange", s |-> s, e |-> epoch[t], ok |-> TRUE]}
  /\ off' = off \ {t}
  /\ UNCHANGED <<store, revoked, epoch, uses, lost>>

\* The tokens of an exchange come. The tab keeps them only in the epoch of
\* the sign-in, and revokes the session that they replace. Else it revokes
\* the new session.
Exchanged(m) ==
  /\ m.kind = "exchange"
  /\ answers' = answers \ {m}
  /\ IF Mode = "noepoch" \/ m.e = epoch[m.t]
       THEN /\ store' = [s |-> m.s, a |-> 0]
            /\ uses' = [uses EXCEPT ![m.t] = m.s]
            /\ revoked' = IF store.s # None THEN revoked \cup {store.s} ELSE revoked
       ELSE /\ revoked' = revoked \cup {m.s}
            /\ UNCHANGED <<store, uses>>
  /\ UNCHANGED <<epoch, off, fresh, lost>>

\* A tab with a socket asks for a new access token. It may not know yet
\* that its session changed. Home Assistant answers as the session is now:
\* a new access token, or a refusal for a revoked session.
Refresh(t) ==
  /\ uses[t] # None
  /\ answers' = answers \cup
       {[t |-> t, kind |-> "refresh", s |-> uses[t], e |-> epoch[t], ok |-> uses[t] \notin revoked]}
  /\ UNCHANGED <<store, revoked, epoch, uses, off, fresh, lost>>

\* The new access token comes. Home Assistant gave it before any revoke of
\* its session. The tab writes it only when the store still has its
\* session (a compare and set).
Refreshed(m) ==
  /\ m.kind = "refresh"
  /\ m.ok
  /\ answers' = answers \ {m}
  /\ IF Mode = "nocas" \/ store.s = m.s
       THEN /\ store' = [s |-> m.s, a |-> IF store.a < MaxAccess THEN store.a + 1 ELSE store.a]
            /\ uses' = [uses EXCEPT ![m.t] = m.s]
       ELSE UNCHANGED <<store, uses>>
  /\ UNCHANGED <<revoked, epoch, off, fresh, lost>>

\* Home Assistant refused the refresh: the session ended. The tab clears
\* the store only when it still has that session (a compare and set). It
\* ends its socket only when the socket uses that session.
Refused(m) ==
  /\ m.kind = "refresh"
  /\ ~m.ok
  /\ answers' = answers \ {m}
  /\ store' = IF store.s = m.s THEN [s |-> None, a |-> 0] ELSE store
  /\ IF Mode = "noowner" \/ uses[m.t] = m.s
       THEN /\ uses' = [uses EXCEPT ![m.t] = None]
            /\ lost' = IF uses[m.t] # None /\ uses[m.t] \notin revoked THEN lost \cup {m.t} ELSE lost
       ELSE UNCHANGED <<uses, lost>>
  /\ UNCHANGED <<revoked, epoch, off, fresh>>

\* The person disconnects on a tab. The tab makes a new epoch, clears the
\* store and revokes its session.
Disconnect(t) ==
  /\ epoch[t] < MaxEpoch
  /\ epoch' = [epoch EXCEPT ![t] = @ + 1]
  /\ revoked' = IF store.s # None THEN revoked \cup {store.s} ELSE revoked
  /\ store' = [s |-> None, a |-> 0]
  /\ uses' = [uses EXCEPT ![t] = None]
  /\ off' = off \cup {t}
  /\ UNCHANGED <<answers, fresh, lost>>

\* A tab reads the store (the news of a different tab, or a reconnect).
\* A session in the store is the choice of the person on a different tab.
Notice(t) ==
  /\ uses[t] # store.s
  /\ uses' = [uses EXCEPT ![t] = store.s]
  /\ off' = IF store.s # None THEN off \ {t} ELSE off
  /\ UNCHANGED <<store, revoked, epoch, answers, fresh, lost>>

Next ==
  \/ \E t \in Tabs : SignIn(t) \/ Refresh(t) \/ Disconnect(t) \/ Notice(t)
  \/ \E m \in answers : Exchanged(m) \/ Refreshed(m) \/ Refused(m)

Spec == Init /\ [][Next]_vars

\* The store never has a session that a tab revoked.
StoreNotRevoked == store.s = None \/ store.s \notin revoked

\* After a disconnect, the tab has no socket, until the person signs in
\* again (on this tab or on a different tab).
OffMeansNone == \A t \in off : uses[t] = None

\* A refusal never closes the socket of a session that is not revoked.
NoLiveLoss == lost = {}
=============================================================================
