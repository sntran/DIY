--------------------------- MODULE HomeAssistant ---------------------------
(***************************************************************************)
(* The sign-in to Home Assistant on the device (assets/js/home_assistant.js *)
(* and DIYWeb.HomeAssistant). The tokens of a sign-in (a session) are in   *)
(* IndexedDB, for all the tabs of the browser, with the generation: the    *)
(* count of the disconnects. Each tab of the app has its own socket to     *)
(* Home Assistant.                                                         *)
(*                                                                         *)
(* A sign-in is in its own tab. The tab reads the generation at its start, *)
(* and asks Home Assistant for the tokens of the code (the exchange). A    *)
(* tab of the app asks for tokens when it refreshes its access token. Each *)
(* answer can come late: after a disconnect, or after a different tab      *)
(* changed the store. A disconnect adds one to the generation, clears the  *)
(* store, and revokes its session on Home Assistant. A new sign-in revokes *)
(* the session that it replaces. The tabs of the app then read the store   *)
(* (Notice: the BroadcastChannel, or a reconnect). Home Assistant refuses  *)
(* a refresh of a revoked session.                                         *)
(*                                                                         *)
(* The rules of the hook:                                                  *)
(* - The generation: a sign-in keeps its session only when the generation *)
(*   is the same as at its start. Else it revokes its session.            *)
(* - The compare and set: a refresh writes its access token only when the *)
(*   store still has the session of the refresh.                          *)
(* - The owner: a refused refresh ends only the socket of its own session. *)
(*                                                                         *)
(* Three modes have a fault:                                               *)
(* - "nogen": the tab of a sign-in keeps each exchange. A disconnect while *)
(*   a sign-in finishes then gives a session of a sign-in that started     *)
(*   before the disconnect (HomeAssistant.nogen.cfg).                      *)
(* - "nocas": a refresh writes its session with no check. A refresh that  *)
(*   was in flight then puts back a session that a disconnect revoked     *)
(*   (HomeAssistant.nocas.cfg).                                            *)
(* - "noowner": a refused refresh ends the socket of the tab with no      *)
(*   check. A late refusal of an old session then closes the socket of    *)
(*   the new session (HomeAssistant.noowner.cfg).                          *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Tabs, Sessions, MaxAccess, MaxGen, Mode

None == "none"

VARIABLES store,    \* the store in IndexedDB: [s |-> a session or None,
                    \* a |-> the count of its access tokens, g |-> the
                    \* generation, from |-> the generation at the start of
                    \* the sign-in of the session]
          revoked,  \* the sessions that a tab revoked
          uses,     \* the session of the socket of each tab, or None
          off,      \* the tabs where the last step of the person was a
                    \* disconnect, with no session in the store after it
          answers,  \* the answers of Home Assistant in flight
          fresh,    \* the sessions that Home Assistant did not give yet
          lost      \* the tabs where a refusal closed the socket of a
                    \* session that is not revoked

vars == <<store, revoked, uses, off, answers, fresh, lost>>

Answers == [t : Tabs, kind : {"exchange", "refresh"}, s : Sessions, g : 0..MaxGen, ok : BOOLEAN]

Empty(g) == [s |-> None, a |-> 0, g |-> g, from |-> 0]

TypeOK ==
  /\ store \in [s : Sessions \cup {None}, a : 0..MaxAccess, g : 0..MaxGen, from : 0..MaxGen]
  /\ revoked \subseteq Sessions
  /\ uses \in [Tabs -> Sessions \cup {None}]
  /\ off \subseteq Tabs
  /\ answers \subseteq Answers
  /\ fresh \subseteq Sessions
  /\ lost \subseteq Tabs

Init ==
  /\ store = Empty(0)
  /\ revoked = {}
  /\ uses = [t \in Tabs |-> None]
  /\ off = {}
  /\ answers = {}
  /\ fresh = Sessions
  /\ lost = {}

\* The person signs in from a tab of the app: the sign-in opens in a new
\* tab, and the new tab reads the generation. Home Assistant gives a new
\* session, and the new tab asks for its tokens (the exchange of the code).
SignIn(t) ==
  /\ \E s \in fresh :
       /\ fresh' = fresh \ {s}
       /\ answers' = answers \cup {[t |-> t, kind |-> "exchange", s |-> s, g |-> store.g, ok |-> TRUE]}
  /\ off' = off \ {t}
  /\ UNCHANGED <<store, revoked, uses, lost>>

\* The tokens of an exchange come. The tab of the sign-in keeps them only in
\* the generation of its start, and revokes the session that they replace.
\* Else it revokes the new session. The tabs of the app read the store
\* later (Notice).
Exchanged(m) ==
  /\ m.kind = "exchange"
  /\ answers' = answers \ {m}
  /\ IF Mode = "nogen" \/ m.g = store.g
       THEN /\ store' = [s |-> m.s, a |-> 0, g |-> store.g, from |-> m.g]
            /\ revoked' = IF store.s # None THEN revoked \cup {store.s} ELSE revoked
       ELSE /\ revoked' = revoked \cup {m.s}
            /\ UNCHANGED store
  /\ UNCHANGED <<uses, off, fresh, lost>>

\* A tab with a socket asks for a new access token. It may not know yet
\* that its session changed. Home Assistant answers as the session is now:
\* a new access token, or a refusal for a revoked session.
Refresh(t) ==
  /\ uses[t] # None
  /\ answers' = answers \cup
       {[t |-> t, kind |-> "refresh", s |-> uses[t], g |-> store.g, ok |-> uses[t] \notin revoked]}
  /\ UNCHANGED <<store, revoked, uses, off, fresh, lost>>

\* The new access token comes. Home Assistant gave it before any revoke of
\* its session. The tab writes it only when the store still has its
\* session (a compare and set).
Refreshed(m) ==
  /\ m.kind = "refresh"
  /\ m.ok
  /\ answers' = answers \ {m}
  /\ IF Mode = "nocas" \/ store.s = m.s
       THEN /\ store' = [store EXCEPT !.s = m.s, !.a = IF @ < MaxAccess THEN @ + 1 ELSE @]
            /\ uses' = [uses EXCEPT ![m.t] = m.s]
       ELSE UNCHANGED <<store, uses>>
  /\ UNCHANGED <<revoked, off, fresh, lost>>

\* Home Assistant refused the refresh: the session ended. The tab clears
\* the store only when it still has that session (a compare and set). It
\* ends its socket only when the socket uses that session.
Refused(m) ==
  /\ m.kind = "refresh"
  /\ ~m.ok
  /\ answers' = answers \ {m}
  /\ store' = IF store.s = m.s THEN Empty(store.g) ELSE store
  /\ IF Mode = "noowner" \/ uses[m.t] = m.s
       THEN /\ uses' = [uses EXCEPT ![m.t] = None]
            /\ lost' = IF uses[m.t] # None /\ uses[m.t] \notin revoked THEN lost \cup {m.t} ELSE lost
       ELSE UNCHANGED <<uses, lost>>
  /\ UNCHANGED <<revoked, off, fresh>>

\* The person disconnects on a tab, or stops a sign-in. The tab makes a new
\* generation, clears the store and revokes its session.
Disconnect(t) ==
  /\ store.g < MaxGen
  /\ store' = Empty(store.g + 1)
  /\ revoked' = IF store.s # None THEN revoked \cup {store.s} ELSE revoked
  /\ uses' = [uses EXCEPT ![t] = None]
  /\ off' = off \cup {t}
  /\ UNCHANGED <<answers, fresh, lost>>

\* A tab reads the store (the news of a different tab, or a reconnect).
\* A session in the store is the choice of the person on a different tab.
Notice(t) ==
  /\ uses[t] # store.s
  /\ uses' = [uses EXCEPT ![t] = store.s]
  /\ off' = IF store.s # None THEN off \ {t} ELSE off
  /\ UNCHANGED <<store, revoked, answers, fresh, lost>>

Next ==
  \/ \E t \in Tabs : SignIn(t) \/ Refresh(t) \/ Disconnect(t) \/ Notice(t)
  \/ \E m \in answers : Exchanged(m) \/ Refreshed(m) \/ Refused(m)

Spec == Init /\ [][Next]_vars

\* The store never has a session that a tab revoked.
StoreNotRevoked == store.s = None \/ store.s \notin revoked

\* The store never has the session of a sign-in that started before the
\* last disconnect.
NoOldSignIn == store.s = None \/ store.from = store.g

\* After a disconnect, the tab has no socket, until the person signs in
\* again (on this tab or on a different tab).
OffMeansNone == \A t \in off : uses[t] = None

\* A refusal never closes the socket of a session that is not revoked.
NoLiveLoss == lost = {}
=============================================================================
