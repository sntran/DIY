----------------------------- MODULE MakerLink -----------------------------
(***************************************************************************)
(* The direct link to the cloud of the maker of a power station, with no   *)
(* Home Assistant (assets/js/maker_link.js, DIYWeb.RelayController and     *)
(* DIY.Pecron).                                                            *)
(*                                                                         *)
(* The hook keeps the token of the person on the device. It reads the      *)
(* stations (a poll) through the relay of the server of the app, at the    *)
(* start and on a timer. A switch on the page sends a control (a command)  *)
(* through the relay. The relay sends each request to the cloud and gives  *)
(* the answer back. The answers can come in any order. The station has     *)
(* one value here: its AC outlets, on or off.                              *)
(*                                                                         *)
(* A person changes the station at any time (on the station, or in the     *)
(* app of the maker). The person can also give a new token (a different    *)
(* account), or disconnect.                                                *)
(*                                                                         *)
(* The rules of the hook:                                                  *)
(* - The generation: a new token or a disconnect starts a new generation.  *)
(*   An answer of an old generation changes nothing.                       *)
(* - One poll at a time: a timer while a poll waits does nothing. The      *)
(*   next timer polls.                                                     *)
(* - A poll after a control: the end of a control starts a poll. While a   *)
(*   poll waits, it marks a poll "again" for the end of that poll. The     *)
(*   page then shows the new state.                                        *)
(* - The timeout: the network can lose a request or an answer (also the    *)
(*   body of an answer). The wait of the hook for an answer ends after a   *)
(*   time (ANSWER_WAIT). A poll then ends with no new state. A control     *)
(*   ends with an error, and its request can still change the station      *)
(*   later. The hook never waits for ever (the property Live).             *)
(*                                                                         *)
(* Five modes have a fault:                                                *)
(* - "nogen": a new token does not start a new generation. A late answer   *)
(*   of the old account then shows on the page (MakerLink.nogen.cfg).      *)
(* - "overlap": a timer starts a second poll while one waits. The answer   *)
(*   of the older poll can come last, and the page shows the old state     *)
(*   (MakerLink.overlap.cfg).                                              *)
(* - "noagain": the end of a control while a poll waits does nothing. The  *)
(*   poll that read the cloud before the control ends last, and the page   *)
(*   keeps the old state (MakerLink.noagain.cfg).                          *)
(* - "nopoll": the end of a control starts no poll. The page keeps the old *)
(*   state (MakerLink.nopoll.cfg).                                         *)
(* - "notimeout": the wait for an answer has no end. When the network      *)
(*   loses an answer, the hook waits for ever (MakerLink.notimeout.cfg).   *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Accounts, MaxChanges, MaxSwitches, MaxPolls, MaxControls, MaxLosses, Mode

None == "none"
\* The page with no station.
NoPage == [acct |-> None, val |-> None]
Values == {"on", "off"}
Other(v) == IF v = "on" THEN "off" ELSE "on"

\* A request or an answer of the relay: a poll or a command, of a
\* generation, for an account. An answer has the value that the cloud gave.
Msg(kind, g, a, v, stage) == [kind |-> kind, gen |-> g, acct |-> a, val |-> v, stage |-> stage]

VARIABLES
  cloud,    \* the AC outlets of the station of each account
  token,    \* the account of the token of the hook, or None
  gen,      \* the generation of the hook
  net,      \* the requests and the answers in flight
  busy,     \* a poll of the hook waits for its answer
  again,    \* the hook polls again at the end of the poll that waits
  pending,  \* a control waits for its end
  page,     \* what the page shows: an account and a value, or NoPage
  synced,   \* a poll of this generation read the cloud after the last change of a person
  changes,  \* the count of the changes of a person (a limit)
  switches, \* the count of the new tokens and the disconnects (a limit)
  polls,    \* the count of the timers (a limit)
  controls, \* the count of the controls (a limit)
  losses    \* the count of the messages that the network lost (a limit)

vars == <<cloud, token, gen, net, busy, again, pending, page, synced,
          changes, switches, polls, controls, losses>>

TypeOK ==
  /\ cloud \in [Accounts -> Values]
  /\ token \in Accounts \cup {None}
  /\ gen \in Nat
  /\ busy \in BOOLEAN
  /\ again \in BOOLEAN
  /\ pending \in BOOLEAN
  /\ page = NoPage \/ (page.acct \in Accounts /\ page.val \in Values)
  /\ synced \in BOOLEAN

Init ==
  /\ cloud = [a \in Accounts |-> "on"]
  /\ token = None
  /\ gen = 0
  /\ net = {}
  /\ busy = FALSE
  /\ again = FALSE
  /\ pending = FALSE
  /\ page = NoPage
  /\ synced = FALSE
  /\ changes = 0
  /\ switches = 0
  /\ polls = 0
  /\ controls = 0
  /\ losses = 0

\* The hook sends a poll of its generation.
SendPoll == net \cup {Msg("poll", gen, token, None, "req")}

\* A person changes the station of an account.
Person(a) ==
  /\ changes < MaxChanges
  /\ cloud' = [cloud EXCEPT ![a] = Other(@)]
  /\ synced' = (synced /\ a /= token)
  /\ changes' = changes + 1
  /\ UNCHANGED <<token, gen, net, busy, again, pending, page, switches, polls, controls, losses>>

\* The person gives a new token, or disconnects (None). The hook clears
\* the page, and starts a poll for a new token.
Switch(t) ==
  /\ switches < MaxSwitches
  /\ t /= token
  /\ token' = t
  /\ gen' = IF Mode = "nogen" THEN gen ELSE gen + 1
  /\ page' = NoPage
  /\ again' = FALSE
  /\ pending' = FALSE
  /\ synced' = FALSE
  /\ busy' = (t /= None)
  /\ net' = IF t = None THEN net ELSE net \cup {Msg("poll", gen', t, None, "req")}
  /\ switches' = switches + 1
  /\ UNCHANGED <<cloud, changes, polls, controls, losses>>

