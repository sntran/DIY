------------------------ MODULE HomeAssistantStates ------------------------
(***************************************************************************)
(* The states of the lights, the switches and the fans of Home Assistant   *)
(* on the page (assets/js/home_assistant.js and DIYWeb.HomeAssistant).     *)
(*                                                                         *)
(* The hook reads the registry of Home Assistant, and watches the states   *)
(* of its devices (subscribe_entities). Home Assistant sends all their     *)
(* states first, then each change. The hook sends the states to the        *)
(* LiveView. A switch on the page sends a control to the hook, and the     *)
(* hook asks Home Assistant to turn the device on or off (call_service).   *)
(* Each device has one entity here.                                        *)
(*                                                                         *)
(* A person changes a state, or the registry, at any time. The socket can  *)
(* close. Then the hook opens a new socket and reads the registry again.   *)
(* The messages of one socket come in their order. But the late messages   *)
(* of an old socket can come after the messages of the new socket. The     *)
(* ids of the commands start again on each socket, as in the hook.         *)
(*                                                                         *)
(* The rules of the hook and of the LiveView:                              *)
(* - The socket: the hook takes the messages of its open socket only.      *)
(* - The watch: the hook takes the events of its watch only.               *)
(* - The old states: a new watch and a closed socket clear the states of   *)
(*   the hook.                                                             *)
(* - The end: a new watch ends the old watch (unsubscribe_events).         *)
(* - The LiveView forgets the states and the controls when the link is not *)
(*   connected.                                                            *)
(*                                                                         *)
(* Five modes have a fault:                                                *)
(* - "noepoch": the hook takes the messages of an old socket. A late state *)
(*   of the old socket then replaces a new state                           *)
(*   (HomeAssistantStates.noepoch.cfg).                                    *)
(* - "noid": the hook takes the events of each watch of its socket. The    *)
(*   first states of the old watch come after the start of the new watch.  *)
(*   Then a state that Home Assistant removes stays                        *)
(*   (HomeAssistantStates.noid.cfg).                                       *)
(* - "noclear": the hook keeps its states. A state that Home Assistant     *)
(*   removed while the socket was closed then stays                        *)
(*   (HomeAssistantStates.noclear.cfg).                                    *)
(* - "nounsub": the hook does not end the old watch. Home Assistant then   *)
(*   keeps two watches (HomeAssistantStates.nounsub.cfg).                  *)
(* - "nolvclear": the LiveView keeps the states when the link is not       *)
(*   connected (HomeAssistantStates.nolvclear.cfg).                        *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Devices, MaxChanges, MaxDrops, MaxRegistry, MaxControls, Mode

\* A state in Home Assistant ("none": Home Assistant has no state of the
\* device). A state on the page ("unav": no state, "absent": not a device
\* of the registry).
Values == {"on", "off", "none"}
Shown == {"on", "off", "unav", "absent"}

Absent == [d \in Devices |-> "absent"]
NoStates == [d \in Devices |-> "none"]

\* A message of Home Assistant to the hook is "a", "c" or "done". "a" has
\* all the states of a watch ("skip" for a device out of the watch). "c" is
\* a change, and "done" is the end of a control. A command of the hook has
\* the same form: "sub" (a new watch of the devices that are not "skip"),
\* "unsub" or "call". A message of the hook to the LiveView is "status",
\* "states" or "done".
Msg(kind, id, d, v, st) == [kind |-> kind, id |-> id, d |-> d, v |-> v, st |-> st]
Skip == [d \in Devices |-> "skip"]
Out(kind, up, d, st) == [kind |-> kind, up |-> up, d |-> d, st |-> st]

VARIABLES
  ha,       \* the state of each device in Home Assistant
  reg,      \* the devices of the registry
  watches,  \* the watches in Home Assistant: [s, id, ids]
  net,      \* the messages of Home Assistant to the hook, for each socket
  cmds,     \* the commands of the hook on its open socket
  sock,     \* the socket of the hook (the count of the closes)
  up,       \* the socket of the hook is open
  watch,    \* the id of the watch of the hook, or 0
  ids,      \* the devices of the watch of the hook
  next,     \* the id of the next command on the socket
  controls, \* the devices of the last read of the registry
  stale,    \* the hook must read the registry again
  hs,       \* the states of the hook
  ready,    \* the hook has all the states of its watch
  dirty,    \* the hook must send its states (its timer)
  calls,    \* the devices of the controls that wait for Home Assistant
  toHook,   \* the controls of the LiveView to the hook
  out,      \* the messages of the hook to the LiveView
  lvUp,     \* the LiveView: the link is connected
  lv,       \* the states that the LiveView shows
  pending,  \* the controls that wait in the LiveView
  changes,  \* the count of the changes of a person (a limit)
  regs,     \* the count of the changes of the registry (a limit)
  used      \* the count of the controls (a limit)

vars == <<ha, reg, watches, net, cmds, sock, up, watch, ids, next, controls, stale, hs,
          ready, dirty, calls, toHook, out, lvUp, lv, pending, changes, regs, used>>

Sockets == 0..MaxDrops

TypeOK ==
  /\ ha \in [Devices -> Values]
  /\ reg \subseteq Devices
  /\ sock \in Sockets
  /\ up \in BOOLEAN
  /\ watch \in Nat
  /\ ids \subseteq Devices
  /\ controls \subseteq Devices
  /\ hs \in [Devices -> Values]
  /\ ready \in BOOLEAN
  /\ dirty \in BOOLEAN
  /\ calls \subseteq Devices
  /\ lvUp \in BOOLEAN
  /\ lv \in [Devices -> Shown]
  /\ pending \subseteq Devices

Init ==
  /\ ha = [d \in Devices |-> "off"]
  /\ reg = Devices
  /\ watches = {}
  /\ net = [s \in Sockets |-> <<>>]
  /\ cmds = <<>>
  /\ sock = 0
  /\ up = TRUE
  /\ watch = 0
  /\ ids = {}
  /\ next = 1
  /\ controls = {}
  /\ stale = TRUE
  /\ hs = NoStates
  /\ ready = FALSE
  /\ dirty = FALSE
  /\ calls = {}
  /\ toHook = <<>>
  /\ out = <<>>
  /\ lvUp = TRUE
  /\ lv = Absent
  /\ pending = {}
  /\ changes = 0
  /\ regs = 0
  /\ used = 0

\* A change of the state of a device: a message "c" for each watch of the
\* device, on the queue of its socket.
RECURSIVE Notify(_, _, _, _)
Notify(queues, ws, d, v) ==
  IF ws = {} THEN queues
  ELSE LET w == CHOOSE x \in ws : TRUE
       IN Notify([queues EXCEPT ![w.s] = @ \o <<Msg("c", w.id, d, v, Skip)>>], ws \ {w}, d, v)

Watching(d) == {w \in watches : d \in w.ids}

\* The end of each control that waits, for the LiveView.
RECURSIVE Dones(_)
Dones(ds) ==
  IF ds = {} THEN <<>>
  ELSE LET d == CHOOSE x \in ds : TRUE IN <<Out("done", TRUE, d, Absent)>> \o Dones(ds \ {d})

\* The states that the hook sends: the devices of its last read only.
Show == [d \in Devices |-> IF d \notin controls THEN "absent"
                           ELSE IF hs[d] = "none" THEN "unav" ELSE hs[d]]

\* The states of Home Assistant on the page.
Expected == [d \in Devices |-> IF d \notin reg THEN "absent"
                               ELSE IF ha[d] = "none" THEN "unav" ELSE ha[d]]

\* A person changes the state of a device in Home Assistant ("none": Home
\* Assistant removes its state).
Person(d, v) ==
  /\ changes < MaxChanges
  /\ v /= ha[d]
  /\ ha' = [ha EXCEPT ![d] = v]
  /\ net' = Notify(net, Watching(d), d, v)
  /\ changes' = changes + 1
  /\ UNCHANGED <<reg, watches, cmds, sock, up, watch, ids, next, controls, stale, hs, ready,
                 dirty, calls, toHook, out, lvUp, lv, pending, regs, used>>

\* A person adds a device to the registry, or removes it. The hook reads
\* the registry again (the watch of the registry).
Registry(d) ==
  /\ regs < MaxRegistry
  /\ reg' = IF d \in reg THEN reg \ {d} ELSE reg \cup {d}
  /\ regs' = regs + 1
  /\ stale' = TRUE
  /\ UNCHANGED <<ha, watches, net, cmds, sock, up, watch, ids, next, controls, hs, ready,
                 dirty, calls, toHook, out, lvUp, lv, pending, changes, used>>

\* The hook reads the registry. With the same devices and a watch, it sends
\* its states again. Else it ends the old watch, clears its states, and
\* starts a new watch. With no device, it starts no watch: it sends no
\* states.
Read ==
  /\ up
  /\ stale
  /\ stale' = FALSE
  /\ controls' = reg
  /\ IF reg = ids /\ watch /= 0
       THEN /\ dirty' = (dirty \/ ready)
            /\ UNCHANGED <<cmds, watch, ids, next, hs, ready, out>>
       ELSE LET ending == IF watch /= 0 /\ Mode /= "nounsub"
                            THEN <<Msg("unsub", watch, "none", "none", Skip)>> ELSE <<>>
            IN /\ hs' = IF Mode = "noclear" THEN hs ELSE NoStates
               /\ ready' = FALSE
               /\ dirty' = IF Mode = "noclear" THEN dirty ELSE FALSE
               /\ IF reg = {}
                    THEN /\ cmds' = cmds \o ending
                         /\ watch' = 0
                         /\ ids' = {}
                         /\ out' = out \o <<Out("states", TRUE, "none", Absent)>>
                         /\ UNCHANGED next
                    ELSE /\ cmds' = cmds \o ending \o <<Msg("sub", next, "none", "none",
                                     [d \in Devices |-> IF d \in reg THEN "on" ELSE "skip"])>>
                         /\ watch' = next
                         /\ ids' = reg
                         /\ next' = next + 1
                         /\ UNCHANGED out
  /\ UNCHANGED <<ha, reg, watches, net, sock, up, calls, toHook, lvUp, lv, pending, changes,
                 regs, used>>

