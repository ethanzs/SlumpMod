# Directional Parry Rewrite Plan

## Goal

Replace melee parry success based on the floating `ParryComponent` box with a default-on directional parry rule.

The new system should block melee attacks when the defender is actively parrying and the incoming hit is in the defender's front-facing defended region. It should reject hits that land clearly behind the defender, including close facehug stabs dragged behind the parry box and jumping overhead/maul-style arcs that land on the back of the head.

No admin command should be required to enable this. The new system should be the default behavior.

## Non-goals

- Do not make this an admin-toggleable feature.
- Do not rely on `bBoxParrySuccess` for melee parries.
- Do not keep `AdminDisableButtParries` as the main protection layer.
- Do not change hit-trade rollback, parry timing rollback, stamina drain, deflect state, or shield stamina behavior unless required by the new geometry gate.
- Do not use the directional parry result to move pawns or change weapon traces.
- Do not remove the engine `ParryComponent` object unless a later compile/test pass proves all inherited projectile/debug/attachment code no longer needs it. It should remain available for visualization, but it must not trace-block melee.

## Current Behavior

Current melee parry flow:

1. `AOCWeaponAttachment` traces the weapon.
2. If the trace intersects the defender's `ParryComponent`, the attacker sends `bBoxParrySuccess=true` to `AttackOtherPawn`.
3. `XangMod/Include/Pawn/Combat.uci::ProcessResolvedAttack` treats the attack as parried when `bBoxParrySuccess` is true and the defender is actively parrying or shielding.
4. `DetectSuccessfulParry` applies stamina, deflect, parry sounds, and successful-parry feedback.
5. `AdminDisableButtParries` currently adds a front-hemisphere veto inside `DetectSuccessfulParry`.

This means the parry box is the primary melee geometry gate, while the butt-parry check is only a later veto.

## Proposed Behavior

For melee attacks, parry success should be decided by:

```text
bParry = bParryActive
    && DirectionalMeleeParrySucceeds(Info)
    && damage type is parryable
    && damage type is not siege/generic
```

Projectile parry behavior can stay separate through the existing `CheckProjectileParry(Info)` path.

`bForceParry` from pending-hit rollback should not bypass the directional geometry check. It can still represent that a held swing is being resolved during a parry window, but the hit must still be directionally blockable.

## Directional Test Design

Use hit location as the primary geometry proof.

Recommended helper:

```unrealscript
simulated function bool XangModDirectionalMeleeParry(HitInfo Info)
```

Suggested logic:

1. Reject if `Info.HitActor == none`.
2. Reject projectiles. They stay on `CheckProjectileParry`.
3. Get defender yaw direction from `Info.HitActor.GetForwardDirection()`.
4. Flatten the hit offset to 2D so looking up/down does not invert overhead/head-hit results.
5. If the flattened hit location is usable, calculate:

```text
HitOffset = Info.HitLocation - Info.HitActor.Location
HitOffset.Z = 0
HitDot = Normal(HitOffset) dot Info.HitActor.GetForwardDirection()
```

6. Accept if `HitDot >= 0.0` for a front 180-degree hemisphere.
7. Also compute the attacker-position check:

```text
AttackerOffset = self.Location - Info.HitActor.Location
AttackerOffset.Z = 0
AttackerDot = Normal(AttackerOffset) dot Info.HitActor.GetForwardDirection()
```

8. Accept the parry if EITHER the hit landed in the defender's front half OR the attacker is in the defender's front half:

```text
(HitDot >= 0.0) || (AttackerDot >= 0.0)
```

The attacker-position term closes the close-range overhead gap: a large weapon can arc over the head and land behind it while the attacker is still standing directly in front, and the handle+damage tracer mix made that effectively unparryable under a hit-location-only rule.

Kicks (`Attack_Shove`) are not melee parry candidates. Expired held swings that failed the parry timestamp gate pass `bNoParry=true` into `ProcessResolvedAttack`, so a later active parry cannot recapture them.

## Cone Width

Start with a true front hemisphere:

```text
HitDot >= 0.0
```

That is equivalent to 180 degrees: 90 degrees left/right/up/down from the defender's current view direction.

If this is too forgiving, narrow it later with a constant:

```text
160 degrees total: dot >= cos(80 degrees) ~= 0.1736
140 degrees total: dot >= cos(70 degrees) ~= 0.3420
120 degrees total: dot >= cos(60 degrees) = 0.5
110 degrees total: dot >= cos(55 degrees) ~= 0.5736  <- current value
```

Do not make this an admin command initially. Tune in source after playtesting.

## Files To Change

### `XangMod/Include/Pawn/Combat.uci`

Add `XangModDirectionalMeleeParry(HitInfo Info)` near `CheckProjectileParry`.

Update `ProcessResolvedAttack`:

- Add a local `bool bDirectionalParry`.
- Compute it after `bParryActive` is known.
- Replace melee dependence on `bBoxParrySuccess` with `bDirectionalParry`.
- Keep `CheckProjectileParry(Info)` for projectiles.
- Do not let `bForceParry` bypass directional geometry.

Remove the old `bDisableButtParries` block from `DetectSuccessfulParry`, because the new directional gate makes that admin-config path obsolete.

### `XangMod/Include/PC/AdminCommands.uci`

Remove these admin commands entirely:

