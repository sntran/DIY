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
(* The page calls the cloud of EcoFlow directly (assets/js/ecoflow.js),    *)
(* with no relay. The relay here is then the network: it also sends each   *)
(* request to the cloud and gives the answer back. A poll of EcoFlow reads *)
(* each station in a call of its own, so each station is as the station    *)
(* of this model. A station of EcoFlow can apply a command after its       *)
(* answer (Lag = TRUE, MakerLink.lag.cfg). The cloud answers, and the      *)
(* station changes in a later step (Apply).                                *)
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
(* - The end after the poll: the end of a control with no error shows on   *)
(*   the page with the answer of a poll. That poll starts after the end.   *)
(*   Until then, the switch waits. So the page never shows the state from  *)
(*   before the control as the state after it (EndNew). An end with an     *)
(*   error shows at once. When that poll fails, the end shows too, and the *)
(*   status of the link has the error (the page tells that it has no       *)
(*   link).                                                                *)
(* - The wait for the station (EcoFlow, with Lag): the end of a control    *)
(*   with no error waits (APPLY_WAIT, the step Settle). Then it goes with  *)
(*   the next poll. The model takes that the station applies the command   *)
(*   in this wait: Settle comes only after Apply. A station that is slower *)
(*   shows its change with a later poll.                                   *)
(*                                                                         *)
(* Seven modes have a fault:                                               *)
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
(* - "earlyend": the page shows the end of a control at once. It then      *)
(*   shows the poll from before the command as the state after the control *)
(*   (MakerLink.earlyend.cfg).                                             *)
(* - "nosettle": with Lag, the end of a control does not wait for the      *)
(*   station. The poll after it reads the station before the change. The   *)
(*   page then shows the old state as the state after the control          *)
(*   (MakerLink.nosettle.cfg).                                             *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Accounts, MaxChanges, MaxSwitches, MaxPolls, MaxControls, MaxLosses, Mode, Lag

None == "none"
\* The page with no station.
NoPage == [acct |-> None, val |-> None]
Values == {"on", "off"}
Other(v) == IF v = "on" THEN "off" ELSE "on"

\* A request or an answer of the relay: a poll or a command, of a
\* generation, for an account. An answer has the value that the cloud gave.
\* The answer of a poll also has the count of the commands of its
\* generation that the cloud served before it (seq).
Msg(kind, g, a, v, stage) == [kind |-> kind, gen |-> g, acct |-> a, val |-> v, stage |-> stage, seq |-> 0]
\* No command that a station must still apply.
NoOwed == [acct |-> None, val |-> None, hook |-> FALSE]

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
  losses,   \* the count of the messages that the network lost (a limit)
  cseq,     \* the count of the commands of this generation that the cloud served
  pseq,     \* the count of the poll that the page shows (seq)
  goal,     \* the count when the end of the last control came (cseq)
  held,     \* the end of a control waits for the next poll
  carried,  \* the poll that waits has the end of a control
  shown,    \* the control on the page: "none", "wait", "ok" or "err"
  perr,     \* the last poll failed: the page tells that it has no link
  owed,     \* a command that the cloud answered, and that the station must still apply (Lag)
  settling  \* the end of a control waits for the station (APPLY_WAIT)

vars == <<cloud, token, gen, net, busy, again, pending, page, synced,
          changes, switches, polls, controls, losses,
          cseq, pseq, goal, held, carried, shown, perr, owed, settling>>
ends == <<cseq, pseq, goal, held, carried, shown, perr>>
lag == <<owed, settling>>

TypeOK ==
  /\ cloud \in [Accounts -> Values]
  /\ token \in Accounts \cup {None}
  /\ gen \in Nat
  /\ busy \in BOOLEAN
  /\ again \in BOOLEAN
  /\ pending \in BOOLEAN
  /\ page = NoPage \/ (page.acct \in Accounts /\ page.val \in Values)
  /\ synced \in BOOLEAN
  /\ cseq \in Nat /\ pseq \in Nat /\ goal \in Nat
  /\ held \in BOOLEAN /\ carried \in BOOLEAN /\ perr \in BOOLEAN
  /\ shown \in {"none", "wait", "ok", "err"}
  /\ owed = NoOwed \/ (owed.acct \in Accounts /\ owed.val \in Values /\ owed.hook \in BOOLEAN)
  /\ settling \in BOOLEAN

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
  /\ cseq = 0
  /\ pseq = 0
  /\ goal = 0
  /\ held = FALSE
  /\ carried = FALSE
  /\ shown = "none"
  /\ perr = FALSE
  /\ owed = NoOwed
  /\ settling = FALSE

\* The hook sends a poll of its generation.
SendPoll == net \cup {Msg("poll", gen, token, None, "req")}

\* A person changes the station of an account.
Person(a) ==
  /\ changes < MaxChanges
  /\ cloud' = [cloud EXCEPT ![a] = Other(@)]
  /\ synced' = (synced /\ a /= token)
  /\ changes' = changes + 1
  /\ UNCHANGED <<token, gen, net, busy, again, pending, page, switches, polls, controls, losses>>
  /\ UNCHANGED ends
  /\ UNCHANGED lag

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
  /\ cseq' = 0 /\ pseq' = 0 /\ goal' = 0
  /\ held' = FALSE /\ carried' = FALSE /\ shown' = "none" /\ perr' = FALSE
  \* The hook does not wait for a command of the old generation.
  /\ owed' = IF owed = NoOwed THEN NoOwed ELSE [owed EXCEPT !.hook = FALSE]
  /\ settling' = FALSE
  /\ UNCHANGED <<cloud, changes, polls, controls, losses>>

\* The timer of the hook: a poll, or nothing while a poll waits.
Timer ==
  /\ token /= None
  /\ polls < MaxPolls
  /\ polls' = polls + 1
  /\ IF busy /\ Mode /= "overlap"
       THEN UNCHANGED <<net, busy, held, carried>>
       ELSE /\ net' = SendPoll
            /\ busy' = TRUE
            /\ carried' = (carried \/ held)
            /\ held' = FALSE
  /\ UNCHANGED <<cloud, token, gen, again, pending, page, synced, changes, switches, controls, losses>>
  /\ UNCHANGED <<cseq, pseq, goal, shown, perr>>
  /\ UNCHANGED lag

\* A switch on the page: a control of the AC outlets, when the page shows
\* their state and no control waits.
Control ==
  /\ token /= None
  /\ page /= NoPage
  /\ ~pending
  /\ shown /= "wait"
  /\ controls < MaxControls
  /\ net' = net \cup {Msg("cmd", gen, token, Other(page.val), "req")}
  /\ pending' = TRUE
  /\ shown' = "wait"
  /\ controls' = controls + 1
  /\ UNCHANGED <<cloud, token, gen, busy, again, page, synced, changes, switches, polls, losses>>
  /\ UNCHANGED <<cseq, pseq, goal, held, carried, perr>>
  /\ UNCHANGED lag

\* The relay and the cloud: a poll reads the station, and a command
\* changes it. The command of a control that ended with a timeout
\* ("late") changes the station with no answer. For the hook, it is as a
\* change of a person. So is a command of an old generation: the person
\* connected the same account again. With Lag, the cloud answers a
\* command, and the station applies it later (owed, Apply).
Serve(m) ==
  /\ m \in net
  /\ m.stage \in {"req", "late"}
  /\ IF m.kind = "poll"
       THEN /\ net' = (net \ {m}) \cup
                {[Msg("poll", m.gen, m.acct, cloud[m.acct], "ans") EXCEPT !.seq = IF m.gen = gen THEN cseq ELSE 0]}
            /\ synced' = (synced \/ (m.gen = gen /\ m.acct = token))
            /\ UNCHANGED <<cloud, cseq, owed>>
       ELSE IF m.stage = "late"
         THEN /\ cloud' = [cloud EXCEPT ![m.acct] = m.val]
              /\ net' = net \ {m}
              /\ synced' = (synced /\ m.acct /= token)
              /\ UNCHANGED <<cseq, owed>>
         ELSE IF Lag
           THEN /\ owed = NoOwed
                /\ owed' = [acct |-> m.acct, val |-> m.val, hook |-> m.gen = gen]
                /\ net' = (net \ {m}) \cup {Msg("cmd", m.gen, m.acct, m.val, "ans")}
                /\ UNCHANGED <<cloud, synced, cseq>>
           ELSE /\ cloud' = [cloud EXCEPT ![m.acct] = m.val]
                /\ net' = (net \ {m}) \cup {Msg("cmd", m.gen, m.acct, m.val, "ans")}
                /\ synced' = (synced /\ (m.gen = gen \/ m.acct /= token))
                /\ cseq' = IF m.gen = gen THEN cseq + 1 ELSE cseq
                /\ UNCHANGED owed
  /\ UNCHANGED <<token, gen, busy, again, pending, page, changes, switches, polls, controls, losses>>
  /\ UNCHANGED <<pseq, goal, held, carried, shown, perr, settling>>

\* The station applies a command that the cloud answered (Lag). A command
\* that the hook waits for (hook) is a change of the hook: the hook must
\* show it. A different one is as a change of a person.
Apply ==
  /\ owed /= NoOwed
  /\ cloud' = [cloud EXCEPT ![owed.acct] = owed.val]
  /\ synced' = (synced /\ (owed.hook \/ owed.acct /= token))
  /\ cseq' = IF owed.hook THEN cseq + 1 ELSE cseq
  /\ owed' = NoOwed
  /\ UNCHANGED <<token, gen, net, busy, again, pending, page, changes, switches, polls, controls, losses>>
  /\ UNCHANGED <<pseq, goal, held, carried, shown, perr, settling>>

\* The network loses a request or an answer.
Lose(m) ==
  /\ m \in net
  /\ losses < MaxLosses
  /\ net' = net \ {m}
  /\ losses' = losses + 1
  /\ UNCHANGED <<cloud, token, gen, busy, again, pending, page, synced, changes, switches, polls, controls>>
  /\ UNCHANGED ends
  /\ UNCHANGED lag

\* The end of a poll or of a control: a poll again, or a poll after a
\* control, as in Deliver.
\* A new poll takes the end of a control that waits (h). With no new poll,
\* the end waits.
AfterPoll(n, h) ==
  IF again
    THEN /\ net' = n \cup {Msg("poll", gen, token, None, "req")}
         /\ again' = FALSE
         /\ carried' = h
         /\ held' = FALSE
         /\ UNCHANGED busy
    ELSE /\ net' = n
         /\ busy' = FALSE
         /\ carried' = FALSE
         /\ held' = h
         /\ UNCHANGED again

AfterControl(n, h) ==
  IF Mode = "nopoll"
    THEN /\ net' = n
         /\ held' = h
         /\ UNCHANGED <<busy, again, carried>>
    ELSE IF busy
      THEN /\ net' = n
           /\ again' = (Mode /= "noagain")
           /\ held' = h
           /\ UNCHANGED <<busy, carried>>
      ELSE /\ net' = n \cup {Msg("poll", gen, token, None, "req")}
           /\ busy' = TRUE
           /\ carried' = h
           /\ held' = FALSE
           /\ UNCHANGED again

\* The wait of the hook for the answer of a poll ends (ANSWER_WAIT): the
\* hook stops the request. The page keeps its state, and the hook did not
\* get the read of the cloud (synced is FALSE until the next poll).
TimeoutPoll ==
  /\ Mode /= "notimeout"
  /\ busy
  /\ token /= None
  /\ AfterPoll({m \in net : ~(m.kind = "poll" /\ m.gen = gen)}, held)
  /\ synced' = FALSE
  /\ perr' = TRUE
  /\ shown' = IF carried THEN "ok" ELSE shown
  /\ UNCHANGED <<cloud, token, gen, pending, page, changes, switches, polls, controls, losses>>
  /\ UNCHANGED <<cseq, pseq, goal>>
  /\ UNCHANGED lag

\* The wait of the hook for the end of a control ends. The control ends
\* with an error. Its request can still reach the cloud ("late"), and its
\* answer does not count. With Lag, the hook does not wait for its
\* command: when the station applies it, it is as a change of a person.
Late(m) == IF m.kind = "cmd" /\ m.gen = gen /\ m.stage = "req" THEN Msg("cmd", m.gen, m.acct, m.val, "late") ELSE m
TimeoutControl ==
  /\ Mode /= "notimeout"
  /\ pending
  /\ pending' = FALSE
  /\ shown' = "err"
  /\ AfterControl({Late(m) : m \in {k \in net : ~(k.kind = "cmd" /\ k.gen = gen /\ k.stage = "ans")}}, held)
  /\ owed' = IF owed = NoOwed THEN NoOwed ELSE [owed EXCEPT !.hook = FALSE]
  /\ UNCHANGED <<cloud, token, gen, page, synced, changes, switches, polls, controls, losses>>
  /\ UNCHANGED <<cseq, pseq, goal, perr, settling>>

\* The hook takes an answer of its generation only. The end of a poll
\* starts the poll "again". The end of a control starts a poll, or marks
\* a poll "again" while a poll waits. With Lag, the end of a control
\* waits for the station first (settling). The goal counts the command
\* that the station must still apply.
Deliver(m) ==
  /\ m \in net
  /\ m.stage = "ans"
  /\ IF m.gen /= gen
       THEN /\ net' = net \ {m}
            /\ UNCHANGED <<busy, again, pending, page>>
            /\ UNCHANGED ends
            /\ UNCHANGED settling
       ELSE IF m.kind = "poll"
         THEN /\ page' = [acct |-> m.acct, val |-> m.val]
              /\ pseq' = m.seq
              /\ perr' = FALSE
              /\ shown' = IF carried THEN "ok" ELSE shown
              /\ AfterPoll(net \ {m}, held)
              /\ UNCHANGED <<pending, cseq, goal, settling>>
         ELSE /\ pending' = FALSE
              /\ goal' = cseq + (IF owed.hook THEN 1 ELSE 0)
              /\ IF Mode = "earlyend"
                   THEN /\ shown' = "ok"
                        /\ AfterControl(net \ {m}, held)
                        /\ UNCHANGED settling
                   ELSE IF Lag /\ Mode /= "nosettle"
                     THEN /\ settling' = TRUE
                          /\ net' = net \ {m}
                          /\ UNCHANGED <<busy, again, held, carried, shown>>
                     ELSE /\ AfterControl(net \ {m}, TRUE)
                          /\ UNCHANGED <<shown, settling>>
              /\ UNCHANGED <<page, cseq, pseq, perr>>
  /\ UNCHANGED <<cloud, token, gen, synced, changes, switches, polls, controls, losses, owed>>

\* The wait for the station ends (APPLY_WAIT). The station applied the
\* command in the wait. Then the end of the control goes with the next
\* poll, as in Deliver.
Settle ==
  /\ settling
  /\ ~owed.hook
  /\ settling' = FALSE
  /\ AfterControl(net, TRUE)
  /\ UNCHANGED <<cloud, token, gen, pending, page, synced, changes, switches, polls, controls, losses>>
  /\ UNCHANGED <<cseq, pseq, goal, shown, perr, owed>>

Next ==
  \/ \E a \in Accounts : Person(a)
  \/ \E t \in Accounts \cup {None} : Switch(t)
  \/ Timer
  \/ Control
  \/ \E m \in net : Serve(m) \/ Deliver(m) \/ Lose(m)
  \/ TimeoutPoll
  \/ TimeoutControl
  \/ Apply
  \/ Settle

Spec == Init /\ [][Next]_vars

\* The network and the cloud answer in the end, the station applies a
\* command, and the timers of the waits of the hook fire.
LSpec ==
  /\ Spec
  /\ WF_vars(\E m \in net : Serve(m) \/ Deliver(m))
  /\ WF_vars(TimeoutPoll)
  /\ WF_vars(TimeoutControl)
  /\ WF_vars(Apply)
  /\ WF_vars(Settle)

\* The page shows only the station of the account of the token.
PageOwn == page = NoPage \/ page.acct = token

\* All is quiet: no poll waits or is due, and no control or end of a
\* control waits. Also no message of this generation is in flight.
Quiet == ~busy /\ ~again /\ ~pending /\ ~settling /\ \A m \in net : m.gen /= gen

\* When all is quiet, and a poll read the cloud after the last change of a
\* person, the page shows the state of the cloud. A change of a control of
\* the hook is not a change of a person: the hook must show it too.
Fresh == (token /= None /\ Quiet /\ synced) => page = [acct |-> token, val |-> cloud[token]]

\* The end of a control with no error shows only with a poll that the
\* cloud read after the command. So the page does not show the state from
\* before the control as its new state. When that poll fails, the page
\* tells that it has no link (perr).
EndNew == (shown = "ok" /\ ~perr) => pseq >= goal

\* After a disconnect, the page shows no station and no control waits.
Clear == token = None => (page = NoPage /\ ~pending)

\* The hook never waits for ever: a poll, a control and the wait for the
\* station end.
Live == /\ (busy /\ token /= None) ~> ~busy
        /\ pending ~> ~pending
        /\ settling ~> ~settling
=============================================================================
