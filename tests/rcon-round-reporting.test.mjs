// Execute the actual UnrealScript function bodies with explicit engine stubs.
// This checks ordering and guards; it does not replace a UDK compile/server test.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';

const root = process.env.SLUMPMOD_SOURCE_ROOT ?? path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const match = read('Include/Game/Match.uci');
const reporting = read('Include/Game/RoundReporting.uci');
const pawn = read('Include/Pawn/Core.uci');
const strip = text => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
function extract(source, name) {
  const text = strip(source);
  const found = new RegExp(`function\\s+(?:(?:bool|int|XangModObjectiveReport)\\s+)?${name}\\s*\\(([^)]*)\\)\\s*\\{`).exec(text);
  if (!found) return null;
  const start = found.index + found[0].length;
  let end = start, depth = 1;
  for (; depth; end++) {
    assert.ok(end < text.length, `Unclosed ${name}`);
    if (text[end] === '{') depth++;
    if (text[end] === '}') depth--;
  }
  return {params: found[1].split(',').filter(v => v.trim()).map(v => v.trim().split(/\s+/).at(-1)), body: text.slice(start, end - 1)};
}
function bind(source, name, state) {
  const fn = extract(source, name);
  if (!fn) return null;
  const body = fn.body
    .replace(/local\s+(\S+)\s+([^;]+);/g, (_, type, names) => names.split(',').map(name =>
      `let ${name.trim()} = ${type === 'bool' ? 'false' : type === 'int' ? '0' : type === 'XangModObjectiveReport' ? '{bValid:false}' : 'null'};`).join('\n'))
    .replace(/XangModRoundScores\(AgathaScore, MasonScore, Goal\);/g, '[AgathaScore, MasonScore, Goal] = XangModRoundScores();')
    .replace(/`\{GAMEMODE\}/g, 'GameCast')
    .replace(/\bnone\b/gi, 'null')
    .replace(/super\./g, 'engine.')
    .replace(/\.Length\b/g, '.length')
    .replace(/@/g, '+ " " +');
  return new Function('state', `with (state) { return function(${fn.params.join(',')}) {${body}}; }`)(state);
}
function game({round = 1, objective = false} = {}) {
  const sent = [], trace = [];
  const state = {
    XangModRoundNumber: round, XangModDeathDepth: 0,
    bXangModRoundEnding: false, bXangModMatchEnded: false, bXangModMatchEndEmitted: false,
    bXangModRoundEndPending: false, XangModPendingRoundNumber: 0, XangModPendingWinningTeam: -1,
    XangModPendingMatchEnding: 0, XangModPendingAgathaScore: 0, XangModPendingMasonScore: 0,
    XangModPendingMap: '', XangModPendingObjectiveReport: {bValid: false},
    XangModObjCompleted: 0, XangModObjSkipped: 0, XangModObjSkipMark: 0,
    Ranked: null, scores: [1, 0, 7], map: 'AOCLTS-Moor_p', victim: {Deaths: 0},
    CurrentObjectiveStage: 1, AllObjectives: [{}, {}, {}], AttackingTeam: 0, TheWinningTeam: 0, TimeLeft: 70,
    EFAC_None: -1, self: null, WorldInfo: {},
    AOCGame: value => value, AOCTeamObjective: value => objective ? value : null, AOCTUT: () => null,
    XangModRCon: value => value, GameCast: value => value,
    XangModRoundReportingEnabled: () => true,
    XangModRoundMapName: () => state.map,
    XangModRoundScores: () => state.scores,
    XangModRoundWinnerTeamIndex: () => 0,
    XangModRoundTeamIndex: value => value,
    XangModResetRoundStats() { trace.push('reset'); state.victim.Deaths = 0; },
    LogAlwaysInternal() {},
    engine: {StartRound() { trace.push('start-super'); }, AOCEndRound() {}, EndGame() {}, Died() { return true; }}
  };
  state.self = state;
  state.WorldInfo.Game = state;
  state.RemoteConsole = {
    SendRoundStart(...args) { sent.push({opcode: 65, args}); },
    SendRoundEnd(...args) { sent.push({opcode: 66, args}); },
    SendObjectiveStage(...args) { sent.push({opcode: 69, args}); },
  };
  state.XangModSendRoundStats = () => {
    sent.push({opcode: 67, deaths: state.victim.Deaths});
    sent.push({opcode: 68, count: 1});
  };
  for (const name of ['XangModSendRoundEnd', 'XangModFlushRoundEnd', 'XangModBeginDeathReport', 'XangModFinishDeathReport',
    'XangModCaptureObjectiveStage', 'XangModCaptureObjectiveEnd', 'XangModSendObjectiveReport', 'XangModSendObjectiveStage', 'XangModSendObjectiveEnd']) {
    const fn = bind(reporting, name, state);
    if (fn) state[name] = fn;
  }
  for (const name of ['StartRound', 'AOCEndRound', 'EndGame']) state[name] = bind(match, name, state);
  state.Died = bind(pawn, 'Died', state) ?? ((...args) => state.engine.Died(...args));
  return {state, sent, trace};
}

test('pawn game cast separates macro expansion from cast arguments', () => {
  assert.doesNotMatch(strip(pawn), /`\{GAMEMODE\}\(/,
    'adjacent parentheses are consumed as macro arguments, leaving a bare class name');
  assert.match(strip(pawn), /ModGame\s*=\s*`\{GAMEMODE\}\s+\(WorldInfo\.Game\);/);
});

test('ending warmup keeps the engine call but emits no round zero', () => {
  const {state, sent} = game({round: 0});
  let ended = 0;
  state.engine.EndGame = () => ended++;
  state.EndGame(null, 'TimeLimit');
  assert.equal(ended, 1);
  assert.deepEqual(sent, []);
});

for (const mode of ['elimination', 'suicide', 'match-winning kill']) {
  test(`${mode} finishes death accounting before the complete round burst`, () => {
    const {state, sent} = game();
    state.engine.Died = () => {
      if (mode === 'match-winning kill') state.EndGame(null, 'TimeLimit');
      else state.AOCEndRound();
      assert.deepEqual(sent, [], 'the boundary must wait for the rest of Died');
      state.victim.Deaths++;
      return true;
    };
    assert.equal(state.Died(null, null, {}), true);
    assert.deepEqual(sent.map(row => row.opcode), [66, 67, 68]);
    assert.equal(sent[1].deaths, 1);
    assert.equal(state.XangModDeathDepth, 0);
  });
}

test('a prevented death returns false without inventing a boundary', () => {
  const {state, sent} = game();
  state.engine.Died = () => false;
  assert.equal(state.Died(null, null, {}), false);
  assert.equal(state.XangModDeathDepth, 0);
  assert.deepEqual(sent, []);
});

test('nested pawn death wrappers flush only at the outermost return', () => {
  const {state, sent} = game();
  let nesting = 0;
  state.engine.Died = () => {
    if (nesting++ === 0) {
      state.Died(null, null, {});
      assert.deepEqual(sent, []);
      state.victim.Deaths++;
    } else {
      state.AOCEndRound();
      state.victim.Deaths++;
    }
    return true;
  };
  state.Died(null, null, {});
  assert.deepEqual(sent.map(row => row.opcode), [66, 67, 68]);
  assert.equal(sent[1].deaths, 2);
  assert.equal(state.XangModDeathDepth, 0);
});

test('the queued result keeps its boundary map, number and scores', () => {
  const {state, sent} = game();
  state.engine.Died = () => {
    state.AOCEndRound();
    state.map = 'changed-after-boundary';
    state.scores = [99, 99, 7];
    state.victim.Deaths++;
    return true;
  };
  state.Died(null, null, {});
  assert.deepEqual(sent[0].args, [0, 'AOCLTS-Moor_p', 1, 1, 0, 0]);
});

test('nested EndGame and repeated EndGame emit only one final result', () => {
  const {state, sent} = game();
  state.engine.AOCEndRound = () => state.EndGame(null, 'TimeLimit');
  state.engine.Died = () => {
    state.AOCEndRound();
    state.EndGame(null, 'TimeLimit');
    state.victim.Deaths++;
    return true;
  };
  state.Died(null, null, {});
  state.EndGame(null, 'TimeLimit');
  assert.deepEqual(sent.map(row => row.opcode), [66, 67, 68]);
  assert.equal(sent[0].args[5], 1);
});

test('time or admin ends outside a death still report immediately', () => {
  const {state, sent} = game();
  state.EndGame(null, 'TimeLimit');
  assert.deepEqual(sent.map(row => row.opcode), [66, 67, 68]);
});

test('the final objective is captured once and remains next to the final burst', () => {
  const {state, sent} = game({objective: true});
  state.map = 'AOCTO-CompForest_p';
  state.XangModObjCompleted = 1;
  state.engine.Died = () => {
    state.EndGame(null, 'TimeLimit');
    assert.deepEqual(sent, []);
    state.CurrentObjectiveStage = 2;
    state.TimeLeft = 999;
    state.victim.Deaths++;
    return true;
  };
  state.Died(null, null, {});
  assert.deepEqual(sent.map(row => row.opcode), [69, 66, 67, 68]);
  assert.deepEqual(sent[0].args, ['AOCTO-CompForest_p', 1, 2, 3, 1, 0, 2, 0, 70]);
  assert.equal(state.XangModObjCompleted, 2);
});

test('a missing listener loses no pending state and reports a diagnostic', () => {
  const {state} = game();
  let logged = 0;
  state.RemoteConsole = null;
  state.LogAlwaysInternal = () => logged++;
  state.EndGame(null, 'TimeLimit');
  assert.equal(state.bXangModRoundEndPending, false);
  assert.equal(logged, 1);
});

test('pending nonfinal death boundary promotes to final exactly once', () => {
  const {state,sent}=game({objective:true});
  state.engine.Died=()=>{
    state.AOCEndRound();
    assert.equal(state.XangModPendingMatchEnding,0);
    state.EndGame(null,'TimeLimit');
    state.EndGame(null,'TimeLimit');
    state.victim.Deaths++;
    return true;
  };
  state.Died(null,null,{});
  assert.deepEqual(sent.map(x=>x.opcode),[69,66,67,68]);
  assert.equal(sent[1].args[5],1);
  assert.equal(state.XangModObjCompleted,1);
  assert.equal(sent[2].deaths,1);
});

test('nonreporting mode preserves Died without collecting boundaries',()=>{
  const {state,sent}=game();
  state.XangModRoundReportingEnabled=()=>false;
  let calls=0;
  state.engine.Died=()=>{calls++;state.EndGame(null,'TimeLimit');return false;};
  assert.equal(state.Died(null,null,{}),false);
  assert.equal(calls,1);
  assert.equal(state.XangModDeathDepth,0);
  assert.deepEqual(sent,[]);
});

test('leaf LTS wrapper surrounds base TD cast miss',()=>{
  const {state,sent}=game();
  const baseState={...state,GameCast:()=>null,engine:{Died(){state.AOCEndRound();state.victim.Deaths++;return true;}}};
  const baseDied=bind(pawn,'Died',baseState);
  state.engine.Died=baseDied;
  assert.equal(state.Died(null,null,{}),true);
  assert.deepEqual(sent.map(x=>x.opcode),[66,67,68]);
  assert.equal(sent[1].deaths,1);
  assert.equal(state.XangModDeathDepth,0);
});

test('direct end guard also suppresses pre-round AOCEndRound',()=>{
  const {state,sent}=game({round:0});
  state.AOCEndRound();
  assert.deepEqual(sent,[]);
  assert.equal(state.bXangModRoundEndPending,false);
});