\* Home Assistant does the first command of the open socket. A new watch
\* sends all its states after its result. A control sends the change
\* before its end.
HomeAssistant ==
  /\ up
  /\ cmds /= <<>>
  /\ cmds' = Tail(cmds)
  /\ LET c == Head(cmds) IN
       CASE c.kind = "sub" ->
              LET devs == {d \in Devices : c.st[d] /= "skip"} IN
              /\ watches' = watches \cup {[s |-> sock, id |-> c.id, ids |-> devs]}
              /\ net' = [net EXCEPT ![sock] = @ \o <<Msg("a", c.id, "none", "none",
                           [d \in Devices |-> IF d \in devs THEN ha[d] ELSE "skip"])>>]
              /\ UNCHANGED ha
         [] c.kind = "unsub" ->
              /\ watches' = {w \in watches : w.s /= sock \/ w.id /= c.id}
              /\ UNCHANGED <<ha, net>>
         [] c.kind = "call" ->
              /\ ha' = [ha EXCEPT ![c.d] = c.v]
              /\ net' = LET n == Notify(net, Watching(c.d), c.d, c.v)
                        IN [n EXCEPT ![sock] = @ \o <<Msg("done", 0, c.d, "none", Skip)>>]
              /\ UNCHANGED watches
  /\ UNCHANGED <<reg, sock, up, watch, ids, next, controls, stale, hs, ready, dirty, calls,
                 toHook, out, lvUp, lv, pending, changes, regs, used>>

