# How to work

## Keep going

- Do not stop between steps to report and wait. Finish the chain and report once:
  *"So lets keep going, why are we taking pauses?"*, *"Lets keep going? Why are
  we stopping?"*
- Ask only when the answer changes what gets built and no reasonable default
  exists. Otherwise state the assumption and continue.
- Do not over-engineer the fix for a process problem: prefer the smallest change
  to what already exists.

## Evidence

- Measure before concluding, and say which tenant, window, and command produced
  the number.
- A tool's output describes the lookup that produced it. Empty, zero, and a
  complete-looking result set are each properties of the instrument until proven
  otherwise. Confirm identity in-band before trusting a result.
- When rejecting someone's root cause, triangulate on scope, timing, and error
  identity. One axis is a coincidence.
- Retract in the same place the claim was made, and say what the corrected number
  is.

## Cost

- Probes are scoped before they are widened. Filter and partition first; a slow
  probe usually means the wrong predicate, not too small a window: *"Instead of
  widening the time interval, can we just query the response element?"*
- Use the cheapest model that can do the step — data gathering does not need the
  expensive one.
- Watch what a change costs to run repeatedly: CI time, test count, context.
  *"if these are cheap CI tests then it is okay, if not we should make sure they
  don't run all the time"*.

## Finish the loop

- Merged is not shipped. After a merge, confirm the image or config is actually
  running where it was supposed to land, then measure the effect.
- Fix the class, not the instance: when a defect has siblings, enumerate them from
  the built or shipped artifact, and push the fix upstream so everyone gets it
  rather than patching it locally.
- Before a compaction or a fresh session, write the state into a durable tracker
  or an open docs PR — what is settled, what is open, what happens next.