\* The timer of the hook: a poll, or nothing while a poll waits.
Timer ==
  /\ token /= None
  /\ polls < MaxPolls
  /\ polls' = polls + 1
  /\ IF busy /\ Mode /= "overlap"
       THEN UNCHANGED <<net, busy>>
       ELSE /\ net' = SendPoll
            /\ busy' = TRUE
  /\ UNCHANGED <<cloud, token, gen, again, pending, page, synced, changes, switches, controls, losses>>

\* A switch on the page: a control of the AC outlets, when the page shows
\* their state and no control waits.
Control ==
  /\ token /= None
  /\ page /= NoPage
  /\ ~pending
  /\ controls < MaxControls
  /\ net' = net \cup {Msg("cmd", gen, token, Other(page.val), "req")}
  /\ pending' = TRUE
  /\ controls' = controls + 1
  /\ UNCHANGED <<cloud, token, gen, busy, again, page, synced, changes, switches, polls, losses>>

\* The relay and the cloud: a poll reads the station, and a command
\* changes it. The command of a control that ended with a timeout
\* ("late") changes the station with no answer. For the hook, it is as a
\* change of a person. So is a command of an old generation: the person
\* connected the same account again.
Serve(m) ==
  /\ m \in net
  /\ m.stage \in {"req", "late"}
  /\ IF m.kind = "poll"
       THEN /\ net' = (net \ {m}) \cup {Msg("poll", m.gen, m.acct, cloud[m.acct], "ans")}
            /\ synced' = (synced \/ (m.gen = gen /\ m.acct = token))
            /\ UNCHANGED cloud
       ELSE IF m.stage = "late"
         THEN /\ cloud' = [cloud EXCEPT ![m.acct] = m.val]
              /\ net' = net \ {m}
              /\ synced' = (synced /\ m.acct /= token)
         ELSE /\ cloud' = [cloud EXCEPT ![m.acct] = m.val]
              /\ net' = (net \ {m}) \cup {Msg("cmd", m.gen, m.acct, m.val, "ans")}
              /\ synced' = (synced /\ (m.gen = gen \/ m.acct /= token))
  /\ UNCHANGED <<token, gen, busy, again, pending, page, changes, switches, polls, controls, losses>>

\* The network loses a request or an answer.
Lose(m) ==
  /\ m \in net
  /\ losses < MaxLosses
  /\ net' = net \ {m}
  /\ losses' = losses + 1
  /\ UNCHANGED <<cloud, token, gen, busy, again, pending, page, synced, changes, switches, polls, controls>>

\* The end of a poll or of a control: a poll again, or a poll after a
\* control, as in Deliver.
AfterPoll(n) ==
  IF again
    THEN /\ net' = n \cup {Msg("poll", gen, token, None, "req")}
         /\ again' = FALSE
         /\ UNCHANGED busy
    ELSE /\ net' = n
         /\ busy' = FALSE
         /\ UNCHANGED again