\* The hook takes a message of a socket. It takes only the messages of its
\* open socket, and of its watch.
Hook(s) ==
  /\ net[s] /= <<>>
  /\ net' = [net EXCEPT ![s] = Tail(@)]
  /\ LET m == Head(net[s])
         taken == (s = sock /\ up) \/ Mode = "noepoch"
     IN IF taken /\ m.kind \in {"a", "c"} /\ (m.id = watch \/ Mode = "noid")
          THEN /\ hs' = IF m.kind = "a"
                          THEN [d \in Devices |-> IF m.st[d] \in {"skip", "none"} THEN hs[d]
                                                  ELSE m.st[d]]
                          ELSE [hs EXCEPT ![m.d] = m.v]
               /\ ready' = (ready \/ m.kind = "a")
               /\ dirty' = TRUE
               /\ UNCHANGED <<calls, out>>
        ELSE IF taken /\ m.kind = "done" /\ m.d \in calls
          THEN /\ calls' = calls \ {m.d}
               /\ out' = out \o <<Out("done", TRUE, m.d, Absent)>>
               /\ UNCHANGED <<hs, ready, dirty>>
        ELSE UNCHANGED <<hs, ready, dirty, calls, out>>
  /\ UNCHANGED <<ha, reg, watches, cmds, sock, up, watch, ids, next, controls, stale, toHook,
                 lvUp, lv, pending, changes, regs, used>>

\* The timer of the hook: it sends its states to the LiveView.
Push ==
  /\ dirty
  /\ dirty' = FALSE
  /\ out' = out \o <<Out("states", TRUE, "none", Show)>>
  /\ UNCHANGED <<ha, reg, watches, net, cmds, sock, up, watch, ids, next, controls, stale, hs,
                 ready, calls, toHook, lvUp, lv, pending, changes, regs, used>>

\* The hook takes a control of the LiveView. With no open socket, or for a
\* device that it does not know, it tells the end at once.
HookControl ==
  /\ toHook /= <<>>
  /\ toHook' = Tail(toHook)
  /\ LET c == Head(toHook) IN
       IF up /\ c.d \in controls
         THEN /\ cmds' = cmds \o <<Msg("call", 0, c.d, c.v, Skip)>>
              /\ calls' = calls \cup {c.d}
              /\ UNCHANGED out
         ELSE /\ out' = out \o <<Out("done", TRUE, c.d, Absent)>>
              /\ UNCHANGED <<cmds, calls>>
  /\ UNCHANGED <<ha, reg, watches, net, sock, up, watch, ids, next, controls, stale, hs, ready,
                 dirty, lvUp, lv, pending, changes, regs, used>>

