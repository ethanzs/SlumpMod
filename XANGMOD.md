# XangMod

The main documentation for XangMod, the competitive gameplay modification for
*Chivalry: Medieval Warfare*. The focused experimental plan for visual network animation
interpolation is in [NETWORK_ANIMATION_INTERPOLATION.md](NETWORK_ANIMATION_INTERPOLATION.md).

**Last restructured: 2026-09-14.**

---

## Contents

| § | Section |
|---|---|
| 1 | [What XangMod is](#1-what-xangmod-is) |
| 2 | [Build and deploy](#2-build-and-deploy) |
| 3 | [Code layout](#3-code-layout) |
| 4 | [UnrealScript constraints that actually bite](#4-unrealscript-constraints-that-actually-bite) |
| 5 | [Combat and netcode](#5-combat-and-netcode) |
| 6 | [First-person spectate](#6-first-person-spectate) |
| 7 | [RCON protocol](#7-rcon-protocol) |
| 8 | [Admin commands and configuration](#8-admin-commands-and-configuration) |
| 9 | [Testing](#9-testing) |
| 10 | [Changelog](#10-changelog) |

---

## 1. What XangMod is

XangMod extends vanilla *Chivalry: Medieval Warfare* (the `AOC` package) with competitive
balance changes, netcode fixes, an RCON admin protocol, first-person spectating and a
custom character/weapon customization system. It ships as an SDK mod, downloaded to clients
as DLC by the server.

**The package is `XangMod`. The product is `SlumpMod`.** `Include/Game/Server.uci` sets
`ModDisplayString="SlumpMod 2.5.0"`, which is the name that appears in the server browser.
Both names refer to the same thing.

### 1.1 The BangMod rename

The package was previously called **BangMod**. Everything was renamed to `XangMod` — class
prefixes, the package, the CookedSDK folder. `Src\BangMod` no longer exists. Older notes,
commit messages and comments that say BangMod mean XangMod.

One casualty survives the rename: the content package `BangmodCharacters` does not exist
under either name, which is why the first-person camera freezes for Knight and Vanguard
when it tries to load a 1P mesh from it. See §6 — it is not a spectate bug.

---

## 2. Build and deploy

### 2.1 Where the compiled package goes

The script compile writes to:

```
UDKGame\ContentSDK\XangMod.u
```

The game does **not** load that. It loads the mod as DLC from:

```
UDKGame\CookedSDK\XangMod_<hash>\XangMod.u
```

Glob the folder rather than hardcoding the hash — it changes with the package name.

Note that `UDKGame\Script` and `UDKGame\ScriptFinalRelease` belong to the separate
"megapatch" work and have nothing to do with this mod.

### 2.2 Verify the build actually contains your change

Before diagnosing any "it's still broken" report, confirm the fix is in the package. `.u`
files store their name table as plain text, so:

```
grep -a -c "MyNewFunctionName" .../CookedSDK/XangMod_*/XangMod.u
```

Zero means the build predates your change, whatever the source says. Also compare the `.u`
mtime against the `.uci` mtimes. This check costs seconds and has repeatedly been the
difference between a real bug and a stale build.

### 2.3 Content packages — this will bite you again

The `.upk` content files are **not produced by the script cook**. They normally arrive by
DLC download from the game server into the CookedSDK folder, and **a cook wipes them**. A
local dedicated server does not re-serve them, so after any cook the client has `XangMod.u`
plus shader caches and every custom mesh silently fails to load.

Check:

```
ls UDKGame\CookedSDK\XangMod_*\*.upk
```

If you see only the three shader caches, the content is gone. Fix by copying the 15 `.upk`
files from the mod root back into that folder (about 258 MB).

### 2.4 Logging

Script logging works. `LogAlwaysInternal` output appears as `ScriptLog:` in:

```
C:\Users\Bindon\Documents\My Games\Chivalry Medieval Warfare\UDKGame\Logs\Launch.log
```

`ClientDisplayConsoleMessage` renders in-game instead — that is what the `FPSpectateDebug`
exec uses.

An earlier conclusion that script logging was suppressed entirely was **wrong**; that log
simply predated the logging code.

Do not use the log macro to get there — see §4.

---

## 3. Code layout

### 3.1 The mode × role grid

Nine game modes, five roles each, 45 classes:

```
XangMod{FFA, TD, TO, KOTH, LTS, CTF, TUT, AOCDuel, CDWDuel}
       {"", HUD, PRI, Pawn, PlayerController}.uc
```

Each of those 45 `.uc` files is a stub containing two includes and nothing else:

```unrealscript
class XangModFFAPawn extends XangModPawn;

`include(XangMod/Include/XangModFFA.uci)
`include(XangMod/Include/XangModPawn.uci)
```

- `Include/XangMod<MODE>.uci` — 26 to 162 bytes. Its only job is `` `define GAMEMODE XangMod<MODE> ``.
- `Include/XangMod<ROLE>.uci` — the actual content.

`Include/Game/Server.uci`'s `DefaultProperties` expands the macro:

```unrealscript
PlayerControllerClass=class'`{GAMEMODE}PlayerController'
DefaultPawnClass=class'`{GAMEMODE}Pawn'
HUDType=class'`{GAMEMODE}HUD'
PlayerReplicationInfoClass=class'`{GAMEMODE}PRI'
```

That indirection is the one piece of structure worth protecting. Do not unpick it.

Two mode includes carry more than the define: `XangModLTS.uci` adds a `DefaultProperties`
block setting `IdleTimeLimit` and `RoundTime`, and `XangModTO.uci` carries a comment header.

### 3.2 Role includes are facades

The three large role includes were split by feature in September 2026. Each is now a thin
facade that nests its feature files; **the 45 mode classes were not touched**.

```unrealscript
// Include/XangModPawn.uci
`include(XangMod/Include/Pawn/Vars.uci)
`include(XangMod/Include/Pawn/VO.uci)
`include(XangMod/Include/Pawn/Core.uci)
`include(XangMod/Include/Pawn/Customization.uci)
`include(XangMod/Include/Pawn/Combat.uci)
`include(XangMod/Include/Pawn/Movement.uci)
`include(XangMod/Include/Pawn/Animation.uci)
`include(XangMod/Include/Pawn/Netcode.uci)
`include(XangMod/Include/Pawn/Camera.uci)
```

| File | What is in it |
|---|---|
| `Pawn/Vars.uci` | every pawn `var`. **Included first.** |
| `Pawn/VO.uci` | voice-command (Z/X menu) variation pinning so every client hears the same take |
| `Pawn/Core.uci` | `Tick`, `DrawTextOverHead` |
| `Pawn/Customization.uci` | helmet/shield colours, character appearance, footman stats, 1P mesh lookup |
| `Pawn/Combat.uci` | flinch, parry detection, `AttackOtherPawn`, `ProcessResolvedAttack`, `TakeDamage` |
| `Pawn/Movement.uci` | dodge, jump, lunge, sprint, crouch, velocity, `Bump` |
| `Pawn/Animation.uci` | animation replication, blend nodes, interpolated rotation |
| `Pawn/Netcode.uci` | clock offset, hit-trade arbitration, pending-hit resolution (§5) |
| `Pawn/Camera.uci` | 1P/3P camera, owner mesh, view target, **`DefaultProperties`** (last) |

| File | What is in it |
|---|---|
| `PC/Vars.uci` | every controller `var`, including all `globalconfig`. **Included first.** |
| `PC/ParryConfig.uci` | parry-box and collision-radius class-default sync |
| `PC/Core.uci` | `PostBeginPlay`, `Possess`, `PawnDied`, `Tick`, `StartFire`, `ProcessViewRotation`, `ReplicateMove`, `FOV` |
| `PC/AdminCommands.uci` | every `exec Admin*` and its `S_*` server counterpart |
| `PC/AdminMaps.uci` | the 14 `AdminGoto*` map-change commands |
| `PC/Loadout.uci` | `GetAdmins`, `JoinClass`, `SetAssassinCustom` |
| `PC/Movement.uci` | feint, `state PlayerWalking`, `UpdateRotation`, sprint angle |
| `PC/Debug.uci` | parry-box visualisation, death messages, hit timing, server tick polling |
| `PC/Spectate.uci` | first-person spectate and `state Spectating` (§6) |
| `PC/Network.uci` | netspeed repair, `NetDebug`, bandwidth cap |
| `PC/Effects.uci` | camera shake, hit feedback, drunk post-process chain, **`DefaultProperties`** (last) |

| File | What is in it |
|---|---|
| `Game/Vars.uci` | game `var`s and config. **Included first.** |
| `Game/Match.uci` | `SetGameType`, countdown, voting, round and match lifecycle, tournament mode |
| `Game/RoundReporting.uci` | the RCON round-boundary emitters (§7) |
| `Game/SiegeObjects.uci` | catapult and siege respawn control |
| `Game/Server.uci` | broadcast, `InitRemoteConsole`, seamless travel, **`DefaultProperties`** (last) |

`Include/XangModCompForestSpawnControl.uci` is nested from the `XangModGame.uci` facade,
immediately after `Game/Vars.uci`. It holds the CompForest alternating-spawn logic.

`Include/XangModHUD.uci`, `Include/XangModPRI.uci` and `Include/XangModTOGamemode.uci` are
small enough that they were left unsplit.

**Rules when editing:**

- A new `var` goes in that role's `Vars.uci`, nowhere else.
- `DefaultProperties` belongs only in the last nested file of a set.
- Keep the preprocessor nesting at two levels (`.uc` → facade → feature file). The depth
  limit of the UDK preprocessor is unverified, so do not add a third.

### 3.3 Weapons

`Classes/XangModMeleeWeapon.uc` is the base for 52 melee weapon classes and owns the
shared state machine: parry buffer, stamina validation, riposte handling, and the
counter-parry overrides in `state Release` and `state ParryRelease`.

Those counter-parry blocks used to be copy-pasted into every weapon class. They were
hoisted into the base in September 2026, removing about 1,700 lines. Consequences worth
knowing:

- Eight weapons that previously had **no** counter-parry out of Release gained it:
  BroadDagger, Claymore, Dagesse, DualBucklers, HolyWaterSprinkler, Longsword1H,
  SwordOfWar1H, ThrustDagger.
- DualBucklers and Flail gained counter-parry out of ParryRelease.
- `XangModWeapon_Flail.uc` keeps its own state machine and was left alone; it retains a
  now-redundant local copy of `Release.BeginFire`.
- `XangModWeapon_GrandLance.uc` has a third copy of the counter-parry block in a
  **class-level** `BeginFire` (brace depth 0, not a state override). That is a different
  code path and is intentional.

Everything else in a weapon class is `DefaultProperties` — roughly 250 lines each of
vanilla AOC data. It has to stay per-class; there is no win available there.

Ranged and thrown weapons extend `XangModRangeWeapon`, `XangModThrowableWeapon`, or their
vanilla `AOCWeapon_*` parent directly, and do not inherit the melee state machine.

### 3.4 Weapon attachments — read this before editing one

Weapon attachments cannot share a base class: each `XangModWeaponAttachment_<Weapon>`
extends its own vanilla `AOCWeaponAttachment_<Weapon>` parent. `XangModWeaponAttachment.uc`
exists and carries real logic (`HandleHitPawn` damage delay plus the hit-time stamp for
trade priority), but almost nothing extends it. **Includes are the only sharing mechanism.
Do not try to "fix" this by reparenting.**

There are therefore two include files with opposite placement rules, and getting them
backwards silently breaks things:

| File | Contains | Where it must be included |
|---|---|---|
| `Include/XangModWeaponAttachmentCode.uci` | `GetNetPriority`, `AttachTo` | **class level**, after any `var`s, before the first function |
| `Include/XangModWeaponAttachment.uci` | `NetUpdateFrequency`, `ParryTracersLength` | **inside** the `DefaultProperties` block |

This split exists because of a real bug. The code and the defaults used to live in one
file, included inside `DefaultProperties`, so **neither function ever compiled** — the
compiler parsed their bodies as malformed property assignments. That produced 205 warnings
(about 17% of the whole build log) with this fingerprint:

```
Missing '=' in default properties assignment: AOCOwner.ParryComponent.SetScale3D(...)
redundant data:                               AOCOwner.ParryComponent.SetTranslation(...)
```

The practical effect was that the parry-component setup did nothing through the attachment
path, and the pawn-side setup was being overwritten by vanilla `AttachTo` with no correction
applied. If those warnings ever reappear, the include has been moved back inside a defaults
block. Melee parry success is now decided by the directional gate in `Include/Pawn/Combat.uci`,
not by parry-box intersection. XangMod keeps the `ParryComponent` for visualization/debugging but
forces it non-trace-blocking when it is resized or moved, so vanilla `ParryPawns` classification
does not pre-empt the directional gate.

**Coverage is 46 of 63 attachment classes.** 41 carry the include directly and 5 more
inherit it from a fixed XangMod parent (`_BastardSword extends _Katana`, `_Gladius extends
_Messer`). Still without it:

- Melee, arguably should have it: `_Nodachi` (which extends `AOCWeaponAttachment_Zweihander`
  rather than the XangMod one), `_PoleAxe`, `_PoleAxeBack`, `_BroadDagger`, `_Dagesse`,
  `_DualBucklers`.
- Ranged, thrown and flags, where a parry-box correction is arguably meaningless:
  `_Crossbow`, `_Javelin`, `_JavelinThrow`, `_HeavyJavelin`, `_HeavyJavelinThrow`,
  `_ShortSpear`, `_ShortSpearThrow`, `_FirebugThrow`, `_AgathaFlag`, `_MasonFlag`, and the
  `XangModWeaponAttachment` base itself.

### 3.5 Everything else

| Path | What |
|---|---|
| `Classes/XangModRCon.uc` | the RCON listener and every opcode handler (§7) |
| `Classes/XangModRConSession.uc` | one accepted connection; extends `XangModRCon` |
| `Classes/XangModCustomization*.uc` | character/helmet/armour customization system |
| `Classes/XangModCharacterInfo_*.uc` | per-class character data (`DefaultProperties` only) |
| `Classes/XangModFamilyInfo_*.uc` | per-class family/stat data |
| `Classes/XangModAOCCombatBot.uc` | `addbots` controller: skill floor and wider threat detection; extends `AOCAIDuelCombatController` so it also backs duel-practice bots |
| `Classes/XangModBotBrain.uc` | timed parries, punishes, ripostes, pressure and pursuit for every combat-AI pawn, Kings hardest; attached from `Pawn/Core.uci` `Tick` |
| `Classes/XangModKingBot.uc` | bot King for `[XangMod.XangModAIKing]` maps; spawned by `XangModTO` |
| `Classes/XangModAIKing.uc` | config: TO maps that get a bot King |
| `Classes/XangModNPC_New*.uc` | reduced-replication NPC variants |
| `Localization/INT/XangMod.INT` | localized strings |

---

## 4. UnrealScript constraints that actually bite

These are the ones that have cost real build round-trips. The VS Code UnrealScript
extension reports many errors that are not real; if it compiles under UDK, the linter is
wrong. These, by contrast, are real.

### 4.1 Never use the log or warn macro

`prevent_direct_calls` (Object.uc:1478) expands to `private` under FINAL_RELEASE, so
`LogInternal` and `WarnInternal` are private:

```
Error, Can't access private function 'LogInternal' in 'Object'
```

Vanilla AOC uses the macro freely only because `AOC.u` is precompiled and never rebuilt.
Every log macro in this repo is commented out — that is a deliberate convention, not dead
code. Use `LogAlwaysInternal(coerce string, optional name)` instead: public, `native(3000)`,
not stripped.

### 4.2 No stray backticks anywhere, including comments

The preprocessor is a naive text pass and treats a backtick as a macro invocation wherever
it appears. A backtick inside a comment will break the build.

### 4.3 Every `var` must precede the first function in the class body

`.uci` content is pasted into the class body, so this applies to includes too. Adding a
feature as one self-contained block near the bottom of a `.uci` — vars, then the functions
using them — fails with `Error, 'Var' is not allowed here` on every including class at once.
Declare vars with the others at the top and leave the functions where they are.

The same rule governs **where you insert an include** that contains functions: it must come
after that class's own vars. This cost a round-trip on
`XangModWeaponAttachment_Flail.uc`, the one attachment class that declares a var. Consts are
fine anywhere.

### 4.4 `DefaultProperties` goes last

The block must be the last thing in the generated class body. In a facade, that means the
last nested file. `Include/Game/Server.uci` carries the game defaults for exactly this
reason.

A `defaultproperties` block followed by an include boundary produces a cosmetic
`Unknown property in defaults: linenumber=N` warning — the preprocessor's line marker
landing where the compiler is still parsing defaults. Harmless, but it is why a handful of
those warnings appear for `XangModTO`, `XangModKOTH` and `XangModLTS`.

### 4.5 Compile errors cite the generated file

Line numbers in errors refer to the generated `.uc`, not the `.uci` you edited, and the
offsets differ per including class. `XangModPawn.uc(2382)` is not line 2382 of anything you
can open.

### 4.6 `switch` does not work on strings

Use an `if / else if` chain with `~=` (case-insensitive string compare).

### 4.7 `Pawn.GetBaseAimRotation()` re-enters the camera path

It calls `Controller.GetPlayerViewPoint`, so it must **never** be called from anything the
camera calls. Inline its no-controller branch instead: `Rotation`, plus
`RemoteViewPitch << 8` when Pitch is 0.

### 4.8 Script-instanced components do not get component instancing

`new(self) class'SkeletalMeshComponent' (default.SomeComp)` is valid (precedent:
`GameFramework/classes/GameExplosionActor.uc:423`) but it is a **plain property copy**.
Subobject pointers in the archetype — notably `LightEnvironment` — still point at the
class-default subobject, which is not registered in the world, so the component renders
unlit and black.

Re-point explicitly after `AttachComponent`:

```unrealscript
Comp.SetLightEnvironment(Mesh.LightEnvironment);
```

(Precedent: `AOCWeaponAttachment.uc:258`.)

### 4.9 Locals are declared at the top of a function

All `local` declarations must appear before any executable statement. You cannot declare a
local inside an `if` block or a loop.

---

---

## 5. Combat and netcode

Chivalry's stock melee resolution assumes the server can decide a swing the instant the
attacker's hit RPC arrives. On a dedicated server with mixed ping that assumption produces two
distinct failure modes: a swing that gets committed and then refunded when a parry turns up a
few milliseconds later, and a parry that succeeds but whose success notification arrives after
the defender's weapon state machine has already moved on. SlumpMod addresses both, plus the
related question of who wins when two swings land at nearly the same moment.

The code lives in three places:

- `Include/Pawn/Netcode.uci` — the hold/commit machinery, the client-clock offset estimator, the
  hit-trade arbitration helpers, and the client→server timestamp RPCs.
- `Include/Pawn/Combat.uci` — `AttackOtherPawn`, `ProcessResolvedAttack`,
  `DetectSuccessfulParry`, `CheckProjectileParry`, flinch handling and the `TakeDamage` override.
- `Classes/XangModPawn.uc` — the `PendingHit` and `RecentIncomingHit` struct declarations and
  the rollback tunables. These are declared in the class rather than an include deliberately, so
  every subclass (`XangModAOCDuelPawn`, `XangModCDWDuelPawn`, the gamemode pawns) shares one
  struct type instead of each compiling its own copy.
- `Classes/XangModMeleeWeapon.uc` — the weapon state machine, the parry buffer, the parry
  timestamp stamp, and stamina validation on combos.

`Include/XangModPawn.uci` still exists but is now a thin facade that pulls in the split includes;
nothing of substance lives there.

### 5.1 Parry rollback — the decide-once hold

**The problem this replaces.** The earlier model committed an incoming hit immediately and then
tried to undo it if a parry showed up inside a flat 60 ms defer window. That model failed in two
opposite ways:

- At 0 ping (bots, LAN, standalone) the defender entered `Parry` well inside the flat window, the
  rollback cleared the deferred-replication timer, and the *entire* hit — which had been 100 %
  deferred — was dropped: no damage, no impact sound, no blood.
- When the rollback did not cancel, the player saw commit-then-refund: blood and hit sound play,
  then the damage is refunded. The "bloody but alive" bug.

**The model that ships.** An incoming melee swing is *held* on the defender for a latency-sized
window instead of being applied and later undone. Nothing is applied during the hold, so a parry
that lands inside the window suppresses the swing before any feedback has played. Nothing is ever
played and then taken back.

`AttackOtherPawn` (in `Include/Pawn/Combat.uci`) is a thin dispatcher and runs on the attacker
pawn; `Info.HitActor` is the defender. It does the work that must happen exactly once on RPC
arrival — PRI resolution, the flinch check that blocks swings from a flinched attacker, and the
`PerformAttackSSSC` authority/lag-comp validation — and then decides between holding and
resolving. A swing is eligible for the hold only if it is a real enemy melee hit: not
`bCheckParryOnly`, defender is an `XangModPawn`, not a projectile damage type, not
`Attack_Shove`, not same-team, and the defender is not *already* parrying or active-shielding
(if they are, the parry is already known and there is nothing to wait for).

`GetParryHoldSeconds` (in `Include/Pawn/Netcode.uci`) supplies the length: the defender's one-way
latency, capped at `fParryRollbackMaxHoldSeconds` and floored — holds shorter than
`fParryRollbackMinHoldSeconds` return 0. **At 0 ping the hold is 0**, the dispatcher calls
`ProcessResolvedAttack` directly, and behaviour is vanilla-instant. That is what fixes the
bots-eat-the-whole-hit case: there is no window to roll back inside.

When the hold is non-zero the swing is captured into a `PendingHit` (commit time, attacker,
`HitInfo`, damage string, box-parry and shield flags, swing sound, quick-kick flag, and the
reconstructed action timestamp from 5.3) and appended to the *defender's* `PendingHits` array.
Two paths then resolve it, and exactly one of them fires per swing:

- `ProcessPendingHits` (`Include/Pawn/Netcode.uci`) is polled from the pawn's `Tick` on authority
  only. Any entry whose `fCommitTime` has passed is removed and committed through
  `ProcessResolvedAttack` with `bNoParry = true` as a normal hit, so a later active parry cannot
  recapture a swing that already failed the timestamp gate.
- `ResolvePendingHitsAsParry` (`Include/Pawn/Netcode.uci`) runs on the defender from
  `XangModMeleeWeapon`'s `Parry.BeginState`, *after* `super.BeginState` so that
  `bIsParrying` / `bIsActiveShielding` are set before parry validation reads them. It replays each
  held swing through `ProcessResolvedAttack` with `bForceParry = true`.

`ProcessResolvedAttack` (`Include/Pawn/Combat.uci`) is the single commit path — damage, feedback,
replication, AI notification, stat and achievement bookkeeping, all applied at once. `bForceParry`
does not bypass validation: held parry-window resolutions still have to pass the directional melee
parry gate. A rejected one falls straight through to a normal hit inside the same call. The
parry-active test also honours a fresh authoritative `Parry` state whose replicated booleans have
not serialized yet, using `fServerParryStartTime` and `fParryGracePeriod` on the defending weapon
(see 5.4).

**Why this is safer than rollback.** There is no state to undo, so there is no ordering hazard
between the refund and any feedback that already played. The decision is made once, at the moment
the swing's fate is actually known, and the cost is bounded by the defender's own latency rather
than by a fixed constant applied to everybody.

**Tuning.** `fParryRollbackMaxHoldSeconds` caps the hold; `fParryRollbackMinHoldSeconds` is the
floor below which holding is not worth a frame of delay. Both are declared in
`Classes/XangModPawn.uc` and defaulted in the pawn's `DefaultProperties`.

**Coverage.** `XangModAOCDuelPawn` and `XangModCDWDuelPawn` extend `XangModPawn` and do not
override `AttackOtherPawn`, `Tick`, `ProcessResolvedAttack` or `ProcessPendingHits`, so bots in
duel run through the same path as everything else.

### 5.2 Late parry in Recovery

**The symptom.** On a dedicated server with variable ping, a defender parries successfully very
late in the attacker's release phase and is nevertheless unable to parry again immediately
afterwards — they feel stuck in parry recovery lockout for roughly the normal recovery duration,
about 500 ms.

**The race.** The defender is in `ParryRelease`. The server resolves a very late enemy release hit
as a valid parry. By the time that success notification arrives, the weapon has already
transitioned `ParryRelease` → `Recovery`. Vanilla `Recovery` has no `SuccessfulParry` override, so
the late success cannot repair the state, and `Recovery` holds the player in lockout with
`bCanParry` disabled until the recovery animation ends.

Vanilla's `AOCMeleeWeapon.ParryRelease.OnStateAnimationEnd()` already handles the success
correctly *when `bSuccessfulParry` is set before the animation ends* — it goes to `Active` if the
parry succeeded and there is no hit-counter, to `Recovery` if it missed, to `Release` for a
riposte. The problem is purely that the flag arrives after that decision has been made.

**The previous attempt, and why it was reverted.** Commit `28a372a` overrode `ParryRelease` with a
grace timer: `OnStateAnimationEnd` set `SetTimer(0.15f, false, 'ParryGraceExpired')` instead of
dropping into `Recovery`, and `ParryGraceExpired` then chose `Active` or `Recovery`. It did repair
some late successes, but it did so by holding `ParryRelease` open longer, which extended the
active/parry-release phase for *every* parry. Parry-to-parry cadence got slower and the flow felt
worse. That commit was removed. The 0.15 s `ParryRelease` grace timer is a standing non-goal — it
is not to be reintroduced, and `ParryRelease.OnStateAnimationEnd()` is not overridden for this
bug.

**What ships instead.** The repair lives entirely in `Recovery`, in
`Classes/XangModMeleeWeapon.uc`, and creates no new timing window.

`var bool bAcceptLateParrySuccessInRecovery;` sits alongside the other parry timing vars
(`fServerParryStartTime`, `fParryGracePeriod`, `fDamageTraceActivationDelay`). It is armed in
`Recovery`'s `BeginState`, before `super`, and only for the exact transition that can lose the
race:

```uc
bAcceptLateParrySuccessInRecovery =
    PreviousStateName == 'ParryRelease'
    && CurrentFireMode == Attack_Parry
    && !bEquipShield;
```

`Recovery` then overrides `SuccessfulParry`. It returns immediately unless the flag is armed and
`bSuccessfulParry` is not already set — so a repeat or unrelated call does nothing. On the real
late success it disarms the flag, sets `bSuccessfulParry = true` and `bParryHitCounter = false`,
clears the owner's `OnAttackAnimEnd` timer (the recovery animation timer, which would otherwise
fire mid-repair), raises `OnActionSucceeded(EACT_Block)` so the defender gets normal block
feedback, and calls `GotoState('Active')`. `Active`'s own `BeginState` restores normal parry
behaviour and consumes any buffered parry input, so no part of the repair duplicates what the
state machine already does. Leaving `Recovery` clears the flag again, so the repair is never armed
outside that one transition.

**Why this is safer than the timer.** It only fires for a success notification that arrives *after*
the state machine has already gone `ParryRelease` → `Recovery`. It does not wait in
`ParryRelease`, does not extend the active parry window, does not change normal parry misses, and
explicitly excludes shields via `!bEquipShield`. The end state it forces — `Active` — is exactly
the state vanilla would have entered had `bSuccessfulParry` been set a few milliseconds earlier.

**The bounded risk.** If `SuccessfulParry` could be called in `Recovery` for some unrelated
reason, the repair would incorrectly skip recovery. The three-part guard is what keeps that from
happening: recovery must have come from `ParryRelease`, the current fire mode must be
`Attack_Parry`, and the weapon must not be a shield. Widening any of those — in particular letting
`Recovery` accept all parry successes — reopens that hole.

**Behaviour to preserve when touching this area.** A normal missed parry still plays full
recovery, with no speedup. A normal successful parry inside the window is unchanged. A very late
release parry lets the defender parry again immediately instead of waiting ~500 ms.
Parry-to-parry cadence matches the pre-`28a372a` feel, without the slower flow the 0.15 s timer
caused. Shield block and timed shield drop are unchanged.

### 5.3 Client-timestamp hit-trade arbitration and the clock offset

This layer postdates the original rollback design and answers a different question: when two
players connect at nearly the same moment, or when a parry and a hit arrive in ambiguous order,
whose action happened first? Everything here is in `Include/Pawn/Netcode.uci` unless noted.

**Getting the clients onto one timeline.** `GetOneWayPingSeconds` halves
`PlayerReplicationInfo.ExactPing` (which is round-trip, in seconds) and clamps the result to
`fMaxPlausibleLatency`, so a spoofed or garbage ping cannot push a reconstructed action time
arbitrarily far into the past. `UpdateClockOffset` runs on every stamped RPC: a stamp taken about
one one-way-ping ago on the client's clock should map to `now - oneWay` on the server, and the
difference is the offset. Samples are EMA-smoothed with `fClockOffsetAlpha` so per-message queue
jitter does not swing the estimate. `SeedClockOffset` carries a player's converged offset over
from their previous pawn (called from the player controller's `Possess`), so a respawn starts warm
instead of cold-starting into pure ping reconstruction. `ReconstructActionTime` maps a client
stamp onto the server timeline, falling back to `now - oneWayPing` when there is no usable stamp
or offset (bots, first message), and clamps the result so it can neither land in the server's
future nor be older than `fMaxPlausibleLatency`.

**The stamps themselves.** `ServerStampHitTime` and `ServerStampParryTime` are reliable server
RPCs on the pawn channel. The weapon attachment sends the hit stamp immediately before
`AttackOtherPawn` fires (reliable means ordered, so the stamp is there when the swing arrives);
`AttackOtherPawn` reads it through `ReconstructActionTime` and then zeroes it, so a later
stampless swing falls back to ping reconstruction instead of reusing a stale value.
`XangModMeleeWeapon.ActivateParry` sends the parry stamp from the locally controlled client;
`ServerStampParryTime` reconstructs it and records when it arrived. `GetParryActionServerTime`
returns that reconstructed parry moment when it is fresh, and otherwise falls back to
`now - oneWayPing`.

**Deciding a trade.** `RecordIncomingHit`, called from the end of `ProcessResolvedAttack` for real
enemy melee hits only, remembers on the victim that they took a hit and when (server timeline).
`PruneRecentIncomingHits` drops entries older than `fRecentHitTTL`. `ShouldCancelTradeSwing`,
checked near the top of `ProcessResolvedAttack`, returns true when this same opponent hit us — or
has a swing still *held* on us that will hit — more than `fTradeWindowSeconds` before our own
swing landed. Checking the held `PendingHits` as well as the recorded hits is what stops the
rollback hold from letting a staggered hit slip through disguised as a trade. Swings inside the
window still trade normally; only clearly staggered ones are dropped, and the player sees a
console notice when the hit-time debug display is on.

Exemptions are deliberate and narrow: projectiles, shoves, same-team hits, `bCheckParryOnly`
probes, and forced parries are never cancelled, and `IsRiposteAttack` (true when the weapon's
`bParryHitCounter` is set) exempts ripostes so a deliberate parry counter always lands.
`bEnableTradeCancellation` is the master toggle for the whole mechanism.

**The parry-vs-hit gate.** `ResolvePendingHitsAsParry` takes the parry's action time and only
resolves a held swing as a parry when the parry was not clearly later than the swing — the
allowance is `fParryTradeGraceSeconds`. A genuine block is up before or around the hit; a panic
parry fired well after the hit landed does not save the swing. Swings the parry was too late for
stay held and commit as normal hits when their hold expires, which is why the function removes
entries individually rather than clearing the array.

### 5.4 Parry grace period, parry buffer and riposte handling

These live in `Classes/XangModMeleeWeapon.uc` and interact with the above rather than being part
of it.

**Server parry grace period.** `Parry.BeginState` records `fServerParryStartTime` on authority
before calling `super`. `ProcessResolvedAttack` uses it: if the defender's replicated
`bIsParrying` / `bIsActiveShielding` booleans have not serialized yet but the defending weapon is
in state `Parry` and the elapsed time since `fServerParryStartTime` is within `fParryGracePeriod`,
the parry counts. This is the "through-parry" fix — it covers replication lag on the parry state
itself, and is separate from the latency hold in 5.1.

**Parry buffer.** `BeginFire` calls `BufferParryInput` when a parry is pressed while it cannot be
honoured (`!bCanParry`, or the weapon is in `Recovery` or `Deflect`), stamping
`fLastParryInputTime`. `HasBufferedParryInput` treats the input as live for `fParryBufferWindow`.
`TryActivateBufferedParry` clears the buffer and activates the parry if the owner's
`bCanParry` allows it; it is called from `Active.BeginState`, which is what makes the late-parry
repair in 5.2 feel seamless — the repaired transition into `Active` picks up the queued input
without any special case of its own. The equivalent calls in `Recovery` and the other states are
commented out; `Active` is the only live caller.

**Shields and riposte.** `Parry.BeginState` clears `bCanParryHitCounter` for shields *after*
`super`, because `AOCMeleeWeapon.Parry.BeginState` resets it to true; shields therefore get no
riposte. Shield parries are also routed through `ParryRelease` rather than vanilla
`ShieldUpIdle`, giving them the same timed window as weapons. `IsRiposteFlinchProtected` reports a
riposte flow (`bParryHitCounter` while in `ParryRelease` or `Release`) so flinch can be ignored
there. The pawn-side riposte grace period fields (`fLastParrySuccessTime`, `fRiposteGracePeriod`)
still exist but their use sites are commented out — the flinch-disable-after-parry window is not
currently active.

### 5.5 Where the two design notes disagree

Both notes were written as standalone handoffs and were not reconciled with each other; the
following are real conflicts, not wording differences.

- **They describe opposite halves of the same race and neither acknowledges the other.** The
  rollback note argues that holding a swing means a parry inside the window suppresses it cleanly,
  which implies the late-parry problem is handled at the pawn layer. The late-parry note documents
  that late successes still reach a weapon that has already left `ParryRelease`. Both are true:
  the hold is bounded by the defender's one-way ping and the cap, which is shorter than the
  `ParryRelease` → `Recovery` race the 5.2 repair covers. The two fixes are complementary, not
  alternatives, and the late-parry note's own closing risk section concedes this by pointing at
  `GetParryHoldSeconds` and `ResolvePendingHitsAsParry` as the next place to look if the recovery
  repair alone does not resolve the symptom.
- **`fParryGracePeriod` value.** The late-parry note reproduces the declaration comment as "75ms
  for RTT compensation"; the shipped default is 0.060 (60 ms). The comment is stale, not the code.
- **`fParryRollbackMaxHoldSeconds` value.** The rollback note specifies 0.060; the shipped default
  is 0.051. The shipped value is the one in effect.
- **Two different ping sources coexist.** `GetParryHoldSeconds` uses
  `PlayerReplicationInfo.Ping * 0.004` (UE3 stores ping as ms/4), while the timestamp layer's
  `GetOneWayPingSeconds` uses `ExactPing * 0.5` with a plausibility clamp. Nothing reconciles the
  two, and the hold length is therefore computed from a coarser, unclamped estimate than the trade
  arbitration it feeds.
- **Stale file references.** Both notes point at `Include/XangModPawn.uci` (and the late-parry note
  at line-numbered regions of it) for the pending-hit and parry-rollback path. After the refactor
  that code is in `Include/Pawn/Netcode.uci` and `Include/Pawn/Combat.uci`; the line numbers in
  both notes are meaningless.
- **Firebug ignition timing.** The rollback note's commit path ignites Firebug inline at the end of
  the hit; the shipped `ProcessResolvedAttack` defers it with a 0.25 s `DelayedFirebugIgnite`
  timer so the blunt impact sound is not drowned out by the fire scream.

---

## 6. First-person spectate

Status: **implemented**. This section describes what shipped, why it is built the
way it is, and what to test. The vanilla-engine background in 6.2 and 6.3 is
unchanged and is still the reference for anyone touching this code.

### 6.1 Where the code lives

| File | What it holds |
|------|---------------|
| `XangMod/Include/PC/Spectate.uci` | `XangModLogCameraState`, `XangModFixCameraAfterSpawn`, `ClientRestart`, `XangModFPObserveBlocker`, `XangModCanFPObserve`, `XangModApplyFPObserve`, `XangModClearFPObserve`, `XangModRestoreVanillaCamera`, `XangModMayView`, `XangModNoteViewBlock`, `XangModApplySpectatorPerspective`, `XangModEnforceLifeBars`, `XangModEnforceLifeBars`, `XangModEnforceSpectateFOV`, the `FirstPersonSpectate` and `FPSpectateDebug` execs, and the `state Spectating` override |
| `XangMod/Include/Pawn/Camera.uci` | Pawn-side camera code: `SetThirdPersonCamera`, `XangModEnsureOwnerMesh`, `BecomeViewTarget`, `XangModCanUseCameraSocket`, `GetCameraSocketLocationAndRotation`, `XangModAimRotation`, `XangModEyeViewPoint` |
| `XangMod/Include/Pawn/Customization.uci` | `XangModStock1PMesh` and `SetCharacterAppearance` |
| `XangMod/Include/XangModHUD.uci` | `DrawHUD` override + `XangModDrawSpectatorTarget` / `XangModGetFactionColor` (the followed player's name and class) |

`Include/XangModPawn.uci` and `Include/XangModPlayerController.uci` still exist,
but they are now thin facades that just `include` the feature files above. The
includes are pulled into every XangMod player-controller / pawn / HUD subclass,
so this is effectively a shared override of `AOCPlayerController`, `AOCPawn` and
`AOCBaseHUD`.

The old commented-out block (the two `Client*SpectatorHead` RPCs and the previous
`state Spectating`) has been removed. None of it was needed — see 6.4.

### 6.2 Vanilla AOC behavior (unchanged reference)

#### 6.2.1 How you get into spectate

- `AOCPlayerController.JoinSpectatorTeam()` → `GenericSwitchToObs(true, true)`
  → `ClientGotoState('Spectating')` + `ServerSpectate()`.
- XangMod also exposes `AdminForceSpectate` / `AdminForceSpectateAll`, which call
  `Target.JoinSpectatorTeam()`.

#### 6.2.2 The input chain for "left click follows a player"

From `UDKGame/Config/DefaultInput.ini`:

```
.Bindings=(Name="LeftMouseButton",Command="GBA_SprintAttack|GBA_Fire|GBA_SpectatorNext",...)
.Bindings=(Name="GBA_SpectatorNext",Command="SpectatorNext")
```

Left click, while spectating, runs the `SpectatorNext` **state** function on
`AOCPlayerController` (line 5053), which calls `ServerViewNextPlayer()` →
`ViewAPlayer(+1)` **on the server**.

`AOCPlayerController` overrides `ViewAPlayer` (line 5098) and this is the line
that forced third person:

```unrealscript
function ViewAPlayer(int dir)
{
    super.ViewAPlayer(dir);
    if(ViewTarget != none)
    {
        SetReality(ViewTarget.RealityID);
        SetBehindView(true); // <-- refresh behindview on new pawn (3RD PERSON)
    }
    ClientSetViewTarget(ViewTarget);
}
```

Because this runs server-side (no `LocalPlayer`), `UTPlayerController.SetBehindView`
turns it into a `ClientSetBehindView(true)` RPC, so the *client* is dragged back
into third person on every single target change.

#### 6.2.3 Other bound spectator keys

| Input | Command | Effect |
|-------|---------|--------|
| Left click | `SpectatorNext` | Follow next player |
| `F` | `SpectatorPrevious` | Follow previous player |
| Right click | `SpectatorFreecam` | `SetViewTarget(none)` + `ServerViewSelf()` |
| Space | `SpectatorPerspective` | `BehindView()` — an **empty stub** in vanilla's state |
| Mouse wheel | `SpectatorZoomIn/Out` | Zoom |

### 6.3 How first-person view actually works in this engine

#### 6.3.1 `UsingFirstPersonCamera` / `IsFirstPerson`

`UTPlayerController.UsingFirstPersonCamera()` returns `!bBehindView`
(`UTPlayerController.uc:1791`). `UTPawn.IsFirstPerson()` (`UTPawn.uc:4595`)
returns true when some local player controller has `ViewTarget == self` **and**
`UsingFirstPersonCamera()`. So `bBehindView == false` is what makes the pawn
render/calc in first person.

#### 6.3.2 `AOCPlayerCamera.UpdateCamera` picks the FP socket

`AOCPlayerCamera.uc` lines 70–88:

```unrealscript
if (((OwnerPawn.IsLocallyControlled() && !OwnerPawn.bIsBot) || OwnerPawn.bIsBeingFPObserved) && OwnerPawn.Health > 0)
{
    OwnerPawn.GetCameraSocketLocationAndRotation(true, CameraLocation, CameraRotation);
    CameraRotation.Roll = 0;   // <-- FP path zeroes roll
}
else
{
    OwnerPawn.GetCameraSocketLocationAndRotation(false, CameraLocation, CameraRotation);
}
```

`GetCameraSocketLocationAndRotation(true, ...)` reads `CameraSocket` off the
**first-person `OwnerMesh`**; `false` reads it off the **third-person `Mesh`**.

**`bIsBeingFPObserved` is the master switch.** It also gates the OwnerMesh
animation tree (`AOCPawn.uc` 5189, 5300, 5321, 5348, 5369, 5614), the FP overlay
weapon, `HelmetEmitter` visibility (9208), and the health/stamina HUD push (9140).
Torn Banner built the whole observer path; they just never wired input to it.

#### 6.3.3 `BecomeFirstPersonObserved` flips the pawn into FP mode

`AOCPlayerController.state Spectating.SetBehindView(false)` (line 5129) is the
only thing that calls `AOCPawn.BecomeFirstPersonObserved()`. That is why the
implementation goes through `SetBehindView(false)` rather than assigning
`bBehindView` directly.

#### 6.3.4 `GetPlayerViewPoint` FP branch

`AOCPlayerController.GetPlayerViewPoint` (line 5165, inside `state Spectating`):

- `bFreeCamera == true` → free/orbit camera (this is also what vanilla "3rd
  person follow" actually is)
- `bFreeCamera == false && bBehindView == true` → offset-back follow
- `bFreeCamera == false && bBehindView == false` → first-person follow:
  `POVRotation = RInterpTo(CalcViewRotation, TempPOVRot, DeltaTime, 20.0f)`

### 6.4 What is implemented

#### 6.4.1 Route target changes through the real FP-observer path

`state Spectating.ViewAPlayer` is overridden and **deliberately does not call
`super`**. It reproduces the useful half of vanilla (`GetNextViewablePlayer` →
`SetViewTarget` → `SetReality` → `ClientSetViewTarget`) and drops the
`SetBehindView(true)` force. The client then picks its own perspective inside
`ClientSetViewTarget`, which is the correct client-side hook for "the view target
changed".

#### 6.4.2 Fix vanilla's own call-order bug

`SetBehindView(false)` in the spectating state runs:

```
super.SetBehindView(false)          -> bBehindView = false, bFreeCamera = false,
                                       ViewTarget.SetThirdPersonCamera(false)
AOCPawn.BecomeFirstPersonObserved(self)
    -> BecomeViewTarget(self)
        -> SetThirdPersonCamera(!bIsBeingFPObserved)   // still false here, so this
                                                       // re-runs as SetThirdPersonCamera(TRUE)
    -> bIsBeingFPObserved = true, swap OwnerMesh, attach 1P weapon
```

So vanilla ends with the pawn flagged for a first-person **camera** but still in
third-person **visuals**: 3P body drawn, helmet on, 1P mesh hidden. That is what
"seeing inside their head" was. `XangModApplyFPObserve` calls
`P.SetThirdPersonCamera(false)` immediately afterwards to put the meshes back
into 1P state.

**Consequence: the head-hiding RPCs are gone.** `SetThirdPersonCamera(false)`
already does `Mesh.SetOwnerNoSee(true)` + `HelmetMeshComp.SetOwnerNoSee(true)`,
which is both correct and per-view-target (these components are declared
`bOwnerNoSee` / `bOnlyOwnerSee` in `AOCPawn` defaultproperties), so nothing leaks
onto other players or persists after switching away.

#### 6.4.3 The tilt bug is fixed for free

Because `bIsBeingFPObserved` is now actually set, `AOCPlayerCamera.UpdateCamera`
takes its FP branch and executes its existing `CameraRotation.Roll = 0`. The
sprint-lean roll (`AOCSprintLeanNode`, `Shift+W+A` / `Shift+W+D`) never reaches
the spectator's POV.

The old fix attempt zeroed the **controller's** `Rotation.Roll`, but the POV comes
from the observed pawn's camera socket (`TempPOVRot`), not from controller
rotation — which is why it did nothing.

#### 6.4.4 Feed the 1P aim offset

`AOCPawn.FaceRotation` (line 5611) is the only thing that copies
`AimNode.Aim` → `OwnerAimNode.Aim`, and `FaceRotation` only runs for a locally
controlled pawn (`PlayerController.UpdateRotation` / `ProcessMove`). For a pawn we
are merely observing it never fires, which would leave the 1P mesh — and therefore
the camera socket — refusing to pitch with the observed player's aim.

`state Spectating.PlayerTick` re-copies it every frame while
`bIsBeingFPObserved`. **If a future engine-side change makes this redundant it can
be deleted safely; it is a defensive copy, not load-bearing.**

#### 6.4.5 Perspective toggle

- First person is the default (`bXangModFPSpectate = true`, set in `PostBeginPlay`
  so the choice survives re-entering spectate).
- **Space** (`SpectatorPerspective`, and `BehindView` which routes to it) flips
  between first person and the vanilla orbit follow.
- **Right click** (`SpectatorFreecam`) still detaches to free camera.
- `FirstPersonSpectate <bool>` is a console exec for anyone who wants to default
  to the orbit follow.

Important gotcha handled here: `UTPlayerController.SetBehindView(false)` also sets
`bFreeCamera = false`, and `state Spectating.PlayerMove` early-outs on
`!bFreeCamera` *before* `UpdateRotation()`. Leaving first person therefore has to
call `SetBehindView(true)` to hand `bFreeCamera` back, otherwise the free camera
is frozen and cannot even look around. Both exit paths (`SpectatorFreecam` and the
"no live target" branch of `XangModApplySpectatorPerspective`) do this.

#### 6.4.6 Spectator HUD

**Health / stamina.** `AOCPlayerController.PlayerTick` already pushes
`AOCPawn(ViewTarget).Health / .Stamina` into the HUD when we have no pawn of our
own (line 3667), and `ReplicatedStamina` is in `AOCPawn`'s general replication
block, so the values reach every client. What was missing was visibility:
`DisplayCompleteHUD()` is only called from `ShowHUDElements()` on possession, so
somebody who joined straight into spectate never had the bars turned on.
`XangModEnforceLifeBars` calls it on target change and resets
`PreviousHealth` / `PreviousStamina` to `-1` to defeat the change filter so the
new target's values push immediately.

**Name / class.** Drawn by `XangModDrawSpectatorTarget` in
`Include/XangModHUD.uci` (centred, ~88% down the screen, tinted by faction, with a
drop shadow).

Why not the vanilla sub-crosshair info box: `AOCBaseHUD.DrawHUD`'s spectator
branch does support it (`bOverrideSubXhair` / `OverrideText`, lines 679–685), but
a few lines later the same branch unconditionally calls
`ShowInfomationBox(false)` whenever `GetViewName()` fails to resolve a player
under the crosshair — which is the normal case while first-person spectating. So
the readout is drawn directly instead of fighting that.

The faction colour reads `AOCPRI.MyFamilyInfo.FamilyFaction` directly rather than
`AOCPRI.GetCurrentTeam()`, because that function dereferences `Team` without a
none-check on its bot branch.

#### 6.4.7 None-safety

`XangModCanFPObserve` gates every apply/clear. It checks everything
`BecomeFirstPersonObserved` and `SetThirdPersonCamera` dereference without their
own none-checks (`OwnerMesh`, `CharacterAssetStore`, `HelmetMeshComp`,
`HelmetEmitter`, `ShieldMesh`, `OverlayShieldMesh`, the
`AOCWeaponAttachment(CurrentWeaponAttachment)` **cast**, and that attachment's
`Mesh`). This matters because `PlayerTick` retries every frame, so an unguarded
apply would turn one partially-replicated target into per-frame "Accessed None"
spam.

#### 6.4.8 The stripped 1P mesh (post-release fix)

First testing on a dedicated server showed the view never leaving third person.
Cause: `AOCPawn.SetCharacterAppearance()` (`AOCPawn.uc` ~11890) **destroys** the
first-person `OwnerMesh` on any pawn that was not locally controlled at the moment
it loaded its character assets:

```unrealscript
if( IsLocallyControlled() || bIsBeingFPObserved )
{
    ... OwnerMesh.SetAnimTreeTemplate(...);
    ... OwnerMesh.SetSkeletalMesh( AssetStore.OwnerMesh );
}
else if(Worldinfo.NetMode != NM_DedicatedServer || Controller != none)
{
    DetachComponent(OwnerMesh);
    OwnerMesh = none;
}
```

That runs at spawn, long before anybody spectates, so `bIsBeingFPObserved` is
always false there. `BecomeFirstPersonObserved()` then does
`OwnerMesh.SetSkeletalMesh(...)` on a null component and the whole FP path is
dead on arrival.

Who is affected — this is **not** bot-specific:

| Setup | 1P mesh survives? |
|-------|-------------------|
| Your own pawn | Yes |
| Host (listen/standalone) watching a **bot** | Yes — server-side AI controllers count as locally controlled |
| Client watching a bot | **No** |
| Anyone watching a remote human on a dedicated server | **No** |

The 1P skeletal mesh **asset** is fine: `LoadCharacterAssets()` fetches
`OwnerMeshPath` into `CharacterAssetStore.OwnerMesh` on every non-dedicated client
with no locally-controlled gate. Only the component is missing.

**Fix:** `XangModEnsureOwnerMesh()` in `Include/Pawn/Camera.uci` rebuilds the
component from the class-default archetype
(`new(self) class'SkeletalMeshComponent'(default.OwnerMesh)`), re-applies the anim
tree, anim sets, skeletal mesh and materials in the same order
`SetCharacterAppearance()` uses, and verifies that `OwnerAimNode` /
`OwnerBlendAnimationListNode` got bound — vanilla relies on
`SetAnimTreeTemplate()` firing `PostInitAnimTree(OwnerMesh)` to populate those,
and there is no other call site that assigns them. If they come back none the
rebuild is reverted so the spectator stays in a clean third person rather than
looking at a static ref-pose.

It is driven from the `BecomeViewTarget` override in `Include/Pawn/Camera.uci`,
which fires from the native `SetViewTarget` inside
`PlayerController.ClientSetViewTarget` — exactly one step ahead of where
`XangModApplySpectatorPerspective()` runs on the controller. Rebuild cost is one
component + anim-tree init per pawn, once, cached for that pawn's lifetime.

#### 6.4.9 Always establish a camera state (post-release fix)

`state Spectating.ViewAPlayer` deliberately drops vanilla's
`SetBehindView(true)` on every target change (see 6.4.1). That means XangMod is now
solely responsible for setting the camera state, and the original
`XangModApplySpectatorPerspective()` did not hold up its end:

```unrealscript
if (bXangModFPSpectate)
    XangModApplyFPObserve(P);   // silently no-ops if the guard fails
else
    { XangModClearFPObserve(); SetBehindView(true); }
```

When `XangModApplyFPObserve` bailed on its none-guard -- which, before 6.4.8, was
**every single pawn on a client** -- neither branch touched `bBehindView` or
`bFreeCamera`. The controller ran on whatever those flags happened to be left at,
with nothing ever refreshing them. `state Spectating.PlayerMove` early-outs on
`!bFreeCamera` before `UpdateRotation()`, so a stale `false` there means a camera
that neither follows anybody nor accepts input.

Fix: `XangModApplyFPObserve` now returns whether it succeeded, and
`XangModApplySpectatorPerspective` falls through to an explicit
`SetBehindView(true)` when first person is not available -- so a definite camera
state is always established, exactly as vanilla guaranteed.

`XangModPerspectivePawn` tracks the pawn we have already settled on, so the
fallback runs once per pawn rather than every frame, while first person is still
cheaply retried in case the 1P mesh only becomes rebuildable after the pawn's
character assets finish streaming.

**Rule of thumb for this code: if you remove a vanilla call, you own everything it
was doing.**

#### 6.4.10 Rebuilt-component gotchas

Three things a second review caught in the 6.4.8 rebuild, all worth remembering if
anyone ever script-instances a component in this codebase:

- **`new(self) class'X' (Template)` is a plain property copy — it does NOT run
  component instancing.** The `LightEnvironment` pointer it copies still refers to
  the class-default `MyLightEnvironment` subobject, which is not registered in the
  world, so the rebuilt 1P mesh renders unlit (black). Fixed with
  `OwnerMesh.SetLightEnvironment(Mesh.LightEnvironment)` right after
  `AttachComponent`, mirroring `AOCWeaponAttachment.uc:258`.

- **The rebuild only fires from the pawn's `BecomeViewTarget`,** i.e. once per
  view-target change. If the pawn's character assets had not finished streaming at
  that moment, `CharacterAssetStore.OwnerMesh` is none, the rebuild bails, and
  nothing would ever try again — the "retry" in `PlayerTick` was a permanent no-op
  because it only re-checked a component that only that hook creates. `PlayerTick`
  now re-pokes `P.BecomeViewTarget(self)`, rate limited to twice a second via
  `fXangModNextFPRetry`.

- **`AOCPlayerController.state Spectating.SetBehindView` dereferences
  `AOCGRI(WorldInfo.GRI)` unguarded**, and that is reachable the instant a joining
  client enters spectate, before the GRI has replicated.
  `XangModRestoreVanillaCamera()` guards it and sets the flags directly in that
  window.

Still unverified by reading alone: whether the engine's native component attach
fires `PostInitAnimTree` for a script-`new`'d `SkeletalMeshComponent`. The
`OwnerAimNode == none` check in `XangModEnsureOwnerMesh` is the hedge — if it does
not fire, the rebuild reverts itself and you stay in a clean third person rather
than looking at a frozen ref-pose. The log line it emits says which happened.

#### 6.4.11 Post-spawn camera correction (post-release fix)

The camera-stranded-on-spawn bug survived 6.4.9 through 6.4.12. Reading
`Engine.PlayerController.ClientRestart()` (PlayerController.uc:4728) rather than
assuming its order explains why — on a client it runs:

```unrealscript
Pawn = NewPawn;
AcknowledgePossession(Pawn);
Pawn.ClientRestart();
if (Role < ROLE_Authority)
{
    SetViewTarget(Pawn);   // still inside state Spectating
    ResetCameraMode();     // no-op unless PlayerCamera exists
    EnterStartState();     // only NOW do we leave Spectating
}
```

Note `Role < ROLE_Authority` — **this whole block is skipped on a listen-server
host**, which is another reason host testing cannot reproduce it.

Two consequences:

1. `SetViewTarget(Pawn)` fires `AOCPawn.BecomeViewTarget()` while the controller is
   *still* in `state Spectating`, so it takes its spectator branch
   (`CurrentObserver = PC; SetThirdPersonCamera(...)`) and never calls
   `super.BecomeViewTarget()`. UTPawn's real possession-view setup — arms attach,
   `SetMeshVisibility(bBehindView)`, `bUpdateEyeHeight = true` — is skipped for your
   own pawn.

2. `PlayerController.GetPlayerViewPoint` reads the view **straight off
   `PlayerCamera`** and ignores `Pawn`/`ViewTarget` entirely whenever one exists.
   The only place AOC destroys it is the non-`CameraActor` branch of
   `state Spectating.GetPlayerViewPoint`, so leaving spectate while one is alive
   strands the view wherever that camera actor sits — a fixed spot on the map, with
   the pawn playing normally underneath. `ResetCameraMode()` cannot rescue this:
   `PlayerController.SetCameraMode()` does nothing at all when `PlayerCamera` is
   None, and only sets `CameraStyle` when it is not.

Rather than fight that ordering, `ClientRestart` is overridden to schedule
`XangModFixCameraAfterSpawn()` on a 0.05s timer. Once the transition has actually
completed it destroys any surviving `PlayerCamera`, clears `bFreeCamera`, clears
the FP-observer flags off our own pawn, forces the view-target transition to
re-run (`SetViewTarget(none)` then `SetViewTarget(Pawn)`) so `BecomeViewTarget`
takes its normal branch this time, and puts the controller's own location back on
the pawn.

**This is a corrective, not a root-cause fix** — it re-asserts the right state
instead of preventing the wrong state. It also logs, via `LogAlwaysInternal`, one
line before and one line after correcting:

```
[XangModFPSpec] post-spawn State=PlayerWalking Pawn=... ViewTarget=... PlayerCamera=... bBehindView=... bFreeCamera=... PCLoc=...
[XangModFPSpec] post-spawn-corrected ...
```

Read the *first* line to identify the real cause:

- `PlayerCamera=` anything but `None` → cause (2), and the correction handles it.
- `ViewTarget=` not your own pawn → cause (1) or a stale spectator target.
- `bFreeCamera=True` → the controller still thinks it is a free camera.
- `State=` still `Spectating` → the client never left the state at all, which would
  be a different bug again.

#### 6.4.12 Diagnostic

`FPSpectateDebug` (console exec, `Include/PC/Spectate.uci`) works in **any**
state, not just while spectating, and dumps: current state name, netmode, `Pawn`,
`ViewTarget`, `RealViewTarget`, `PlayerCamera`, the perspective flags, both pawn
trackers, then -- if the view target is a pawn -- `bIsBot` / `IsLocallyControlled`,
`bIsBeingFPObserved`, the `OwnerMesh` component, `OwnerAimNode`, the asset store
and its 1P mesh asset, every component `XangModCanFPObserve` gates on, and the
final verdict.

Signatures to look for:

- `OwnerMesh (1P component): None` -- the stripped 1P mesh, 6.4.8.
- `PlayerCamera:` anything other than `None` during normal play -- the engine is
  reading the view straight off a `Camera` actor and ignoring `Pawn` / `ViewTarget`.
- `ViewTarget is not our own Pawn while we have one` -- the frozen-camera
  signature: the pawn is alive and taking input while the view is somewhere else.

**Script logging does not work in this build.** The client log
(`Documents\My Games\Chivalry Medieval Warfare\UDKGame\Logs\Launch.log`) contains
zero `ScriptLog` lines — script output is suppressed in the shipping build, so
`LogAlwaysInternal` never appears. `XangModLogCameraState` is therefore inert here;
use the `FPSpectateDebug` exec instead, which goes through
`ClientDisplayConsoleMessage` and renders in game.

#### 6.4.13 Do not clear the HUD on leaving spectate (post-release fix)

First build regressed health/stamina in **actual play**: a player's bars were
missing for their whole first life after joining.

`state Spectating.EndState` was calling `AOCBaseHUD.ClearHUDOnDeath()`
unconditionally. The spawn sequence is:

1. server `AOCPlayerController.Possess()` -> `ShowHUDElements()` (reliable client RPC)
   -> `DisplayCompleteHUD()` -> life bars **on**
2. server -> `ClientRestart(Pawn)` (reliable client RPC) -> `Pawn = NewPawn` ->
   `EnterStartState()` -> `EndState('Spectating')`

Both are reliable, so step 1 always lands first and the `EndState` hook then
re-hid the bars, the crosshair and the ammo count. Nothing calls
`DisplayCompleteHUD()` again until the next `Possess()`, i.e. the next respawn --
hence "no bars until you die once". `SetHealthValues()` kept updating the widget
the whole time, it was just invisible, which is why it looked like a data problem
rather than a visibility one.

Fix: guard on `Pawn == none`. `Engine.PlayerController.ClientRestart()` assigns
`Pawn` before `EnterStartState()`, so a non-none `Pawn` at `EndState` reliably
means "we are spawning -- leave the HUD alone". Leaving spectate without a pawn
still tidies up.

Worth remembering generally: this state is also the parent of
`state SpecialSpectating`, and it is the state players sit in during team/class
select -- anything done in its `BeginState`/`EndState` runs far more often, and in
more situations, than "somebody pressed spectate".

### 6.5 Test plan

Camera:

- [ ] Left click follows the next player **in first person**, no third-person flash.
- [ ] `F` follows the previous player in first person.
- [ ] Space toggles first person ↔ orbit follow, both directions, repeatedly.
- [ ] Right click drops to free camera **and the free camera can move and look around**
      (this is the `bFreeCamera` regression guarded against in 6.4.5).
- [ ] Space while in free camera does nothing (no target to toggle).
- [ ] The followed player's own body/helmet is not visible from inside their head.
- [ ] After switching from A to B, player A looks normal again (3P body, helmet on,
      no floating 1P mesh).

Tilt (the original bug):

- [ ] Tracked player holds `Shift+W+A` → **no camera roll**.
- [ ] Tracked player holds `Shift+W+D` → **no camera roll**.

Aim:

- [ ] Tracked player looks up/down — the spectator view pitches with them.
- [ ] Tracked player attacks — the view shows the normal Chivalry first-person
      attack camera motion and the 1P weapon.

Lifecycle:

- [ ] **Leave spectate and spawn: the camera follows your own pawn, you can move
      and look, and the HUD is intact.** (6.4.9 / 6.4.11 / 6.4.13 — this is the one that broke.)
- [ ] Spawn, die, respawn, spectate, spawn again — camera correct every time.
- [ ] Tracked player dies → auto-advance to the next player still works, and the
      new target comes up in first person.
- [ ] Tracked player dies with nobody left alive → no stuck/frozen camera.
- [ ] Tracked player respawns while followed → first person re-applies to the new pawn.
- [ ] Leaving spectate (joining a team, spawning) restores the normal HUD and camera.

HUD:

- [ ] **Join a server, pick a team, spawn: health and stamina bars are visible on the FIRST life.** (6.4.13)
- [ ] Crosshair and ammo count also survive that first spawn.
- [ ] Health and stamina bars show the **followed player's** values and update live.
- [ ] Bars appear for a client who joined straight into spectate (never possessed a pawn).
- [ ] Bars hide in free camera and when the target dies.
- [ ] Name + class readout shows, tinted by team, and updates on target change.
- [ ] Nothing draws when not spectating.

Networking (this is where 6.4.8 bit -- do not sign off on host-only testing):

- [ ] All of the above **on a dedicated server**, as a connected client.
- [ ] `FPSpectateDebug` reports a non-None `OwnerMesh` and `CanFPObserve: True` for a remote player.
- [ ] Watching a **bot** from a client (not just from the host) goes first person.
- [ ] Two spectators following the same player at once — neither one's mesh state
      affects the other or the player being watched.

### 6.6 Notes / open items

- **The "camera stranded on spawn" bug was never a spectate bug.** Commit `ed572f9`
  (2026-07-21) renamed 26 asset references across 14 `XangModCharacterInfo_*`
  classes to a package `XangmodCharacters` that was never created. Those classes —
  Knight and Vanguard in every variant, plus BARB Archers — therefore had no
  first-person mesh. `AOCPlayerCamera.UpdateCamera()` reads the camera position
  from a socket on that mesh, and `GetSocketWorldLocationAndRotation` returns
  **without writing its output** when the mesh is NULL, so `CameraLocation` keeps
  whatever it last held. Coming out of spectate that is the spectator camera
  position, hundreds of metres away; in an ordinary respawn it is your own last
  position, which is why it read as harmless jitter for a month.
  Confirmed by test: Archer and MAA fine, Knight and Vanguard broken. Reverted to
  `SlumpCharacters` (the package that actually ships) on 2026-08-21.
  Diagnostic signature in `Launch.log`:
  `Error: Failed to find package for MP character class ...` immediately followed
  by a flood of `Warning: GetSocketWorldLocationAndRotation : Could not find SkeletalMesh`.
- `MasonBarbVanguard1p` does not exist in `SlumpCharacters.upk` either (only a `3p`
  version), so BARB Mason Vanguard still has no 1P mesh and will show this same
  frozen-camera behaviour until the asset is authored.
- No mod content package appeared in a 14 MB client log — no `SlumpCharacters`,
  `TurtleFFA`, `crown` or any other. Untested, but worth confirming content
  actually reaches clients.
- The "bodycam" feel of the previous attempt was a symptom of never setting
  `bIsBeingFPObserved`: the camera was reading the **third-person** mesh's camera
  socket, which carries the full-body locomotion and lean animation. The 1P
  `OwnerMesh` socket is the one the game uses when you play normally. If it still
  reads wrong after this change, the next lever is the smoothing constant in
  `AOCPlayerController.state Spectating.GetPlayerViewPoint`
  (`RInterpTo(CalcViewRotation, TempPOVRot, DeltaTime, 20.0f)`), which XangMod can
  override in its own state if needed.
- `NextCameraAngle` is a no-op in first person and sets `iThirdPersonAngle = 1` in
  orbit follow, matching vanilla. If real cycling is ever wanted, the values live in
  `AOCPlayerController.ThirdPersonCameraPositions` and are consumed by
  `AOCPlayerCamera.CalcThirdPersonLocation`.
- Status as of 2026-08-21: the 1P mesh rebuild (6.4.8) is **confirmed working on a
  dedicated server** — `ScriptLog: XangModEnsureOwnerMesh: rebuilt 1P mesh
  SK_CH_1P_MAsonArcher` in the client log. First-person spectate is functional on
  any class whose 1P mesh actually loads.

---

## 7. RCON protocol

Server side: `Src\XangMod\Classes\XangModRCon.uc` (extends `AOCRCon`), spawned by the
`InitRemoteConsole` override in `Include/Game/Server.uci`. `Classes/XangModRConSession.uc`
extends `XangModRCon`, so it inherits every opcode constant and handler described here; the
RCON implementation itself is unchanged by the include refactor.

**Status: limited testing in a development environment.** Tournament controls, loadout,
freeze, bans, map and the fun commands have been exercised on a live server; the fixes
made in response are noted per opcode below. Nothing has been load-tested.

### Where the supporting code lives

The game-side includes were split. `Include/XangModGame.uci` still exists but is now a thin
facade that includes the files below.

  * `Include/Game/Server.uci` -- the `InitRemoteConsole` override that spawns the RCON
    actor, and the seamless-travel actor list.
  * `Include/Game/RoundReporting.uci` -- the round-boundary reporting functions:
    `XangModRoundReportingEnabled`, `XangModRoundTeamIndex`, `XangModRoundMapName`,
    `XangModRoundWinnerTeamIndex`, `XangModRoundScores`, `XangModSendRoundEnd`,
    `XangModSendRoundStats`.
  * `Include/Game/Match.uci` -- match lifecycle: `StartMatch`, `StartRound`, `AOCEndRound`,
    `EndGame`, and tournament mode.

### Why this exists

The ChivAdmin desktop client already speaks opcodes 0-28. Opcodes 0-22 match
`AOCRCon.uc`'s `MessageType` enum exactly, in order. **Opcodes 23-28 exist only in the
client** -- its Java classes for them are marked `implements CustomChivEvent`, whose
javadoc says "for non-vanilla CMW messages sent from the server. This is the case when
the 'ChivAdmin' mod is installed." That mutator was never published.

So implementing 23-28 makes an **unmodified ChivAdmin client** work against a XangMod
server. Every layout below was read off the client's own encoders/decoders, not guessed.

### Wire format (unchanged from vanilla)

Big-endian. `AOCRConPacket` provides:

    AddInt / GetInt        4-byte big-endian int
    AddString / GetString  4-byte length prefix, then UTF-8 bytes
    AddQWord / GetGUID     8-byte Steam ID
    SetMessageType(int)    takes a plain int, so custom opcodes need no enum change

Auth is untouched: challenge string, 50-byte password packet, `RCON_Connecting` ->
`RCON_Connected`. `XangModRCon.HandleMessage` checks `RCON_Connected` before dispatching
anything extended, so an unauthenticated peer reaches none of it.

### Opcodes

`in` = client to server. `out` = server to client.

#### 0-22 -- vanilla, handled by AOCRCon, untouched

SERVER_CONNECT, SERVER_CONNECT_SUCCESS, PASSWORD, PLAYER_CHAT, PLAYER_CONNECT,
PLAYER_DISCONNECT, SAY_ALL, SAY_ALL_BIG, SAY, MAP_CHANGED, MAP_LIST, CHANGE_MAP,
ROTATE_MAP, TEAM_CHANGED, NAME_CHANGED, KILL, SUICIDE, KICK_PLAYER, TEMP_BAN_PLAYER,
BAN_PLAYER, UNBAN_PLAYER, ROUND_END, PING

One exception: **UNBAN_PLAYER (20) is intercepted** by `XangModRCon.HandleUnbanFixed`
before it reaches `super`. Vanilla's `AOCAccessControl.UnbanByUID` removes the entry
from the in-memory `Bans` array and stops -- it never calls `SaveConfig()`, while
`AddBan` does, so the ban is still sitting in the ini and comes back on the next server
start. The interception does the same removal, calls `SaveConfig()`, and audits whether
anything actually matched (vanilla's version was silent either way).

#### 23-28 -- ChivAdmin parity, implemented here

| # | Name | Dir | Payload |
|---|------|-----|---------|
| 23 | PING_EXTENDED | out | qword uid, int ping, score, idleTime, kills, teamDamageDealt, rank |
| 24 | CHANGE_SCORE | in | qword uid, int score |
| 25 | KILL_PLAYER | in | qword uid |
| 26 | INEBRIATE | in | qword uid |
| 27 | CHANGE_GAME_PASSWORD | in | string password |
| 28 | CONSOLE_COMMAND | in | qword uid, int scope, string command |

Scope: `0` = game, `1` = that player, `2` = all players.

Opcode **23 overrides `GameEvent_UpdatePing`**, it does not add a new hook. That is the
only ping entry point the game calls (`AOCPlayerController.uc:8446`); `AOCRCon` is native
and exposes nothing else, so a separately-named "extended" function would never run. It
replaces vanilla opcode 22 rather than sitting alongside it, matching what the ChivAdmin
mutator did, and the field order is theirs: uid, ping, score, idleTime, kills,
teamDamageDealt, rank. `AOCPRI.IdleTime` is a byte of quarter-scale seconds
(`AOCPRI.uc:558`), so it is multiplied by 4 on the way out and saturates at 1020s.

**23 is written but not wired.** Vanilla drives plain PING from
`GameEvent_UpdatePing`; hooking the extended one needs a decision on how often to emit a
packet per player. `idleTime` and `rank` are sent as 0 -- nothing in `AOCPRI` or
`PlayerReplicationInfo` tracks either, and inventing values would be worse than the gap.

Opcode **48 (SOBER_PLAYER)** is XangMod-only and undoes 26. ChivAdmin's Inebriate carries
only a UID and is one-way; 26 is left wire-compatible with that rather than growing a flag.

#### 49-50 -- tournament control

  * **49 SET_TOURNAMENT** `int enabled, int thresholdPercent (0 = leave)`
    Disable also clears `class'AOCGame'.default.bTournamentMode` and saves. `bTournamentMode`
    is globalconfig and InitGame re-reads it every map (AOCGame.uc:3337), so a runtime-only
    clear lets the mode come back after a map change and re-brick the pre-round. Enable is
    runtime-only on purpose.
  * **50 READY_ALL** `int ready (1 = ready all, 0 = clear all)`

**XangMod deliberately disabled vanilla's own tournament command.** `Include/Game/Match.uci`
carries `// Deprecated` and an empty `function AdminTournamentMode(bool bEnable){}`, which
neuters `AOCGame.AdminTournamentMode` -- and that is no loss, because the vanilla version
writes the flag to config with `SaveConfig` and then calls
`WorldInfo.ServerTravel("?restart")`. In other words the in-game `AdminTournamentMode`
command does nothing on a XangMod server, and opcode 49 is not a duplicate of it but the
only working way to toggle the mode. Do not "restore" the vanilla behaviour without asking:
a map restart per toggle is exactly what was removed.

`bTournamentMode` gates `AOCGame.ShouldStartRound` (AOCGame.uc:3062), holding the pre-round
until each team reaches `TournamentTeamReadyThreshold` or `bAdminForcedTournamentReady` is
set. Two things the client has to state rather than hide:

  * It only bites during the pre-round.
  * **`StartRound` clears it** (AOCGame.uc:3099). TB's comment there says it "can't persist
    (since LTS reenters preround)", so it is one-shot per round start. Vanilla behaviour,
    not a bug to work around.

Opcode 49 also applies the side effects vanilla applies at InitGame when the mode is on
(AOCGame.uc:3344): autobalance off, ping limit off, team damage penalty disabled. A mid-match
toggle never ran InitGame, so without this "tournament mode over RCON" would quietly mean
something weaker than `?Tournament` on the command line. They are **not** reverted on
disable -- the server cannot know what it was originally configured with, and guessing would
silently rewrite an admin's settings.

Opcode 50 with `ready=1` is vanilla's `AdminReadyAll` (:5235), previously reachable only by
typing `!adminreadyall` in chat. `ready=0` has no vanilla equivalent and clears
`bAdminForcedTournamentReady` as well, which is what makes a re-match work -- otherwise the
gate stays latched open from the previous round.

#### 62-64 -- muted player list

  * **62 MUTE_LIST_REQUEST** `(no body)`
  * **63 MUTE_INFO** `QWord uid, string name, int team, int online, int stored` -- one per mute.
    `stored=0` marks a live mute the mod never recorded: `AOCPlayerController.ServerAdminMutePlayer`
    (`AdminMutePlayer` in Deadliest Warrior) writes `AOCPRI.bIsAdminMuted` straight, so it is real but
    lasts only until that player disconnects. The trailing field is new in 1.4; a client that stops
    after `online` reads everything as stored, which is what older servers meant.
  * **64 MUTE_LIST_END** `int count`

Same request/burst/end shape as 29-31 and 39-41, and it closes the same gap 39-41 closed
for bans: opcode 42 could mute and unmute but nothing could *see* who was muted, so an
admin joining mid-match had no way to find out.

The list is the **stored** one, not a scan of connected players, so mutes on people who
have left are visible too. `online` is 1 when that uid is currently connected, in which
case `name` and `team` are live; for an offline entry `name` is whatever they were called
when muted and `team` is -1.

**Mutes persist.** `Mutes` is a `globalconfig array<MuteInfo>` on `XangModRCon`, holding
`UniqueNetId` + name exactly as `AOCAccessControl.Bans` does, saved to
`[XangMod.XangModRCon]` in `UDKGame.ini` on every change. Opcode 42 writes the entry and
`GameEvent_PlayerConnect` re-applies `bIsAdminMuted` as the player rejoins, so a mute is
no longer cleared by reconnecting or by a server restart.

Two consequences worth knowing. `SaveConfig()` runs on every mute change -- deliberate,
because `AOCAccessControl.UnbanByUID` drops the entry from its array and never saves,
which is why an unbanned player comes back banned after a restart. And 42 accepts a uid
that is not connected: with no PlayerController there is no flag to clear, but the stored
entry is still removed, otherwise a mute applied to someone who then left could never be
lifted. Bots are included if muted; their uid follows the usual `{A=0, B=PlayerID}`
stamping, and being per-match they will never match a stored entry.

#### 60-61 -- teleport and slap

  * **60 TELEPORT** `QWord mover, QWord destination`
  * **61 SLAP** `QWord uid, int power` (clamped 50-2000 server-side, no damage)

Placement logic lives in `XangModAdminActions`. `Actor.SetLocation` is `native(267)` and
returns FALSE when the spot is taken, so `Teleport` walks a ring of eight positions around
the destination before giving up. Velocity is cleared on arrival. Both players must be
alive, and the failure reason is in the audit line.

The in-game `!bring` / `!goto` / `!slap` / `!pause` chat commands were removed by decision
on 2026-08-31 -- RCON covers all of it and the chat parser was not worth its surface area.

#### 51-59 -- freeze, class, loadout, map

  * **51 SET_FROZEN** `QWord uid, int frozen`
  * **52 SET_CLASS** `QWord uid, int classIndex, int immediate`
  * **53 LOADOUT_REQUEST** `QWord uid` -> a burst of 54, then 55
  * **54 LOADOUT_OPTION** out `QWord uid, int slot, int index, string weapon`
  * **55 LOADOUT_END** out `QWord uid, int prim, int sec, int tert`
  * **56 SET_LOADOUT** `QWord uid, int prim, int sec, int tert` (-1 = leave that slot)
  * **57 PLAYER_POS_REQUEST** -> a burst of 58, then 59
  * **58 PLAYER_POS** out `QWord uid, string name, int team, int x, int y, int z, int yawDeg, int alive, int health`
  * **59 PLAYER_POS_END** out `int count`

**Freeze needs no new replication.** `AOCPlayerController.ScriptToggleInput` ->
`ClientScriptToggleInput` (:7572) is already a `reliable client function`; the
`ScriptBlockedInputs` array is not replicated but the RPC that writes it is. Read TB's
comment beside it before trusting this for anything: *"This isn't a safe way of preventing a
player from performing some action. It's intended for SP/Tutorials."* Enforcement is
client-side. Talk is deliberately left unblocked.

**Loadout is exchanged as indices, not names.** 53 walks
`AOCFamilyInfo.NewPrimaryWeapons/NewSecondaryWeapons/NewTertiaryWeapons` and sends each
entry's index; 56 sets by that index. No weapon class path crosses the wire, so the client
needs no content knowledge and the server never resolves a string it was handed.
`AltPrimaryWeapon` is carried through untouched -- it is not in the choice lists and
clobbering it would drop the alternate mode of whatever they hold. Server-side only:
`SetWeapons` is simulated and the normal flow is client-then-`S_SetWeapons`, so this sets
what the server will spawn them with, not what their own class menu shows.

**Positions are read live, not from the replicated copy.** `AOCPRI.PawnLocation` is only
refreshed on a 2s server timer (AOCPRI.uc:192); the handler already runs on the server, so
it takes `Pawn.Location` directly and falls back to `PawnLocation` for a player whose pawn is
gone. Yaw is converted to degrees on the way out so the client needs to know nothing about
UE3 rotator units.

**Inebriate is not TO2-only, and neither 26 nor 48 touches the sound mode.** Two things had
to be right:

  * `EnableDrunkSoundMode` is a plain function, so calling it from an RCON handler runs it on
    the *server's* copy of the controller, where its 1s repeating timer reaches for an audio
    device a dedicated server does not have. Both handlers now call only `ClientInebriate`;
    `AOCBaseHUD` drives the sound mode on the player's own machine from its fade.
  * The drunk effect is gated by the active post-process chain, not the map.
    `AOCBaseHUD.NotifyBindPostProcessEffects` looks up `'drunkeffect'` in
    `LocalPlayer.PlayerPostProcess`, and Torn Banner's comment beside it says "if the PPC
    doesn't have a drunk effect, this does nothing". The default chain is
    `CHV_PPC_Pack.ChivPostProcess_noToneMap`; the drunk nodes live in the sibling chain
    `ChivPostProcess_drunk` in the same base-game package. XangMod's `ClientInebriate`
    override **swaps the whole chain** and re-binds when the map has none of its own, using
    the engine's own idiom from `GameInfo.uc:1585-1592`:

        LP.RemoveAllPostProcessingChains();
        LP.InsertPostProcessingChain(<chain>, INDEX_NONE, true);
        PC.myHUD.NotifyBindPostProcessEffects();

    Appending instead of replacing is what the first attempt did, and it renders as heavy
    blocky smearing: `ChivPostProcess_drunk` is a *complete* chain, a sibling of
    `ChivPostProcess_noToneMap`, so leaving the map's chain in place runs two full chains
    back to back and uber-post-processes (tone map, bloom, motion blur) the scene twice.
    Sober-up restores `Engine.static.GetWorldPostProcessChain()` the same way, and only when
    XangMod was the one that swapped it.

#### 29-47 and 65-69 -- XangMod additions

ChivAdmin ignores opcodes it does not know, so these cannot break it.

| # | Name | Dir | Payload |
|---|------|-----|---------|
| 29 | PLAYER_LIST_REQUEST | in | (empty) |
| 30 | PLAYER_INFO | out | qword uid, string name, int team, score, deaths, kills, ping, health, teamDamage, string class, int isSpectator |
| | | | ping is milliseconds (`PRI.Ping * 4`), matching opcode 23. Bots carry a synthetic uid: `{A=0, B=PlayerID}`. |
| 31 | PLAYER_LIST_END | out | int count |
| 32 | SET_TEAM | in | qword uid, int team |
| 33 | FORCE_SPECTATE | in | qword uid |
| 34 | SET_TEAM_SCORE | in | int team, int score |
| | | | LTS keeps the real score in `AOCLTS.RoundScores` and draws `AOCLTSGRI.RoundsWon`; `Teams[].Score` is a mirror rewritten from `RoundScores` at every round boundary (`AOCLTS.uc:216-219`, `:316`). All three are written. `AOCLTS.uc:331` tests `== GoalScore` after the increment, so a team set to the goal steps over it and never triggers the end. |
| 35 | ADMIN_AUDIT | out | string action, string detail |
| 36 | SERVER_INFO_REQUEST | in | (empty) |
| 37 | SERVER_INFO | out | string map, int numPlayers, maxPlayers, matchBegun, numSpectators |
| 38 | CONSOLE_RESULT | out | string command, string result |
| 39 | BAN_LIST_REQUEST | in | (empty) |
| 40 | BAN_INFO | out | qword uid, string name, string reason, int durationSeconds, string netIdString, string ipPolicy |
| | | | Three stores are reported, not one, because all three are enforced. `AOCAccessControl.Bans` holds the rich entries the RCON ban, votekick and ping kick write. `Engine.AccessControl.BannedIDs` holds bare uids written by the console `admin kickban` and by `AOCAccessControl.KickBanPlayer`; `AOCAccessControl.IsIDBanned` ends with `bBanned || Super.IsIDBanned(NetID)`, so those are live bans -- sent as `(uid ban list)`, duration 0, because the game records nothing else. `Engine.AccessControl.IPPolicies` DENY lines are live too via `Super.CheckIPPolicy`; sent with uid 0 and name `(ip ban)`. `KickBanPlayer` appends the DENY line and the `BannedIDs` entry together, so when the two arrays pair one-for-one the Nth policy is reported on the Nth uid's row and opcode 20 removes both. A bare `DENY,` (Steam sockets carry no `:port`, so `Left(IP, InStr(IP, ":"))` yields "") is inert and never listed. Entries already covered by `Bans` are not repeated. |
| 41 | BAN_LIST_END | out | int count (every BAN_INFO sent, across all three stores) |
| 42 | MUTE_PLAYER | in | qword uid, int mute |
| 43 | SET_PAUSE | in | int paused |
| | | | Goes to `AOCGame.SetPause`/`ClearPause`, not `PlayerController.SetPause` (XangMod's override there is admin-gated). `bPauseable` is forced on around the call: AOCGame inherits `bPauseable=False` from `UTGame.uc:3396`, and `bAdminCanPause=false` in UDKGame.ini, so `AllowPausing` refused every pause until this. In-game `unpause` only clears a pause the same controller set, so it cannot undo this -- unpause over RCON. |
| 44 | END_MATCH | in | int winningTeam, string reason |
| | | | `winningTeam` does not decide the winner. `AOCGame.EndGame` opens with `WinningTeam = GetWinningTeam()` and takes the result off the live scores; the parameter only picks whose top scorer is spotlighted (`GetHighestScoreFromTeam`). Use opcode 34 first to hand a team the match. `reason` is broadcast to chat here -- `EndGame`'s own Reason is a condition string players never see, and it is passed as **`"TimeLimit"`**: `AOCFFA.EndGame` runs its body only for `"TimeLimit"` (Medieval Warfare also accepts `"Admin action"`, Deadliest Warrior's copy does not) and `AOCDuel.EndGame` gates on `"TimeLimit"` alone, so any other string is a silent no-op in free-for-all. Ends 25s later via `ActualEndGame`. |
| 45 | SET_AUTOBALANCE | in | int enabled |
| 46 | SET_GAME_SPEED | in | int speedPercent (100 = normal, clamped 10-400) |
| 47 | RESTART_MATCH | in | (empty) |
| 65 | ROUND_START | out | string map, int roundNumber, int agathaScore, int masonScore, int goalScore |
| 66 | ROUND_END | out | int winningTeam, string map, int roundNumber, int agathaScore, int masonScore, int matchEnding |
| 67 | ROUND_PLAYER_STAT | out | qword uid, int team, string name, int kills, deaths, assists, score, enemyDamage, teamDamage, damageTaken, parries, feints, meleeHits, projectileHits, blocks, dodges |
| 68 | ROUND_STAT_END | out | int count |

**46 exists rather than routing through 28** because `AOCGame.SetGameSpeed` notifies
every client via `NotifySpeedChanged` and republishes `AOCGRI.Speed`, which a bare
`GameInfo.ConsoleCommand` does not do. That is exactly why the old relay carried its own
SLOMO verb. Clamped 10-400%: a speed of zero stops the match with no way to type the
command that would restore it.

**38 is the one that changes how RCON feels.** `Actor.ConsoleCommand` returns the
command's output as a string and vanilla throws it away, so every *query* command was
invisible to an admin. Opcode 28 now captures it and replies with 38, which makes RCON
a real console rather than a fire-and-forget pipe. Empty results are still sent so a
client can always pair a response to its request.

**39-41 fixes a genuine vanilla gap:** RCON could unban but had no way to *see* the ban
list, so unbanning meant already knowing the uid. `AOCAccessControl.Bans` carries name,
reason and duration for exactly this reason.

**42** sets `AOCPRI.bIsAdminMuted` directly rather than calling
`ServerAdminMutePlayer`, which gates on the *caller's* `bAdmin` -- the console has no
PRI, so that path could never authorise it. The RCON password is the authorisation.

**43** borrows a PlayerController to own the pause (an admin if one is connected),
because `GameInfo.SetPause` requires one and the console has none.

**44** converts a team index into the winning PRI via
`AOCGame.GetHighestScoreFromTeam`, since `EndGame` wants a PRI. An empty team ends the
match with no winner rather than failing silently.

29 replies with a burst of 30s then a 31. Kills come from `AOCPRI.NumKills`, not
`PlayerReplicationInfo.Kills` -- AOCPRI's own comment says `Kills` is not replicated.

### Round events (65-69)

Server-push only -- there is no request opcode; the game mode emits them as rounds begin
and end. Scope: **LTS, TD, TO** only (see the gate below). They exist to give a consumer
the warmup/round/map boundaries vanilla never exposes: vanilla opcode 21 `ROUND_END` only
fires from `AOCGame.EndGame`, which for LTS is once per *match*, and there is no start
event at all.

**Warmup never emits.** The game starts in `Auto State AOCPreRound` and only enters a real
round when `StartRound()` runs. The start event is emitted from the `StartRound` override in
`Include/Game/Match.uci`, so the pre-round countdown can never produce one.

  * **65 ROUND_START** `string map, int roundNumber, int agathaScore, int masonScore, int goalScore`
    Pushed immediately after the round actually begins (post `super.StartRound`).
    `roundNumber` is 1-based per map. Scores are the scores at round start; `goalScore` is
    `GoalScore` for LTS, -1 for TD/TO (no per-map goal in the same sense).
  * **66 ROUND_END** `int winningTeam, string map, int roundNumber, int agathaScore, int masonScore, int matchEnding`
    `winningTeam` is a raw `EAOCFaction` int: 0 = Agatha, 1 = Mason, -1 = draw/none.
    `matchEnding` is 1 when this round also ends the match (LTS reaching the goal, or any
    TD/TO end), 0 otherwise -- that is what lets the client tell a round from a map boundary.
    For LTS a per-round end (elimination/time) is emitted once per round with `matchEnding=0`;
    the round that reaches `GoalScore` emits with `matchEnding=1`.
  * **67 ROUND_PLAYER_STAT** `qword uid, int team, string name, int kills, deaths, assists,
    score, enemyDamage, teamDamage, damageTaken, parries, feints, meleeHits, projectileHits,
    blocks, dodges` -- one per connected, non-bot player, sent as a burst immediately after a
    66. Stats are **match-cumulative**, not per-round: a consumer diffs two consecutive
    bursts. Bots carry the same synthetic `{A=0, B=PlayerID}` uid as everywhere else.
    Every reported counter is zeroed when round 1 starts (`XangModResetRoundStats`), so the
    first burst is round 1 alone and holds nothing from the pre-round.
    `teamDamage` is real team damage dealt (`RealTeamDamageDealt`), not the PRI's
    `TeamDamageDealt`, which this mod reuses as the scoreboard parry count; that count is
    sent as `parries`. `damageTaken` covers enemy and team hits. `meleeHits` and
    `projectileHits` count landed, unparried hits on enemies. `blocks` and `dodges` are
    still unwired and always 0.
  * **68 ROUND_STAT_END** `int count` -- closes the 67 burst.
  * **69 OBJECTIVE_STAGE** `string map, int roundNumber, int stage, int totalStages,
    int outcome, int attackingTeam, int completed, int skipped, int timeLeft` -- TO only,
    one per objective stage as it ends. `stage` is 1-based, in the map's Register Objective
    Sequence order. `outcome` is 1 when the attackers completed the stage, 2 when a skip
    ended it (`AdminSkipObjective`, the CompForest timed skip, or `AdminCEAutoskip`), and 0
    when the match ended with the stage still standing. `attackingTeam` is a raw
    `EAOCFaction` int (0 = Agatha, 1 = Mason, -1 unknown). `completed` and `skipped` are
    running counts for the round, this stage included, zeroed when round 1 starts; they
    never overlap, so stages the attackers got through is `completed + skipped`.
    `timeLeft` is the round clock in seconds, read before the stage's bonus time is added.
    One 69 is always sent immediately before a match-ending 66, for the stage the match
    ended on, so the last 69 before a 66 holds the totals even for a consumer that
    connected mid-match. The final stage only reports outcome 1 or 2 when the map itself
    ended the match for the attackers (`ObjectiveEndGame`); a time-out or an admin ending
    the match reports 0. A `ce skip` typed by hand is indistinguishable from a real
    completion and reports 1.

**Mode gate.** `XangModRoundReportingEnabled()`, in `Include/Game/RoundReporting.uci`, emits
only for `AOCLTS` (per-round), `AOCTD`, and `AOCTeamObjective` **excluding `AOCTUT`**
(tutorial subclasses the objective game, but is not a real round). FFA, CTF, KOTH, Duel,
CDWDuel, TUT and Survival emit nothing. KOTH deliberately left alone.

**Winning-team source differs by mode.** For LTS the round winner is read from
`AOCLTS.RoundWinner`; `AOCGame.WinningTeam` is only written inside `EndGame`, so it would be
stale for a normal per-round LTS end. For TD/TO every end routes through `EndGame`, so
`WinningTeam` is current. `XangModRoundWinnerTeamIndex` in `Include/Game/RoundReporting.uci`
picks the right source.

**Double-emit guards.** `AOCLTS.AOCEndRound` calls itself to resolve a draw; a re-entrancy
flag keeps that from producing two 66s. `EndGame` sets a flag so `AOCEndRound` (which TD/TO
also reach) doesn't emit a second, `matchEnding=0` event on top of the `matchEnding=1` one,
and a third flag stops a second `EndGame` call (time-limit vs admin-forced) re-emitting. The
`AOCEndRound` and `EndGame` overrides that carry these guards live in `Include/Game/Match.uci`;
the emit helpers they call (`XangModSendRoundEnd`, `XangModSendRoundStats`) live in
`Include/Game/RoundReporting.uci`.

The round-event helpers in `XangModRCon` are `SendRoundStart` / `SendRoundEnd` /
`SendRoundPlayerStat` / `SendRoundStatEnd`.

The game captures a round result's map, winner, number, scores and final objective state
when the boundary occurs. If a death caused it, the pawn's `Died` override holds the result
until the outermost inherited death call returns, so the final victim's death is included.
It then sends the final objective report (if any) and the complete 66/67/68 burst together,
without a timer or a new protocol layout. Time limits and administrative ends outside a
death still report immediately. An end before round 1 emits no competitive result.

Autoskip marks a stage before activating Kismet so synchronous transitions see the mark.
When no matching event accepts activation, the mark is cleared: a later real completion
must not be reported as skipped.

`InitRemoteConsole` reuses only a valid XangMod listener, judged by its own port. A live
listener's port can differ from `class'XangModRCon'.default.RConPort` (a host can set it
outside this class's config), so the class default is only the port a new listener starts
with, never the test for reuse. Comparing against it rejected the carried listener on every
map change: a second actor became the event target with no sessions, clients stopped
receiving game events (kills, team changes, chat, round ends) and were dropped at the next
travel. Among several XangMod listeners the one holding the socket wins, then the one
holding sessions; an idle duplicate on the same port (never bound, no sessions) is retired
so it cannot take the port later. A vanilla listener on the required port is retired before
a replacement is created; another mod's conflicting listener is reported explicitly.
`AdminRConStatus` displays the runtime game class and actual `RemoteConsole` event target,
including whether its native socket is listening, its configured and bound ports and the
class default port. A newly spawned actor is reported as waiting to bind, not as ready.

### CONSOLE_COMMAND is the important one

Scope 1 runs against the **server-side** controller for that player, so it reaches
server functions and admin execs. It does not execute on their machine.

That single opcode exposes everything XangMod already has without a per-command opcode:
`AdminKick`, `AdminKickBan`, `AdminUnban`, `AdminBanNetID`, `AdminChangeTeam`,
`AdminCoinFlip`, `AdminReadyAll`, `AdminCancelVote`, `AdminTournamentMode`,
`AdminForceSpectate`, `AdminForceSpectateAll`, `ce`, and anything added later.

It is also arbitrary execution against a live server, gated only by the RCON password.

Because scope 1 runs in the server's process, `quit` on a player quits the **server** --
confirmed in testing. `XangModBlockedConsoleCommands` (config, `[XangMod.XangModRCon]` in
UDKGame.ini) refuses the first token of a command; defaults are `quit`, `exit`, `debug`.

### Auditing

Every state-changing command calls `XangModAudit(Action, Detail)`, which:

  * logs via `LogAlwaysInternal` (not the log macro -- FINAL_RELEASE makes `LogInternal`
    private and the macro stops compiling), and
  * emits opcode 35 so any connected client sees it too.

Passwords are never logged; opcode 27 records only "set" or "cleared". This is
deliberate: admin power on this server should be visible rather than quiet.

Not yet done: an in-game notification for destructive actions. `22603c3` already added
admin command logging in-game, so there is a pattern to extend.

### Client (C:\Projects\ChivRcon)

The client is a separate Avalonia app at `C:\Projects\ChivRcon`. .NET 8, three projects.
`ChivRcon.Core` speaks the protocol; `ChivRcon.App` is the UI; `ChivRcon.Tests` is a
self-contained runner.

Its opcode table already matched 0-28 exactly, so the parity work needed no client
changes at all. Added since: opcodes 29-47 in `RconMessageType`, the matching send
methods and parse cases in `RconClient`, and event records in `RconEvents`.

**The relay is gone.** `RelayClient.cs` spoke a separate text protocol on its own port,
served by a `ChivRelay` ServerActor, and existed solely to reach three things native
RCON could not: console commands, text mute, and game speed. Those are now opcodes 28,
42 and 46, so the whole second connection -- port field, status label, reconnect timer,
connect/disconnect lifecycle -- was removed along with its integration tests. Old
settings files carrying `RelayPort` still load; unknown JSON properties are ignored.

One naming fix worth knowing: the client's `ConsoleCommandScope` used to read
`Server / Client / All`. Scope 1 does **not** run on the player's machine -- it runs on
their server-side controller -- so it now reads `Game / Player / AllPlayers`, matching
ChivAdmin's own naming and the server.

### Adding an opcode

1. `const RCONX_YOURTHING = 38;` in `XangModRCon.uc`.
2. A `case` in `HandleMessage`'s extended switch.
3. A handler that reads with `GetGUID`/`GetInt`/`GetString` **in the order the client
   writes them** and calls `XangModAudit` if it changes state.
4. Document it in the table above.

Unknown opcodes are logged and ignored, never fatal -- a newer client cannot drop the
connection.

#### `SAY_ALL_BIG` (opcode 7) was never a big message

`AOCRCon.uc:143` falls both broadcast opcodes through to one handler:

    case MessageType.SAY_ALL:
    case MessageType.SAY_ALL_BIG:
        HandleSayAll(Packet);

`HandleSayAll` only calls `BroadcastMessage`, so "say big" was a second chat line and
nothing else. `AOCBaseHUD.Announce` looks like the intended path but its body is
commented out (`AOCBaseHUD.uc:961`), so `PC.Announce()` does nothing at all.

The only vanilla route that puts arbitrary text on screen is the objective header
banner: `AOCPlayerController.ClientShowLocalizedHeaderText` ->
`AOCBaseHUD.AddHeaderText`, which the stock game uses for CTF and Duel headers.
`XangModRCon.HandleSayAllBig` intercepts opcode 7 the same way `UNBAN_PLAYER` is
intercepted, calls that on every `AOCPlayerController`, and still broadcasts the chat
line, because the banner clears itself after a few seconds and the chat line is the
record. Audited as `SAY_ALL_BIG`.

Clients need no mod for this -- the header banner is stock; only the server has to be
running this build.

### Three vanilla traps, found the hard way

These are worth reading before adding anything that moves players or silences them.

#### `WorldInfo.Game.ChangeTeam(PC, num, ...)` does not change teams

`AOCGame.ChangeTeam` (AOCGame.uc:1618) ignores `num` completely apart from a `< 255`
test:

    NewTeam = (num < 255) ? Teams[AOCPlayerController(Other).CurrentFamilyInfo.FamilyFaction] : ObserverTeam;

The team is read back off the player's own `CurrentFamilyInfo`, so it always resolves to
the team they are already on, hits the "check if already on this team" branch, and
returns false. `ServerChangeTeam(N)` is no better -- `AOCPlayerController.ChangeToNewTeam`
calls it with `CurrentFamilyInfo.FamilyFaction` anyway.

The only thing that moves a player is changing `CurrentFamilyInfo` first. The one place
in the stock game that force-swaps a live player is `AOCGame.PerformDeathBasedAB`
(AOCGame.uc:4962), and `XangModForceTeam` follows it:

  1. `NewFamily = AOCGRI.FamilyInfos[ClassReference]`, `+5` for Mason. The array is
     laid out 0-4 Agatha, 5-9 Mason, indexed by `ClassReference`.
  2. `PC.ClientAutoBalance(NewFamily)` -- clears the client's pending team selection and
     updates its HUD.
  3. `PC.SetNewClass(NewFamily, false, true)` -- `bForceSwitch = true` (autobalance passes
     false) is what sets `bMarkNewTeam` and kills the current pawn, so the swap lands now
     instead of on next respawn.
  4. `AOCPRI.MyFamilyInfo = none`.
  5. `PC.ServerChangeTeam(NewFamily.FamilyFaction)` -- only now does `ChangeTeam` resolve
     to the other team.

A player who has not picked a class yet has no `CurrentFamilyInfo` and cannot be swapped;
opcode 32 audits `SET_TEAM_FAILED` in that case rather than failing silently.

#### `bIsAdminMuted` alone does not mute anyone

The flag replicates fine (`AOCPRI.uc:128`, on `bNetDirty`), but the only chat-side
consumer is `AOCPlayerController.ReceiveChatMessage` (:3502) -- i.e. **on each receiving
client**, and it is skipped in two cases:

  * the receiver has the sender on their Steam friends list (`SteamFriendPRI`), and
  * the message is the sender's own copy (`PRI != PlayerReplicationInfo`).

So a muted player still watches their own chat go through, which is exactly what mute
looking broken looks like when testing. `ServerAdminMutePlayer` (:7304) sets the flag and
has its `UpdateGameplayMuteList` follow-up commented out, so nothing else covers it.

`XangModGame.BroadcastMessage` now drops the message server-side before it reaches the
wire, and tells the sender they are muted. VOIP was already covered -- `AOCGame.uc:2198`
checks the flag when building voice channels.

#### The ban list is server-side, and that is fine

`AOCAccessControl.Bans` is `globalconfig array<BanInfo>`, so it only exists in the
server's ini and no client can read it directly. Opcodes 39-41 walk the array **on the
server** and send one `BAN_INFO` per entry, so exposing it is entirely feasible -- the
client just never had a way to ask before. `ChivRcon.App/BanManagerDialog.cs` is the UI:
refresh, select, unban, with the server's audit line reported back in the dialog.

Note `KickBanGlobal` -> `AddBan` stores both the NetID **and** an IP policy
(`DENY,<addr>`) in the same `BanInfo`, so removing the entry lifts both. An IP-only ban
with no UID cannot be lifted by opcode 20; the dialog greys that case out.

### Untested, in rough risk order

  * The C# client changes have not been compiled -- no .NET SDK was reachable from this
    session. `BanManagerDialog.cs` is a new file in `ChivRcon.App`.
  * `XangModForceTeam` against a player who is mid-respawn, in a vehicle, or a King class
    (`FamilyInfos` only covers the five standard classes).
  * `AC.Bans.Remove(i, 1)` + `SaveConfig()` from outside `AOCAccessControl` -- legal
    UnrealScript, but the write happens on whatever ini `AOCAccessControl` is configured
    to, not necessarily the one being edited by hand.
  * Opcode 30's field order against the client's parse (now read by the player list).
  * `Pawn.Died` for opcode 25 -- taken from an existing `AOCGame` call site, but not
    exercised from an RCON context.

---

## 8. Admin commands and configuration

### 8.1 How admin commands are structured

Almost every admin command is a pair: an `exec function` the player types into the console,
and a `reliable server function S_<Name>` that does the work. The exec half checks
`PlayerReplicationInfo.bAdmin` locally and prints

```
You are not logged in as an administrator on this server.
```

if you are not. That client-side check is a convenience, not the security boundary — the
server half re-checks with `IsAdmin()`. Both halves live in `Include/PC/AdminCommands.uci`,
except the map-change commands, which are in `Include/PC/AdminMaps.uci`.

### 8.2 Admin commands

| Command | Effect |
|---|---|
| `AdminBroadcastMessage <text>` | Broadcast a server message to everyone |
| `AdminCoinFlip` | Server-side coin flip, broadcast to all |
| `AdminChangeTeam <player>` | Swap a player's team |
| `AdminChangeTeamDamageAmount <float>` | Set team damage multiplier (0.0 none, 0.5 vanilla, 1.0 full) |
| `AdminCancelVote` | Cancel the vote in progress |
| `AdminReadyAll` | Force every player ready |
| `AdminKick [player]` | Kick by name |
| `AdminKickScoreboard [player]` | Kick by scoreboard selection |
| `AdminKickBan [player]` | Kick and ban by name |
| `AdminKickBanScoreboard [player]` | Kick and ban by scoreboard selection |
| `AdminUnban [player]` | Remove a ban |
| `AdminBanNetID <netid> [reason]` | Ban by Steam NetID without the player being present |
| `AdminLoginHidden <password>` | Log in as admin without the login appearing in chat |
| `AdminRestartMap` | Restart the current map |
| `AdminForceSpectate <player>` | Force one player into spectator |
| `AdminForceSpectateAll` | Force everyone into spectator |
| `UnPause` | Start the unpause countdown (default 3 seconds) |
| `ce <event>` / `CauseEvent <event>` | Fire a Kismet console event |

**Competitive / tuning commands.** These change combat behaviour and are the ones worth
understanding before you touch them:

| Command | Effect | Backing config var |
|---|---|---|
| `AdminTournamentMode [bool]` | Enable tournament mode (mod supplies its own readiness via `!ready` in chat; vanilla `bReady` is a join gate, not readiness) | — |
| `AdminSetCollisionRadius <float>` | Player collision bubble radius. Vanilla AOC default is 39.0 | `fXangModCollisionRadius` |
| `AdminEnableGoFast [bool]` | Cuts `MaxSprintSpeedTime` (time to reach full sprint) by MAA 50%, Vanguard 35%, Knight 20%; archers unchanged. Top sprint speed is unchanged. Applies immediately, no respawn | `bXangModGoFast` |
| `AdminCEAutoskip` | Fire `ce skip` automatically when the objective timer reaches 5 seconds | — |
| `AdminSkipObjective` | Complete every objective in the current TO stage so the map's Kismet advances it; that stage awards no bonus time. Skipping the final stage ends the match | — |
| `AdminCompForestAlternatingSpawns [bool]` | Alternate A/B spawn groups during the CompForest sluice gate objective only | `bEnableCompForestAlternatingSpawns` |
| `AdminResetAllTraction` | Reset traction on all surfaces |
| `AdminResetIceTraction` | Reset ice traction specifically |
| `AdminParryTurnComp [true/false]` | **Default on.** When on, a melee swing that fails the plain parry cone is re-tested against the defender's predicted facing (recent turn speed carried forward by the defender's one-way ping, capped at 0.15 s and 60 degrees). Fixes parries that fail when you turn toward the attacker after raising the parry, because the server only knows your facing from your last move packet. It can only turn a miss into a parry. No argument reports the current state. Saved to the ini | `bXangModParryTurnComp` |
| `AdminParryCone [degrees]` | Directional melee parry cone, total degrees, applied server-wide. `160` is the default, `180` is a full front hemisphere, `30` is very tight. Clamped to 30–180. No argument reports the current value. Saved to the ini, so it survives restarts | `fXangModParryConeDegrees` |

Melee parry success is default-on directional logic in `Include/Pawn/Combat.uci`; there is no
admin parry-box toggle. The old parry component can still be visualized for debugging, but XangMod
forces it non-trace-blocking so it does not drive melee parry classification.

### 8.3 CompForest alternating spawns

Disabled by default. When enabled, TO on CompForest alternates between tagged A/B
player-start groups during the sluice gate objective only.

Tag the sluice gate `AOCPlayerStart` actors with:

```
Obj3_Agatha_A
Obj3_Agatha_B
Obj3_Mason_A
Obj3_Mason_B
```

The tagged starts still need their normal `PlayerStartFaction` set correctly. If no valid
tagged start is available, spawning falls back to vanilla behaviour.

```ini
[XangMod.XangModTO]
bEnableCompForestAlternatingSpawns=false
```

The logic lives in `Include/XangModCompForestSpawnControl.uci`, nested from the
`XangModGame.uci` facade.

### 8.4 Map shortcuts

`Include/PC/AdminMaps.uci` provides 14 one-word map changes. Eleven call `ServerChangeMap`,
which validates via `AOCGame.MapExists` and broadcasts the change:

| Command | Map |
|---|---|
| `AdminGotoSF` | `AOCTO-Slumforest_p` |
| `AdminGotoSH` | `AOCTO-Slumpshill_p` |
| `AdminGotoSP` | `AOCTO-Slumppost_p` |
| `AdminGotoDuel` | `AOCFFA-YeedYard_p` |
| `AdminGotoMoor` | `AOCLTS-Moor_p` |
| `AdminGotoKendo` | `AOCTDM-Moor_p` |
| `AdminGotoOF` | `AOCTO-OldForest_p` |
| `AdminGotoWF` | `AOCTO-Snowforest_p` |
| `AdminGotoSpooky` | `AOCTO-SpookyForest_p` |
| `AdminGotoDF` | `AOCTO-Darkforest_p` |
| `AdminGotoCF` | `AOCTO-CompForest_p` |

Three others switch to a **different mod** via `WorldInfo.ServerTravel` with `?modname=`,
so they leave XangMod entirely:

| Command | Travels to |
|---|---|
| `AdminGotoCompMod` | `AOCFFA-YeedYard_p?modname=CompMod3` |
| `AdminGotoNateMod` | `AOCFFA-YeedYard_p?modname=NateMod` |
| `AdminGotoZwangMod` | `AOCFFA-YeedYard_p?modname=Slump3` |

### 8.5 Player commands

| Command | Effect | File |
|---|---|---|
| `FirstPersonSpectate [bool]` | Toggle first-person while following a player (§6) | `PC/Spectate.uci` |
| `SpectatorPerspective`, `BehindView`, `NextCameraAngle`, `SpectatorFreecam` | Spectator camera controls | `PC/Spectate.uci` |
| `FOV <float>` | Set field of view | `PC/Core.uci` |
| `SetRagdollLimit <int>` | Cap simultaneous ragdolls | `PC/Core.uci` |
| `DisableScreenShake <bool>` | Turn off flinch/dazed/hit camera shake | `PC/Effects.uci` |
| `JoinClass [team] [class]` | Join a team and class directly | `PC/Loadout.uci` |
| `SetAssassinCustom <team> <field> <value> [slot]` | Assassin customization | `PC/Loadout.uci` |
| `GetAdmins` | List admins currently on the server | `PC/Loadout.uci` |
| `XangModNetSpeed <int>` | Set net speed | `PC/Network.uci` |

### 8.6 Debug and diagnostic commands

All in `Include/PC/Debug.uci` unless noted.

| Command | Effect |
|---|---|
| `DrawParryHitbox` | Toggle parry hitbox rendering |
| `ShowMyParryBox` / `ShowOthersParryBoxes` / `ShowAllParryBoxes` | Scope the hitbox display |
| `ShowStats` | Display accumulated player stats |
| `ToggleDeathMessages` / `EnableDeathMessages` / `DisableDeathMessages` | Console messages on death |
| `ToggleReleaseHitMessage` / `EnableReleaseHitMessage` / `DisableReleaseHitMessage` | Report how far into release you hit |
| `aoc_DrawTracerHitDetails <bool>` | Draw tracer hit details |
| `ShowGroundSpeed <bool>` | Display ground speed |
| `GetServerTickTime` | One-shot server tick time |
| `StartPollingServerTickTime` | Continuous server tick time |
| `NetDebug` | Net diagnostics (`PC/Network.uci`) |
| `XangModShowParryBoxes [bool]` | Admin-only, client-side: draws every pawn's parry box for tuning (`PC/ParryConfig.uci`) |
| `FPSpectateDebug` | First-person spectate diagnostics (`PC/Spectate.uci`) — renders in game via `ClientDisplayConsoleMessage` |

### 8.7 Config variables

`globalconfig` variables on the player controller, declared in `Include/PC/Vars.uci`. These
persist per-client in the user's config:

| Variable | Meaning |
|---|---|
| `bDisableScreenShake` | Disable all camera shake effects |
| `bXangModParryBox` | Legacy parry-component visualization/sizing value; not the melee parry rule |
| `bSkeletalParry` | Legacy parry-component visualization/sizing value; not the melee parry rule |
| `bXangModGoFast` | Faster sprint ramp-up per class (`AdminEnableGoFast`) |
| `fXangModCollisionRadius` | Player collision bubble radius (vanilla 39.0) |
| `iXangModMinNetSpeed` | Minimum net speed to enforce |

Game-side `config` variables in `Include/Game/Vars.uci`:

| Variable | Meaning |
|---|---|
| `SDKPrefixes` | Map-prefix to gametype mapping — see §8.8 |
| `fXangModTournamentHoldLimit` | Seconds before the tournament gate gives up; 0 disables. Default 300 |
| `bEnableCompForestAlternatingSpawns` | §8.3 |

### 8.8 `DefaultXangMod.ini`

**`SDKPrefixes` is the important part.** Mounting a mod with `?modname=` does not by itself
select a gametype — the map prefix does. `SetGameType` in `Include/Game/Match.uci` maps
prefixes to XangMod gametypes:

```ini
[XangMod.XangModTD]
SDKPrefixes=(Prefix="AOCFFA",GameType="XangMod.XangModFFA")
SDKPrefixes=(Prefix="AOCTUT",GameType="XangMod.XangModTUT")
SDKPrefixes=(Prefix="AOCDUEL",GameType="XangMod.XangModAOCDuel")
SDKPrefixes=(Prefix="AOCLTS",GameType="XangMod.XangModLTS")
SDKPrefixes=(Prefix="AOCKOTH",GameType="XangMod.XangModKOTH")
SDKPrefixes=(Prefix="AOCTO",GameType="XangMod.XangModTO")
SDKPrefixes=(Prefix="AOCTD",GameType="XangMod.XangModTD")
SDKPrefixes=(Prefix="AOCCTF",GameType="XangMod.XangModCTF")
SDKPrefixes=(Prefix="DUEL",GameType="XangMod.XangModCDWDuel")
SDKPrefixes=(Prefix="CDWDUEL",GameType="XangMod.XangModCDWDuel")
```

Other sections:

- `[Engine.GameInfo] DefaultGame=XangMod.XangModTD`
- `bRestartMapAfterEndGame` per gametype — true for TD, LTS and TO; false for FFA, Duel,
  KOTH and CTF
- `[Engine.Engine]` / `[Engine.GameEngine]` — `bSmoothFrameRate=False`,
  `MaxSmoothedFrameRate=500`, `MinSmoothedFrameRate=5`

**The blocked console command list must live in the `.ini`, not in `DefaultProperties`:**

```ini
[XangMod.XangModRCon]
XangModBlockedConsoleCommands=quit
XangModBlockedConsoleCommands=exit
XangModBlockedConsoleCommands=debug
```

The compiler rejects a config array seeded from defaults, which left the list empty and
`quit` runnable over RCON. Scope 1 runs on the server-side controller, so a `quit` aimed at
a player kills the server. See §7.

**TO stage bonus time per map** (`Classes/XangModObjTimer.uc`, applied in
`XangModTO.ActivateNextObjectiveStage`):

```ini
[XangMod.XangModObjTimer]
+Overrides=(Map="AOCTO-MapName_p",Obj=2,Bonus=900)
```

`Map` is matched case-insensitively against `WorldInfo.GetMapName()`. `Obj` is the 1-based
stage in the map's Register Objective Sequence order. `Bonus` replaces that stage's
`BonusTime` (vanilla default 600) - the seconds added to the round clock when it completes.
Clients resync through the vanilla `RequestTime` call after each stage change, so the HUD
needs nothing extra. Plain TO maps only; the final stage ends the match, so its bonus is moot.

**Bot King per map** (`Classes/XangModAIKing.uc`, `Classes/XangModKingBot.uc`, handled in
`Include/XangModTOGamemode.uci`):

```ini
[XangMod.XangModAIKing]
Maps=Stoneshill,KingsGarden
```

Comma-separated; each entry is matched inside the map's title or file name, ignoring case
and punctuation (`+Maps=` array lines did not load from the mod ini, a plain string does).
`bDisabled=true` keeps Kings human by default. `AdminAIKing [on|off]` switches it for the
current match (no argument toggles); during the King stage, off hands the throne to the
top-scoring defender and on takes it back for the bot.
Idle-bot teammate following is listed the same way under `[XangMod.XangModBotBrain]`
`FollowMaps=` (`*` = every map). The map's
`AOCObjective_Assassination` only accepts a human King, so `ChooseHighestScoreController`
hands it any player, mutes the "X will be King" messages, and next tick undoes that pick
(as if they'd rejected) and spawns `XangModKingBot` at `KingSpawnLocation` with the King
family and loadout. Its pawn is set as the objective's `Parent` with the death listener,
so killing it completes the objective as normal. The bot leaves when it dies; `killbots`
replaces it instead of completing the objective. No map changes.

The stats-reporting keys (`bEnableStatsReporting`, `StatsEndpoint`, `StatsApiKey`,
`StatsServerId`, `StatsReportInterval`) are commented out throughout — that system was
removed on 2026-09-14 and superseded by the RCON round events in §7.

---

---


---

### 8.9 Ranked LTS and TO

Ported from MustMod (Love Norström's fork) 2026-10-10. Plan, backend contract and test
list: project doc `ranked-lts-plan.md`. Backend source: `supabase/` in this folder.

- `Classes/XangModRanked.uc` -- server-only state machine (queue, locked teams, leaver
  pause, result) and HTTP to the Supabase `ranked` function. Spawned by `PostBeginPlay` in
  `Game/Match.uci`: matchmade ranked on both LTS and TO, gated by `bRankedEnabled`.
- Hooks: `ShouldCountDown` holds the countdown until teams lock; `EndGame` calls
  `MatchEnded`; `GenericPlayerInitialization` tags names (strips them in other modes);
  `BroadcastMessage` handles `!rankedhelp`. The shared hook block (team lock, leaver pause,
  votes, ranked admin execs) lives in `Include/XangModRankedHooks.uci`, included by both
  `Classes/XangModLTS.uc` and `Classes/XangModTO.uc`.
- Elo name tags: LTS shows `[elo] Name` whenever the backend is configured; TO shows it
  only while `bRankedEnabled` is on (`ShowEloTag`, `bTagRequiresRanked` on the actor).
- Player: `voteranked`, `voteunranked`, chat `!rankedhelp`.
- Admin (typed directly, no `admin` prefix -- same as every other command in §8.2):
  `RankedMode 1|0`, `adminstartmatch`, `adminterminatematch`, `RankedExtend [s]`,
  `RankedAbandon`, `RankedMinTeamSize n`, `RankedMaxTeamSize n`, `RankedPing`. While a match
  is live, `AdminRestartMap`, `AdminChangeMap`/`AdminGoto*` and restart/change-map votes are
  refused. RCON is deliberately not guarded.
- Config goes in the **server's** `UDKGame.ini` only, never `DefaultXangMod.ini`:

```
[XangMod.XangModRanked]
bRankedEnabled=false
RankedEndpoint=https://<project-ref>.supabase.co/functions/v1/ranked
RankedServerToken=<secret>
RankedMinTeamSize=2
RankedMaxTeamSize=16
QueueCountdown=30
LeaverPauseSeconds=120
```

## 9. Testing

### 9.1 Host testing hides real bugs

Running "Create Game" as a listen server is fine for UI work, weapon damage values and
basic functionality. It is **not** sufficient for anything else, because as the host you are
`IsLocallyControlled()` and every branch gated on that takes the wrong path. Netcode,
replication, stamina validation, the parry rollback, riposte grace, hit-trade arbitration
and first-person spectate all behave differently.

**Verify as a client connected to a dedicated server.** This is not optional for combat or
netcode changes; it is where the bugs are.

### 9.2 Test with real latency

Netcode issues only appear with real network delay. Several systems in §5 exist purely to
compensate for latency and do nothing at 0 ping — the parry rollback hold is literally
sized from the defender's one-way ping, so at 0 ping it is 0 and the code path is never
exercised.

### 9.3 Before believing any result

1. Compile clean.
2. Confirm the change is in the package — `grep -a -c "<new function name>"` against
   `CookedSDK/XangMod_*/XangMod.u` (§2.2). Zero means you are testing an old build.
3. After any cook, re-copy the 15 `.upk` content packages (§2.3), or every custom mesh
   silently fails.
4. Then test, as a client, on a dedicated server.

### 9.4 What to check after touching combat

- Counter-parry out of Release **and** out of a riposte, on at least one weapon from each
  shape group — a plain weapon, a polearm with its own `PlayStateAnimation`, and a shield.
- The parry box in all three modes: default, `bXangModParryBox=false`, and
  `bSkeletalParry=true` (§3.4 — these were inert for a long time).
- Trades: near-simultaneous swings should still trade; clearly staggered ones should not.
- Riposte with incoming damage, to confirm flinch immunity during the grace period.

### 9.5 What to check after touching spectate

See §6.5 for the full spectate test plan.

### 9.6 Warning-count regression check

A clean build currently produces a large number of warnings, most inherited from vanilla
AOC patterns (variable shadowing, config/localized import failures, `DefaultProperties`
data issues in weapon and character classes). The useful signal is the *fingerprints*:

- `Missing '=' in default properties assignment: AOCOwner.ParryComponent.SetScale3D(...)`
  reappearing means the weapon-attachment include has been moved back inside a
  `DefaultProperties` block (§3.4).
- `'Var' is not allowed here` means a var landed after a function, usually because an
  include was inserted in the wrong place (§4.3).
- `GetInterpolatedRotation: Missing return value` is a known debug leftover in
  `Include/Pawn/Animation.uci` — the function is declared to return a `Rotator`, has no
  return statement, and has no callers anywhere in the tree.

### 9.7 Heir RCON regression checks

Run the dependency-free checks from the repository root with Node.js:

```sh
node --test tests/*.test.mjs
```

These execute selected UnrealScript function bodies with explicit engine mocks. They
cover listener selection and status, accepted-session ownership, objective skip outcomes,
warmup exclusion, nested death finalization, and round/objective metadata. They do not
compile UnrealScript or replace the dedicated-server checks below.

Before shipping a cooked package:

1. Compile clean and verify the loaded `CookedSDK` package contains
   `XangModFinishDeathReport` and `XangModCanReuseListener`.
2. Connect Heir and a second RCON client. Verify both receive complete 65–69 sequences,
   including after seamless travel and replacement of a carried vanilla listener.
3. End an LTS round by elimination and suicide, then end a match with a final kill.
   Compare opcode 67's final victim death count with the live kill feed. Verify one final
   burst and correct return behavior for a prevented death.
4. Force a match end during warmup: no round-zero result may appear. Check ordinary
   timeout/admin ends and the next round's reset as well.
5. Exercise TO autoskip with absent, rejected, synchronous and asynchronous Kismet events.
   A later genuine completion after a failed skip must add a completed objective.

---

---

## 10. Changelog

Chronological history, newest first. Carried over verbatim apart from heading levels
and two include paths that the September 2026 split renamed.

### Heir RCON event delivery and results (2026-11-02)

**Source checks passed; not yet compiled or tested on a dedicated server.** Heir's event
target must be a valid XangMod listener, and diagnostics report the actual game and target.
Round results wait for an in-progress pawn death to finish accounting before their stats
are sent. Forced warmup ends produce no round-zero result, and a failed objective autoskip
no longer labels the next real completion as skipped. Packet IDs and field layouts remain
unchanged. General RCON admin-command fixes, leaver snapshots and capability negotiation
are outside this patch.

### TO Elo tags gated on ranked mode (2026-10-20)

**Not yet compiled or tested in game.** Elo name tags on TO now appear only while
`bRankedEnabled` is on (`ShowEloTag` / `bTagRequiresRanked` on `XangModRanked`). LTS is
unchanged: it tags whenever the backend is configured. Previously TO tagged whenever
configured, even with ranked off.

### Ranked admin commands fixed to PlayerController execs (2026-10-12)

**Not yet compiled or tested in game.** The ranked admin commands were `exec function` on the
GameInfo, so a client's console never dispatched to them -- `RankedMode`, `RankedPing`, etc.
came back "unrecognized". They are now PlayerController `exec` + `reliable server function`
pairs (§8.1) in `Include/PC/AdminCommands.uci`, forwarding to the plain GameInfo methods in
`Include/XangModRankedHooks.uci`. Typed directly, no `admin` prefix: `RankedMode 1|0`,
`RankedPing`, `RankedMinTeamSize n`, `RankedMaxTeamSize n`, `RankedExtend [s]`, `RankedAbandon`.

### Ranked on TO (2026-10-12)

**Not yet compiled or tested in game.** TO now runs the same matchmade ranked mode as LTS
instead of Elo tags only. The ranked hook block moved out of `Classes/XangModLTS.uc` into a
shared `Include/XangModRankedHooks.uci` included by both LTS and TO; `Game/Match.uci` spawns
with `InitRanked(false)` for both; the player commands (`voteranked`/`voteunranked`,
`adminstartmatch`, `adminterminatematch`, map-change guards) and `!rankedhelp` now cover both
modes. `bRankedEnabled` still gates everything -- off means normal play with Elo tags only.

### RCON connection diagnostics: AdminRConStatus (2026-10-10)

**Not yet compiled or tested in game.** For the report that RCON refuses other clients on
servers tracked by heir.gg (heir.gg holds a persistent RCON event feed). `admin
AdminRConStatus` prints the listener state and bound port, any non-XangMod `AOCRCon`
actor, every session (peer, state, age, last data) and rejected logins this map. Sessions
now log `connection from`, `authenticated`, and `login failed ... <reason>` (password
rejected, frame not 50 bytes, no password within 2s) via `LogAlwaysInternal`.

### Ranked LTS ported from MustMod (2026-10-10)

**Not yet compiled or tested in game.** Ranked LTS and Elo name tags, ported from Love
Norström's MustMod fork (MIT, modelled on ImbaMod). See §8.9. Differences from MustMod:
the `switch` on the HTTP action became an `if / else` chain (§4.6); the ranked `EndGame`
call lives in `Game/Match.uci` because that file already defines `EndGame`; the actor is
spawned from `Game/Match.uci` and runs matchmade on both LTS and TO.

### RCON objective stages: opcode 69 for Team Objective (2026-10-05)

**Not yet compiled or tested in game** -- written without a UDK build.

TO reported nothing about objectives: 66 carries the engine team scores, which stay 0-0
in TO, so a consumer could only tell which side won. Opcode 69 now reports each stage as
it ends, with whether the attackers completed it or a skip ended it, which side is
attacking, running completed and skipped counts, and the clock. See §7 for the fields.

- `Include/XangModTOGamemode.uci`: the `ActivateNextObjectiveStage` override reports the
  stage that just ended before calling super. `XangModSkipObjective` and both timed
  `ce skip` triggers mark the stage first, so it is reported as skipped.
- `Include/Game/RoundReporting.uci`: `XangModSendObjectiveStage` builds the event;
  `XangModSendObjectiveEnd` sends the one for the stage the match ended on, called from
  `XangModSendRoundEnd` ahead of a match-ending 66.
- `Include/Game/Vars.uci`, `Include/Game/Match.uci`: three counters, zeroed with the
  round stats when round 1 starts.
- `Classes/XangModRCon.uc`: `RCONX_OBJECTIVE_STAGE = 69` and `SendObjectiveStage`.

Opcodes 65-68 are unchanged. LTS, TD and every other mode send no 69.

### RCON round stats: round 1 reset, real team damage, wired counters (2026-10-01)

Found by comparing a consumer's capture of opcodes 65-68 (562 opcode 67 rows) against the
source. **Not yet compiled or tested in game** -- written without a UDK build.

- **Pre-round activity was reported as round 1.** `ProcessResolvedAttack` bumps
  `EnemyDamageDealt` and `DamageTaken` before `TakeDamage` runs, so a swing on an
  invulnerable pre-round player still counted, as did pre-round parries and feints. Nothing
  cleared them before the first round: after a 60-90 second pre-round, round 1 showed
  roughly twice the damage of a normal round. The `StartRound` override in
  `Include/Game/Match.uci` now calls `XangModResetRoundStats` when `XangModRoundNumber`
  becomes 1, which zeroes kills, deaths, assists, score and every counter opcode 67 sends.
  `AOCPlayerController.TeamDamageDealt` (the penalty system) is not touched.
- **`teamDamage` carried the parry count.** `AOCPRI.TeamDamageDealt` is the scoreboard
  "Prys" column, and that was what opcode 67 sent. A new `RealTeamDamageDealt` on the mod
  PRI accumulates real team damage and is sent instead; the parry count now also goes into
  `Parries`. Opcode 23's `teamDamageDealt` slot is unchanged and still carries parries.
- **Counters that were sent but never written.** `AllDamageTaken`, `Parries`, `MeleeHits`
  and `ProjectileHits` were declared, reset and sent, but nothing incremented them. They are
  now written in `Include/Pawn/Combat.uci`. `Blocks` and `Dodges` are still unwired.

Still open: `Deaths` in opcode 67 can miss the death that ends a round (it stays lower than
the opcode 15 kill feed). The cause was not found in this repo.

### Skeletal parry actually reaches players (2026-09-28)

Two reasons it never worked. (1) Parry-box hits are traced on the attacker's client
(`AOCWeaponAttachment` Release state skips tracing on a dedicated server), but the toggle only
synced the admin's own client and the on-possess sync was commented out - every other client
kept its own `bSkeletalParry=false`. Now `XangModSyncParryBoxToAll` pushes to every player, the
possess sync is back (collision-radius sync left commented), and the client re-applies to all
pawns, not just its own. (2) The "skeletal" box was only a thicker front box (0.18 x 0.17 x 0.35
at 10,5,-28). It is now 0.32 x 0.32 x 0.45 at 0,0,-45 on the camera socket - about 82 x 82 x 115
units (cube is +/-128) centred on the head and hanging to roughly the knees. Starting values;
tune with `XangModShowParryBoxes`. Same numbers in `Pawn/Customization.uci`,
`XangModWeaponAttachmentCode.uci` and `PC/ParryConfig.uci` - keep them identical.

### AdminEnableGoFast (2026-09-28)

Scales each class's `MaxSprintSpeedTime` on the live `AOCFamilyInfo` actors - MAA x0.5,
Vanguard x0.65, Knight x0.8 - so sprint reaches the same top speed sooner. Vanilla only
reads it server-side (`AOCPawn.HandleDebuffs`), so no client sync is needed. Helper is
`XangModAdminActions.ApplyGoFast`; `Pawn/Customization.uci` re-applies it on class assignment.

### Per-map TO stage bonus time (2026-09-28)

`[XangMod.XangModObjTimer]` overrides a stage's `BonusTime` per map without touching the
map package. New `Classes/XangModObjTimer.uc`; `ActivateNextObjectiveStage` override in
`Include/XangModTOGamemode.uci`. See §8.8.

`AdminSkipObjective` calls `CompleteObjective()` on each actor in the current stage, which
fires the map's own Complete Objective event, so doors, spawns and the next stage follow
the map's normal Kismet. `XangModSkipStage` zeroes that stage's `BonusTime` when the map
calls `ActivateNextObjectiveStage`. Does nothing to maps whose Kismet ignores the event.

### Tournament warmup no longer pollutes tracked kills/deaths (2026-09-26)

In tournament mode the pre-round (before the round starts / before `!adminreadyall`)
lets players move freely and hit/kill teammates. Those team kills and deaths were being
pushed to RCON (vanilla opcodes 15/16 KILL/SUICIDE and the deaths counter), so stat
consumers like heir.gg would credit e.g. 34 kills / 74 deaths when half the deaths came
from warmup.

- `Include/Pawn/Combat.uci` — team damage is negated entirely during the tournament
  pre-round (`IsTournamentWarmup()`), so a warmup team hit cannot kill a teammate.
- `Include/XangModPRI.uci` — `IncrementDeaths` is overridden to ignore deaths during the
  tournament pre-round, keeping warmup deaths out of the tracked `Deaths` stat.
- `Classes/XangModRCon.uc` — `GameEvent_Kill` / `GameEvent_Suicide` are suppressed during
  the tournament pre-round, so opcode 15/16 pushes never fire for warmup deaths.

The gate is `bTournamentMode && IsInState('AOCPreRound')`; `StartRound` clears
`bTournamentMode`, so the round proper is unaffected.

### Proximity chat removed; 165Hz performance notes dropped (2026-09-15)

Finishes the job started on 2026-09-02. That change pulled the voice *enabler* but
deliberately left `ClientNotifyPlayerTalking` and `bEnableProximityChat` in place; both are
now gone too, along with the rest of the proximity path.

Removed:

- `Include/PC/ProximityChat.uci` — `ServerNotifyTalkingState`,
  `NotifyNearbyPlayersOfTalker`, `ClientReceiveProximityTalker`, `ClientNotifyPlayerTalking`
  and `ProcessVOIPQueue`. The file is now a tombstone and is no longer included by
  `XangModPlayerController.uci`; **delete it.**
- `Include/PC/Vars.uci` — `ProximityChatDistance`, `bEnableProximityChat`, `bIsTalking`,
  `NearbyTalkers`.
- `Include/PC/Effects.uci` — the matching `DefaultProperties` entries.
- `DefaultXangMod.ini` — the whole `[AOC.AOCPlayerController]` proximity block.

One consequence: with the mod's `ClientNotifyPlayerTalking` override gone, vanilla AOC's
implementation applies again. The mod's version had been rewritten from a per-notification
`DynamicActors` sweep for performance, so vanilla's is the more expensive one — but it only
runs if the engine reports a remote talker, which cannot happen with no voice codec.

Also removed: the "165Hz server optimization" section of this document. The tickrate work
was never finished, so the figures, thresholds and proposals in it described an intention
rather than the build. The two source documents behind it disagreed with each other on the
acceptance threshold (6.06 ms vs 8.33 ms), on whether the XangMod NPC classes counted as
implemented, and on whether the target was 120Hz or 165Hz. `XangModNPC_New` and
`XangModNPC_New_NoMove` still exist in `Classes/`; the `GetServerTickTime` and
`StartPollingServerTickTime` console commands still work and are listed in §8.6.

### Voice chat removed (2026-09-02)

EU players reported voice not working at all, so the whole voice arc is out rather than
left half-working. Removed from `Include/PC/*.uci`: `ToggleSpeaking` (the
enabler -- without it AOCPlayerController's empty stub applies again and the keybind does
nothing), `GBA_ToggleSpeaking`, the `VoiceTrace` / `VoiceStatus` / `VoiceFix` execs, the
5-second `XangModVoiceSweepTick` timer and local-talker claim, and the four `bXangModVoice*`
vars. Removed from `Include/Game/*.uci`: the `PostLogin` override, `XangModSetupVoiceMuteList`
and `XangModVoiceChannelOf`.

Kept: the netspeed half of `XangModRepairPersistedConfig` (the proximity half went with the
voice code). `VoiceDebug` became `NetDebug` with its voice lines stripped, because it also
carried the saturation and auto-netspeed diagnostics, which are staying.

Left alone: `ClientNotifyPlayerTalking` and `bEnableProximityChat`. That proximity filtering
predates this work and is now inert with the enabler gone; say the word if it should go too.

Changelog
=========

Note: The base values in this document are taken from Mercs Mod 1.995 (thanks GIRU GIRU for providing the numbers for this).

---

### 2.0.2
* Increased messer feint recovery on LMB/overhead (0.3 -> 0.325)
* Increased messer feint recovery on stabs (0.43 -> 0.45)
* Increased messer feint recovery on combos (0.535 -> 0.55)
* Increased longsword feint recovery on LMB/overhead (0.2 -> 0.225)
* Increased longsword feint recovery on combos (0.5 -> 0.525)
* Increased feint recovery on LMB/overhead for all polearms except halberd (0.2 -> 0.3)
* Increased feint recovery on stabs for all polearms except halberd (0.4 -> 0.45)
* Increased feint recovery on combos for all polearms except halberd (0.5 -> 0.55)
* Doubled handle tracers on polearms (this should reduce the amount of handlehits that occur)
* Increase horizontal turncap on all daggers, meaning you can turn faster (75000 -> 85000)
* Reduce turncap on halberd (55000 -> 45000)

### 2.0.1
* Fixed buggy handlehits on polearms from the previous patch
* Reduced halberd knockback on overhead/LMB from 34500 -> 30000
* Reduced halberd knockback on stab from 30175 -> 29000

### 2.0.0

**General Gameplay**

* Added mechanic to cancel ripostes into parries at any time<sup>1</sup>
* Ripostes are no longer flinchable during release state<sup>2</sup>
* MAA stamina on kill increased from 30 to 50
* MAA dodge out of parry cost increased from 25 to 30<sup>3</sup>
* MAA attack lockout after dodge decreased from 0.3 to 0.2 when dodging forwards
* MAA backpedal speed decreased from 0.85 to 0.8
* Archer projectile modifier for torso and arms increased from 2 to 2.25<sup>4</sup>

**Weapon Tweaks**

* Messer stab feint recovery increased from 0.400 to 0.435
* Messer combo feint recovery increased from 0.500 to 0.535
* Poleaxe turncap increased from 53000 to 53800
* Removed handle tracers from all polearms
* Halberd overhead windup increased from 0.600 to 0.625
* Hatchet overhead damage decreased from 95 to 85
* Hatchet swing damage decreased from 95 to 70
* Hatchet damage type for overheads and swings changed from swing to chop

**Console Commands**

* Added admingotoduel to change map to duelyard

**Notes**

* 1 - This mechanic costs 15 stamina not including the stamina drain of the parry
* 2 - Currently, ripostes are also unflinchable during windup, this makes them unflinchable at all times
* 3 - This only affects dodges during a parry, it does not affect normal dodges
* 4 - This is the damage archers take from projectiles, not the damage archer primary weapons deal. This allows light crossbow to 1 shot other archers without needing a headshot.

### 1.6.0
* Stamina values have been fully rewritten, new values can be found [here](https://docs.google.com/spreadsheets/d/1gaXfSi5lQ256lwTdCtGf68Hzlo7aJJf1jZUe5mlNTRA/edit?usp=sharing) while old values can be found [here](https://docs.google.com/spreadsheets/d/1oe2dZvHpgk-lW4AvaQkj5sE0ETmtme6Oabfw2Utof3g/edit?usp=sharing).
* Sword of War overhead damage decreased to 68 swing from 70 swing.
* Sword of War stab damage decreased to 63 pierce from 77.5 pierce.
* Sword of War stab windup decreased to 0.625 seconds from 0.7 seconds.
* Sword of War LMB release decreased to 0.5 seconds from 0.525 seconds.
* Sword of War stab release decreased to 0.375 seconds from 0.4 seconds.
* Sword of War stab feint recovery increased to 0.45 seconds from 0.4 seconds.

### 1.5.0
* Feint window increased on 2h weapons for both combos and normal attacks by 0.05
* Reduce throwing axe ammo to 1 and throwing knife ammo to 2
* Reduce initial projectile speed for firepots from 2000 to 1500
* Increase greatsword combo times on overhead and slash to 0.7
* Increase broadsword stab release to 0.35 and overhead release to 0.4

### 1.4.0

Feint window changes:
* Feint window reduction out of combos increased to (0.275) from (0.25)
* Feint recovery changes reverted for:
* 2H Longsword LMB reverted to (0.2) from (0.36)
* 2H Longsword overhead reverted to (0.2) from (0.36)
* 2H Messer stab reverted to (0.4) from (0.46)
* Greatsword LMB reverted to (0.2) from (0.26)
* Greatsword overhead reverted to (0.2) from (0.26)
* Greatsword stab reverted to (0.4) from (0.46)
* Claymore stab reverted to (0.4) from (0.46)

Feint recovery changes decreased for:
* 2H Longsword stab reduced to (0.45) from (0.52) - pre v1.2.0 was (0.4)
* 2H Messer LMB reduced to (0.3) from (0.36) - pre v1.2.0 was (0.2)
* 2H Messer overhead reduced to (0.3) from (0.36) - pre v1.2.0 was (0.2)
* 1H All Weapons stab reduced to (0.45) from (0.475) - pre v1.2.0 was (0.4)

Feint recovery changes remaining at 1.3.0 values for:
* 1H All weapons LMB will remain at (0.35) - pre v1.2.0 was (0.3)
* 1H All weapons overhead will remain at (0.35) - pre v1.2.0 was (0.3)
* 2H Sword of War LMB will remain at (0.28) - pre v1.2.0 was (0.2)
* 2H Sword of War overhead will remain at (0.28) - pre v1.2.0 was (0.2)
* Poleaxe LMB will remain at (0.18) - pre v1.2.0 was (0.2)
* Poleaxe overhead will remain at (0.18) - pre v1.2.0 was (0.2)
* Quaterstaff LMB will remain at (0.32) - pre v1.2.0 was (0.2)
* Quarterstaff overhead will remain at (0.32) - previously (0.2)
* Quarterstaff stab will remain at (0.46) - pre v1.2.0 was (0.4)

### 1.3.0
* Moved kick tracer down so it is now jumpable (Z=-10 -> Z=-65)
* Readded CauseEvent, but it now displays in chat when used (it can be useful to map makers sometimes)
* Fixed some sling zoom bugs
* Bardiche overhead damage type changed (CHOP -> CUT)
* Bardiche overhead damage increased (100 -> 105)
* Sword of War overhead release time decreased (0.525 -> 0.5)
* Quarterstaff overhead & LMB windups increased (0.4 & 0.45 -> 0.5)
* Waraxe overhead & LMB windups increased (0.4 & 0.45 -> 0.5)
* Holy Water Sprinkler overhead & LMB windups increased (0.4 & 0.45 -> 0.5)
* Flinch duration for two-handed weapons increased (0.9 -> 1.0)

#### 1.2.1
* Longsword stab feint recovery increased from (0.4) -> (0.52)
* Messer stab feint recovery increased from (0.4) -> (0.46)
* All 1H stab feint recoveries increased from (0.475) -> (0.52)
* Sword of war overhead / LMB feint recovery increased from (0.2 -> 0.28)
* Smoke pot and oil pot no longer flinch

### 1.2.0

#### KNIGHT PRIMARY WEAPONS
Poleaxe
* Horizontal swing feint recovery decreased from (0.2) to (0.18)
* Overhead feint recovery decreased from (0.2) to (0.18)

Bearded Axe
* Horizontal swing windup increased from (0.525) to (0.55)
* Stab windup increased from (0.55) to (0.6)
* Overhead stamina drain increased from (26) to (29)

Grand Mace
* Overhead windup increased from (0.575) to (0.6)
* Overhead release decreased from (0.6) to (0.575)

Longsword (2 Handed)
* Horizontal swing feint recovery increased from (0.2) to (0.36)
* Overhead feint recovery increased from (0.2) to (0.36)

Longsword (1 Handed)
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

Messer (2 Handed)
* Overhead release time decreased from (0.6) to (0.575)
* Horizontal swing feint recovery increased from (0.2) to (0.36)
* Overhead feint recovery increased from (0.2) to (0.36)

#### KNIGHT TERTIARY WEAPONS
Throwing Knives
* Damage to archer head decreased to (76) from (86)

Throwing Axes
* Damage to archer head decreased to (119) from (135)

#### VANGUARD PRIMARY WEAPONS
Greatsword
* Overhead windup increased from (0.55) to (0.575)
* Horizontal swing feint recovery increased from (0.2) to (0.26)
* Overhead feint recovery increased from (0.2) to (0.26)
* Stab feint recovery increased from (0.4) to (0.46)

Claymore
* Stab feint recovery increased from (0.4) to (0.46)

Spear
* Overhead recovery decreased from (0.725) to (0.675)
* Stab recovery decreased from (0.65) to (0.625)

Bardiche
* Alternate horizontal swing into stab combo increased from (0.7) to (0.8)

Billhook
* Alternate horizontal swing into stab combo increased from (0.7) to (0.8)
* Horizontal swing stamina drain increased from (25) to (27)
* Overhead stamina drain increased from (27) to (29)
* Stab stamina drain increased from (26) to (28)

Halberd
* Overhead release time decreased from (0.6) to (0.575)
* Alternate horizontal swing into stab combo increased from (0.7) to (0.8)

Polehammer
* Polehammer alt-LMB to stab combo (0.725 -> 0.825)

#### VANGUARD TERTIARY WEAPONS
Smoke Pots
* Ammo increased to 3
* Initial projectile speed increased from (1500) to (2000)
* Maximum projectile speed increased from (2000) to (2500)

#### MAN AT ARMS PRIMARY WEAPONS
Broadsword
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

Norse Sword
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

Falchion
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

Hatchet
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

War Axe
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

Dane Axe
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

Mace
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

Morningstar
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

Holy Water Sprinkler
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

Quaterstaff
* Horizontal swing feint recovery increased from (0.2) to (0.32)
* Overhead feint recovery increased from (0.2) to (0.32)
* Stab feint recovery increased from (0.4) to (0.46)

#### MAN AT ARMS SECONDARY WEAPONS
Shortsword
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

Sabre
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

Cudgel
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

Broad Dagger
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

Hunting Knife
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

Thrusting Dagger
* Horizontal swing feint recovery increased from (0.3) to (0.35)
* Overhead feint recovery increased from (0.3) to (0.35)
* Stab feint recovery increased from (0.4) to (0.475)

#### ARCHER PRIMARY WEAPONS
Longbow
* Bodkin arrows removed
* Broadhead damage to knight to head decreased to (42) from (46)
* Broadhead damage to knight to torso decreased to (21) from (23)
* Broadhead damage to knight to legs decreased to (14) from (15)
* Broadhead damage to vanguard to head decreased to (63) from (68)
* Broadhead damage to vanguard to torso decreased to (32) from (34)
* Broadhead damage to vanguard to legs decreased to (21) from (22)
* Broadhead damage to man at arms to head decreased to (90) from (97)
* Broadhead damage to man at arms to torso decreased to (45) from (49)
* Broadhead damage to man at arms to legs decreased to (29) from (31)
* Broadhead damage to archer to head decreased to (155) from (188)
* Broadhead damage to archer to torso decreased to (102) from (110)
* Broadhead damage to archer to legs decreased to (38) from (41)
* Arrow cam removed

Shortbow
* Broadhead arrows removed
* Bodkin damage to knight to head decreased to (49) from (50)
* Bodkin damage to knight to torso decreased to (24) from (25)
* Bodkin damage to vanguard to head decreased to (65) from (68)
* Bodkin damage to vanguard to torso decreased to (33) from (34)
* Bodkin damage to vanguard to legs decreased to (21) from (22)
* Bodkin damage to man at arms to head decreased to (70) from (72)
* Bodkin damage to man at arms to torso decreased to (35) from (36)
* Bodkin damage to archer to head decreased to (99) from (115)
* Bodkin damage to archer to torso decreased to (65) from (67)
* Bodkin damage to archer to legs decreased to (24) from (25)
* Arrow cam removed

Warbow
* Broadhead arrows removed
* Bodkin damage to knight to head increased to (74) from (72)
* Bodkin damage to knight to torso increased to (37) from (36)
* Bodkin damage to knight to legs increased to (24) from (23)
* Bodkin damage to vanguard to head increased to (99) from (98)
* Bodkin damage to vanguard to torso increased to (50) from (49)
* Bodkin damage to vanguard to legs increased to (33) from (32)
* Bodkin damage to man at arms to head increased to (107) from (104)
* Bodkin damage to man at arms to torso increased to (54) from (52)
* Bodkin damage to man at arms to legs increased to (35) from (34)
* Bodkin damage to archer to head decreased to (151) from (166)
* Bodkin damage to archer to torso increased to (100) from (97)
* Bodkin damage to archer to legs increased to (37) from (36)
* Arrow cam removed

Crossbow
* Arrow cam removed

Light Crossbow
* Arrow cam removed

Heavy Crossbow
* Arrow cam removed

Javelins
* Thrown damage to archer head decreased to (167) from (189)
* Arrow cam removed

Short Spears
* Thrown damage to archer head decreased to (155) from (176)
* Arrow cam removed

Heavy Javelins
* Thrown damage to archer head decreased to (215) from (243)
* Arrow cam removed

Sling
* Pebble minimum damage to archer head decreased to (45) from (50)
* Pebble maximum damage to archer head decreased to (74) from (84)
* Lead ball minimum damage to archer head decreased to (37) from (42)
* Lead ball maximum damage to archer head decreased to (104) from (118)
* Added zoom feature
* Arrow cam removed

#### OTHER GAMEPLAY CHANGES
* Removed stamina gain on teamkills

#### ADMINISTRATOR COMMANDS
All Modes
* Added 'AdminBroadcastMessage' command - will send chat message in yellow to all players
* AdminForceSpectate will alert you that you are not logged in as an administrator if you attempt to use it as a regular user
* AdminChangeTeam will alert you that you are not logged in as an administrator if you attempt to use it as a regular user
* AdminCancelVote will alert you that you are not logged in as an administrator if you attempt to use it as a regular user
* AdminReadyAll will alert you that you are not logged in as an administrator if you attempt to use it as a regular user
* AdminChangeTeamdDamageAmount will alert you that you are not logged in as an administrator if you attempt to use it as a regular user

Tournament Mode
* Tournament mode greeting message will no longer be sent on respawn

Normal Mode
* AdminForceSpectate will display in chat on use
* AdminChangeTeam will display in chat on use
* AdminCancelVote will display in chat on use
* AdminReadyAll will display in chat on use
* AdminChangeTeamdDamageAmount will display in chat on use

#### 1.1.1
+ Added `AdminForceSpectate` command (similar to `AdminChangeTeam`) which forces a player into spectate mode
+ Added `AdminGotoMoor` and `AdminGotoDF` commands, simply aliases for `AdminChangeMap AOCLTS-Moor_p` and `AdminChangeMap AOCTO-Darkforest_p` respectively
* Fixed not being able to parry shortly after dodge
* Falchion damage reduced (95 -> 90)
* Bardiche overhead release time decreased (0.6s -> 0.55s)
* Bardiche horizontal turncap while attacking nerfed (55000 -> 49500)
* FOV console command no longer requires weapon switch if above 120. Also introduces FOV cap of 165.
* You are no longer able to parry ballista bolts
* Improved projectile hit detection again (uses a directional system again rather than the parry tracer)
- Removed the invisible Mercs pitchfork which was selectable
- Removed standing health regen on king (now same as vanilla)
- Removed `CauseEvent` / `CE` admin commands

#### 1.1.0
+ Fists always flinch
+ Added `GetAdmins` console command which tells you a list of logged-in admins
* F10 suicide delay reduced (5.0s -> 1.0s)
* Improved hit detection for projectiles
* Kick flinches (unless the other player has a shield raised)
* Shield heavy bash stuns a raised shield
* Spear overhead/long attack knockback reduced by 15% (31500 -> 26775)
* Halberd stab knockback reduced by 15% (35500 -> 30175)
* Longsword LMB damage reduced (84 -> 79)
* Norse sword stab damage reduced (59 -> 57)
* Bubble reduced (50 -> 39)
* Reduced weapon sheath times on all bows, crossbows and sling (0.5s -> 0.2s)
* Javelins can't be fliched while raised (fixes parry lockout issue)
- Disabled team flinch during pre-game warmup
- Removed PauseBreak exploit which allowed a non-admin to unpause


#### 1.0.2
* Firepots and smokepots are no longer parryable by non-shield weapons
- Projectiles don't flinch you if they hit a teammate

#### 1.0.1
* Projectiles can no longer be backparried
- Fists can no longer parry projectiles

### 1.0.0
+ Added the ability to parry projectiles with normal weapons (15 stamina)
+ If you attack a teammate, you get flinched (they still take damage)
+ Man-at-Arms is now locked out of attacking for 300ms after dodging
* ~~Reverted bubble size back to vanilla (50 -> 39)~~
* Raised SoW stab windup (0.65 -> 0.7)
* Raised SoW stab damage (68 -> 77.5)
* Raised SoW overhead windup (0.525 -> 0.55)
* Raised SoW combo speeds (all 0.675 -> 0.7)
- Removed the flinch/stun effect from kick