AfterControl(n) ==
  IF Mode = "nopoll"
    THEN /\ net' = n
         /\ UNCHANGED <<busy, again>>
    ELSE IF busy
      THEN /\ net' = n
           /\ again' = (Mode /= "noagain")
           /\ UNCHANGED busy
      ELSE /\ net' = n \cup {Msg("poll", gen, token, None, "req")}
           /\ busy' = TRUE
           /\ UNCHANGED again

\* The wait of the hook for the answer of a poll ends (ANSWER_WAIT): the
\* hook stops the request. The page keeps its state, and the hook did not
\* get the read of the cloud (synced is FALSE until the next poll).
TimeoutPoll ==
  /\ Mode /= "notimeout"
  /\ busy
  /\ token /= None
  /\ AfterPoll({m \in net : ~(m.kind = "poll" /\ m.gen = gen)})
  /\ synced' = FALSE
  /\ UNCHANGED <<cloud, token, gen, pending, page, changes, switches, polls, controls, losses>>

\* The wait of the hook for the end of a control ends. The control ends
\* with an error. Its request can still reach the cloud ("late"), and its
\* answer does not count.
Late(m) == IF m.kind = "cmd" /\ m.gen = gen /\ m.stage = "req" THEN Msg("cmd", m.gen, m.acct, m.val, "late") ELSE m
TimeoutControl ==
  /\ Mode /= "notimeout"
  /\ pending
  /\ pending' = FALSE
  /\ AfterControl({Late(m) : m \in {k \in net : ~(k.kind = "cmd" /\ k.gen = gen /\ k.stage = "ans")}})
  /\ UNCHANGED <<cloud, token, gen, page, synced, changes, switches, polls, controls, losses>>

\* The hook takes an answer of its generation only. The end of a poll
\* starts the poll "again". The end of a control starts a poll, or marks
\* a poll "again" while a poll waits.
Deliver(m) ==
  /\ m \in net
  /\ m.stage = "ans"
  /\ IF m.gen /= gen
       THEN /\ net' = net \ {m}
            /\ UNCHANGED <<busy, again, pending, page>>
       ELSE IF m.kind = "poll"
         THEN /\ page' = [acct |-> m.acct, val |-> m.val]
              /\ IF again
                   THEN /\ net' = (net \ {m}) \cup {Msg("poll", gen, token, None, "req")}
                        /\ again' = FALSE
                        /\ UNCHANGED busy
                   ELSE /\ net' = net \ {m}
                        /\ busy' = FALSE
                        /\ UNCHANGED again
              /\ UNCHANGED pending
         ELSE /\ pending' = FALSE
              /\ IF Mode = "nopoll"
                   THEN /\ net' = net \ {m}
                        /\ UNCHANGED <<busy, again>>
                   ELSE IF busy
                     THEN /\ net' = net \ {m}
                          /\ again' = (Mode /= "noagain")
                          /\ UNCHANGED busy
                     ELSE /\ net' = (net \ {m}) \cup {Msg("poll", gen, token, None, "req")}
                          /\ busy' = TRUE
                          /\ UNCHANGED again
              /\ UNCHANGED page
  /\ UNCHANGED <<cloud, token, gen, synced, changes, switches, polls, controls, losses>>

Next ==
  \/ \E a \in Accounts : Person(a)
  \/ \E t \in Accounts \cup {None} : Switch(t)
  \/ Timer
  \/ Control
  \/ \E m \in net : Serve(m) \/ Deliver(m) \/ Lose(m)
  \/ TimeoutPoll
  \/ TimeoutControl

Spec == Init /\ [][Next]_vars

\* The network and the cloud answer in the end, and the timers of the
\* waits of the hook fire.
LSpec ==
  /\ Spec
  /\ WF_vars(\E m \in net : Serve(m) \/ Deliver(m))
  /\ WF_vars(TimeoutPoll)
  /\ WF_vars(TimeoutControl)

\* The page shows only the station of the account of the token.
PageOwn == page = NoPage \/ page.acct = token

\* All is quiet: no poll waits, no poll is due, no control waits, and no
\* message of this generation is in flight.
Quiet == ~busy /\ ~again /\ ~pending /\ \A m \in net : m.gen /= gen

\* When all is quiet, and a poll read the cloud after the last change of a
\* person, the page shows the state of the cloud. A change of a control of
\* the hook is not a change of a person: the hook must show it too.
Fresh == (token /= None /\ Quiet /\ synced) => page = [acct |-> token, val |-> cloud[token]]

\* After a disconnect, the page shows no station and no control waits.
Clear == token = None => (page = NoPage /\ ~pending)

\* The hook never waits for ever: a poll and a control end.
Live == /\ (busy /\ token /= None) ~> ~busy
        /\ pending ~> ~pending
=============================================================================