\* The socket closes. Its commands are lost, and Home Assistant ends its
\* watches. Its late messages can still come. The hook clears its states,
\* tells the LiveView, and ends the controls that wait.
Drop ==
  /\ up
  /\ sock < MaxDrops
  /\ up' = FALSE
  /\ sock' = sock + 1
  /\ cmds' = <<>>
  /\ watches' = {w \in watches : w.s /= sock}
  /\ watch' = 0
  /\ ids' = {}
  /\ next' = 1
  /\ hs' = IF Mode = "noclear" THEN hs ELSE NoStates
  /\ ready' = FALSE
  /\ dirty' = IF Mode = "noclear" THEN dirty ELSE FALSE
  /\ calls' = {}
  /\ out' = out \o <<Out("status", FALSE, "none", Absent)>> \o Dones(calls)
  /\ UNCHANGED <<ha, reg, net, controls, stale, toHook, lvUp, lv, pending, changes, regs, used>>

\* A new socket: the LiveView reads the devices again.
Reconnect ==
  /\ ~up
  /\ up' = TRUE
  /\ stale' = TRUE
  /\ out' = out \o <<Out("status", TRUE, "none", Absent)>>
  /\ UNCHANGED <<ha, reg, watches, net, cmds, sock, watch, ids, next, controls, hs, ready, dirty,
                 calls, toHook, lvUp, lv, pending, changes, regs, used>>

\* The LiveView takes a message of the hook. It takes the states only while
\* the link is connected, and it forgets them when the link is not.
LiveView ==
  /\ out /= <<>>
  /\ out' = Tail(out)
  /\ LET m == Head(out) IN
       CASE m.kind = "status" ->
              /\ lvUp' = m.up
              /\ IF ~m.up /\ Mode /= "nolvclear"
                   THEN /\ lv' = Absent
                        /\ pending' = {}
                   ELSE UNCHANGED <<lv, pending>>
         [] m.kind = "states" ->
              /\ lv' = IF lvUp THEN m.st ELSE lv
              /\ UNCHANGED <<lvUp, pending>>
         [] m.kind = "done" ->
              /\ pending' = pending \ {m.d}
              /\ UNCHANGED <<lvUp, lv>>
  /\ UNCHANGED <<ha, reg, watches, net, cmds, sock, up, watch, ids, next, controls, stale, hs,
                 ready, dirty, calls, toHook, changes, regs, used>>

\* A person taps the switch of a device that is on or off, with no control
\* that waits.
Switch(d) ==
  /\ used < MaxControls
  /\ lvUp
  /\ d \notin pending
  /\ lv[d] \in {"on", "off"}
  /\ pending' = pending \cup {d}
  /\ toHook' = toHook \o <<[d |-> d, v |-> IF lv[d] = "on" THEN "off" ELSE "on"]>>
  /\ used' = used + 1
  /\ UNCHANGED <<ha, reg, watches, net, cmds, sock, up, watch, ids, next, controls, stale, hs,
                 ready, dirty, calls, out, lvUp, lv, changes, regs>>

Next ==
  \/ \E d \in Devices, v \in Values : Person(d, v)
  \/ \E d \in Devices : Registry(d) \/ Switch(d)
  \/ \E s \in Sockets : Hook(s)
  \/ Read \/ HomeAssistant \/ Push \/ HookControl \/ Drop \/ Reconnect \/ LiveView

Spec == Init /\ [][Next]_vars

\* All is quiet: the socket is open, and the hook read the registry after
\* its last change. Its watch has all its states, and no message waits.
Quiet ==
  /\ up
  /\ lvUp
  /\ ~stale
  /\ ~dirty
  /\ (reg = {} \/ (watch /= 0 /\ ready))
  /\ cmds = <<>>
  /\ \A s \in Sockets : net[s] = <<>>
  /\ toHook = <<>>
  /\ out = <<>>
  /\ calls = {}

\* When all is quiet, the page shows the states of Home Assistant.
Fresh == Quiet => lv = Expected

\* When all is quiet, no control waits.
Ended == Quiet => pending = {}

\* When all is quiet, Home Assistant has one watch at most for the hook.
OneWatch == Quiet => Cardinality({w \in watches : w.s = sock}) <= 1

\* When the link is not connected, the page shows no state, and no control
\* waits.
NoneOffline == ~lvUp => (lv = Absent /\ pending = {})
=============================================================================
