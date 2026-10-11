------------------------------- MODULE Stage -------------------------------
(***************************************************************************)
(* The stage of an item (DIYWeb.Stage, assets/js/stage.js). The hook      *)
(* Stage flies the model of an item from the plan to the front of the      *)
(* page, and back to the plan. Three things occur in any order:           *)
(* - the frames of the page: the start of the flight out, and the steps of *)
(*   each flight;                                                          *)
(* - the person: a close (the Escape key, the key Put it back, or a tap    *)
(*   next to the panel);                                                   *)
(* - the LiveView: it patches the stage, for example after a change in the *)
(*   panel. It also removes the stage at any time. For                     *)
(*   example, the person goes to a different item, or uses the Back key   *)
(*   of the browser.                                                       *)
(*                                                                         *)
(* Each flight has a number. A step of a flight that is not the last       *)
(* flight does nothing. A close starts a new flight, and the removal stops *)
(* the last flight. The first step of a flight occurs at once; the other   *)
(* steps wait for a frame of the page. With less motion, the model is at   *)
(* once in front, and a close is at once.                                 *)
(*                                                                         *)
(* The state of the stage ("placed", "landed" or "closing") is the        *)
(* attribute data-stage. The LiveView sets it for the hook, and a patch   *)
(* keeps it. A patch puts back only what the LiveView keeps.              *)
(*                                                                         *)
(* Four modes have a fault, and TLC finds each:                           *)
(* - "noalive": a step does not check its flight. The flight out lands     *)
(*   after a close (Stage.noalive.cfg).                                    *)
(* - "noclosing": a second close does not stop. The close goes two times  *)
(*   (Stage.noclosing.cfg).                                                *)
(* - "nogone": the removal does not stop a start that waits for a frame.   *)
(*   The start flies a stage that is not on the page (Stage.nogone.cfg).   *)
(* - "nokeep": a patch does not keep the state. This is a class that the   *)
(*   hook adds before the LiveView: the LiveView then does not keep it.    *)
(*   After a patch, the stage has no state (Stage.nokeep.cfg).             *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Last,  \* the index of the last frame: the front of the item
          Mode   \* "ok", or a fault: "noalive", "noclosing", "nogone", "nokeep"

VARIABLES queue,    \* the calls that wait for a frame of the page
          flight,   \* the number of the last flight
          closing,  \* the stage closes, or it is not on the page
          gone,     \* the LiveView removed the stage
          reduce,   \* the person wants less motion
          shown,    \* the frame that shows
          state,    \* the state of the stage, or "none"
          kept,     \* the state that a patch of the LiveView keeps
          patches,  \* the number of the patches of the close
          late      \* a call changed the stage after its removal

vars == <<queue, flight, closing, gone, reduce, shown, state, kept, patches, late>>

States == {"placed", "landed", "closing"}
Frames == 0..Last
Start == [kind |-> "start"]
Steps == [kind : {"step"}, id : Nat, dir : {"out", "back"}, from : Frames, t : 1..Last]
Step(id, dir, from) == [kind |-> "step", id |-> id, dir |-> dir, from |-> from, t |-> 1]

\* The frame of a step. The flight out goes from the frame 0 to the last
\* frame. The flight back goes from its first frame to the frame 0.
FrameOf(s) == IF s.dir = "out" THEN s.t ELSE s.from - (s.from * s.t) \div Last

TypeOK ==
  /\ queue \subseteq {Start} \cup Steps
  /\ flight \in Nat
  /\ closing \in BOOLEAN
  /\ gone \in BOOLEAN
  /\ reduce \in BOOLEAN
  /\ shown \in Frames
  /\ state \in States \cup {"none"}
  /\ kept \in States \cup {"none"}
  /\ patches \in Nat
  /\ late \in BOOLEAN

\* The close patches the page one time at most.
OnePatch == patches <= 1

\* No call changes the stage after its removal.
NotLate == ~late

\* The panel shows only when the model is in front, and not in a close.
PanelInFront == state = "landed" /\ ~gone => shown = Last /\ ~closing

\* The stage keeps its state: the model and the panel stay at their place.
Placed == ~gone => state \in States

\* The hook sets the state. The LiveView keeps it, but not in the mode
\* "nokeep".
SetState(s) == state' = s /\ kept' = IF Mode = "nokeep" THEN kept ELSE s

\* The flight shows a frame.
Show(f) == shown' = f /\ late' = (late \/ gone)

Init ==
  /\ queue = {Start}
  /\ flight = 0
  /\ closing = FALSE
  /\ gone = FALSE
  /\ reduce \in BOOLEAN
  /\ shown = Last
  /\ state = "placed"
  /\ kept = IF Mode = "nokeep" THEN "none" ELSE "placed"
  /\ patches = 0
  /\ late = FALSE

\* The start of the flight out, at the first frame of the page after the
\* mount.
RunStart ==
  /\ Start \in queue
  /\ IF closing
       THEN /\ queue' = queue \ {Start}
            /\ UNCHANGED <<flight, shown, state, kept, late>>
       ELSE /\ flight' = flight + 1
            /\ IF reduce
                 THEN /\ Show(Last)
                      /\ SetState("landed")
                      /\ queue' = queue \ {Start}
                 ELSE /\ Show(0)
                      /\ queue' = (queue \ {Start}) \cup {Step(flight + 1, "out", 0)}
                      /\ UNCHANGED <<state, kept>>
  /\ UNCHANGED <<closing, gone, reduce, patches>>

\* A step of a flight. At the end, the flight out lands, and the flight
\* back patches the page.
RunStep(s) ==
  /\ s \in queue
  /\ s.kind = "step"
  /\ IF s.id # flight /\ Mode # "noalive"
       THEN /\ queue' = queue \ {s}
            /\ UNCHANGED <<shown, state, kept, patches, late>>
       ELSE /\ Show(FrameOf(s))
            /\ IF s.t < Last
                 THEN /\ queue' = (queue \ {s}) \cup {[s EXCEPT !.t = s.t + 1]}
                      /\ UNCHANGED <<state, kept, patches>>
                 ELSE /\ queue' = queue \ {s}
                      /\ IF s.dir = "out"
                           THEN SetState("landed") /\ UNCHANGED patches
                           ELSE patches' = patches + 1 /\ UNCHANGED <<state, kept>>
  /\ UNCHANGED <<flight, closing, gone, reduce>>

\* A close by the person. The stage listens only while it is on the page.
\* The panel goes at once.
Close ==
  /\ ~gone
  /\ ~closing \/ Mode = "noclosing"
  /\ closing' = TRUE
  /\ flight' = flight + 1
  /\ SetState("closing")
  /\ IF reduce
       THEN /\ patches' = patches + 1
            /\ UNCHANGED <<queue, shown, late>>
       ELSE /\ Show(shown)
            /\ queue' = queue \cup {Step(flight + 1, "back", shown)}
            /\ UNCHANGED patches
  /\ UNCHANGED <<gone, reduce>>

\* A patch of the stage by the LiveView: it puts back what it keeps.
Patch ==
  /\ ~gone
  /\ state' = kept
  /\ UNCHANGED <<queue, flight, closing, gone, reduce, shown, kept, patches, late>>

\* The LiveView removes the stage.
Remove ==
  /\ ~gone
  /\ gone' = TRUE
  /\ flight' = flight + 1
  /\ closing' = (closing \/ Mode # "nogone")
  /\ UNCHANGED <<queue, reduce, shown, state, kept, patches, late>>

\* The page gives a frame to each call that waits.
Tick == RunStart \/ \E s \in queue : RunStep(s)

Next == Tick \/ Close \/ Patch \/ Remove

Spec == Init /\ [][Next]_vars /\ WF_vars(Tick)

\* A close ends with the patch, or the stage goes before it.
Closes == closing ~> (patches > 0 \/ gone)

\* The model lands in front, unless the stage closes first.
Lands == <>(state = "landed" \/ closing)
=============================================================================