- `AdminToggleParryBox`
- `S_AdminToggleParryBox`
- `AdminEnableSkeletalParry`
- `S_AdminEnableSkeletalParry`
- `AdminDisableButtParries`
- `S_AdminDisableButtParries`

Reason: the new parry system is default-on and should not depend on dedicated-server config synchronization.

### `XangMod/Include/PC/Vars.uci`

Leave old globalconfig booleans in place for the first implementation only if removing them would require touching many unrelated visual/debug paths.

If left in place, mark them as legacy visual/config remnants, not active melee parry controls.

Candidate legacy vars:

- `bXangModParryBox`
- `bSkeletalParry`
- `bDisableButtParries`

### `XangMod/Include/PC/Effects.uci`

Update comments for those legacy defaults if the vars remain.

Do not present them as active gameplay toggles.

### Optional later cleanup

Only after compile and live testing, consider cleaning up:

- `XangMod/Include/PC/ParryConfig.uci`
- `XangMod/Include/Pawn/Customization.uci` parry component scaling
- `XangMod/Include/XangModWeaponAttachmentCode.uci` parry component scaling
- Parry-box debug commands

Do not do that in the first pass unless the new directional system is proven and the inherited code no longer depends on `ParryComponent`.

### Legacy parry component handling

Keep the component for visualization/debugging, but force it non-trace-blocking anywhere XangMod resizes or moves it:

- `Include/Pawn/Customization.uci`
- `Include/PC/ParryConfig.uci`
- `Include/XangModWeaponAttachmentCode.uci`
- `Classes/XangModWeaponAttachment_DualBucklers.uc`

This prevents vanilla `AOCWeaponAttachment.HandleHitPawn` from adding defenders to `ParryPawns` through `HitInfoTrace.HitComponent == HitPawn.ParryComponent` before the server directional gate runs.

## Expected Gameplay Effects

Should improve:

- Facehug attacks that bypass the floating box.
- Stabs intentionally sent past the box and dragged into the defender.
- Jumping overhead/maul arcs that land on the back of the defender's head.
- Dedicated-server consistency by removing admin toggle synchronization from the melee parry rule.

May change:

- Some precise side drags that previously bypassed the box may now be blocked if their hit location is still in the defender's front hemisphere.
- Looking far upward should shift the defended region upward because the view direction is part of the test.
- Looking far away from an incoming low/body hit may expose the defender more than a yaw-only check would.

## Test Matrix

Test on a dedicated server with two clients.

### Basic front blocks

- Slash from front while defender parries.
- Stab from front while defender parries.
- Overhead from front while defender parries.
- Kick/shove should not become a normal parry unless existing rules already allow it.

### Known exploit cases

- Facehug stab that starts past the defender's box and drags back into body.
- Stab past the side of the defender and drag into back/side.
- Jumping overhead/maul attack that arcs over the head and lands on back of head.
- Attacker standing in front but hit location behind defender.

Expected: hits landing clearly behind should not parry.

### Directional edge cases

- Attacker at defender's left 90 degrees.
- Attacker at defender's right 90 degrees.
- Defender looking straight up while attacked low/front.
- Defender looking straight up while attacked from above/front.
- Defender looking down while attacked at head/front.

### Existing combat systems

- Parry stamina drain.
- Out-of-stamina parry behavior.
- Riposte activation after successful parry.
- Parry rollback pending-hit resolution.
- Hit-trade cancellation.
- Team hit behavior.
- Projectile parry and shield projectile block.
- Ballista/siege damage should remain unparryable through normal melee parry.

### Regression checks

- No admin command should be required to enable the behavior.
- Old admin parry commands should no longer exist after compile.
- `bBoxParrySuccess` should not be required for melee parry success.
- Successful parries still call the existing `DetectSuccessfulParry` effects path.
- Failed directional parries should proceed as normal hits/flinches.

## Validation Commands

Before compile, run:

```bash
git diff --check -- Include/Pawn/Combat.uci Include/PC/AdminCommands.uci Include/PC/Vars.uci Include/PC/Effects.uci
```

Then grep for stale active command definitions:

```bash
grep -nE "exec function Admin(ToggleParryBox|EnableSkeletalParry|DisableButtParries)|S_Admin(ToggleParryBox|EnableSkeletalParry|DisableButtParries)" Include/PC/AdminCommands.uci
```

Expected: no matches.

Grep the melee parry gate:

```bash
grep -nE "bBoxParrySuccess|XangModDirectionalMeleeParry|bForceParry" Include/Pawn/Combat.uci
```

Expected:

- `bBoxParrySuccess` may remain as an unused function parameter for compatibility with existing `AttackOtherPawn` calls.
- The actual melee `bParry =` expression should use `XangModDirectionalMeleeParry`, not `bBoxParrySuccess`.
- `bForceParry` should not bypass directional geometry.

Full UnrealScript compile is still required. Standalone `.uci` lint can give false positives.

## Implementation Decisions

1. Use a full 180-degree front hemisphere (`dot >= 0.0`) for the first version.
2. Use flattened hit location first. If it is near the vertical centerline, fall back to attacker position so ordinary front blocks do not fail because trace data was noisy.
3. Active shields use the same directional melee rule as weapon parries. Projectile shield behavior stays on the existing projectile path.
4. Leave old parry-box debug visualization temporarily, even though it no longer controls melee parry success.
