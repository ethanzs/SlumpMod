import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import test from 'node:test';

// Executes source-extracted UnrealScript branch logic with actor/socket mocks.
// This does not compile UnrealScript or prove native socket/travel behavior.
const root = process.env.SLUMPMOD_SOURCE_ROOT ?? path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const clean = source => source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
function functionBody(source, name, optional = false) {
  const text = clean(source);
  const match = new RegExp(`(?:function|event)\\s+(?:\\w+\\s+)?${name}\\s*\\([^)]*\\)\\s*\\{`).exec(text);
  if (!match) {
    if (optional) return null;
    throw new Error(`Missing source function ${name}`);
  }
  let end = match.index + match[0].length;
  const start = end;
  let depth = 1;
  while (depth && end < text.length) {
    if (text[end] === '{') depth++;
    if (text[end] === '}') depth--;
    end++;
  }
  assert.equal(depth, 0, `${name} body must be balanced`);
  return text.slice(start, end - 1);
}
function compile(source, name, optional = false) {
  let body = functionBody(source, name, optional);
  if (body === null) return null;
  body = body
    .replace(/local\s+(?:array<\w+>|\w+)\s+([^;]+);/g, 'let $1;')
    .replace(/foreach\s+WorldInfo\.AllActors\(class'(\w+)',\s*(\w+)\)/g, 'for ($2 of WorldInfo.AllActors(classes.$1))')
    .replace(/foreach\s+Lines\(Line\)/g, 'for (Line of Lines)')
    .replace(/class'(\w+)'/g, 'classes.$1')
    .replace(/\bnone\b/g, 'null')
    .replace(/\bstring\(/g, 'String(')
    .replace(/\.Length\b/g, '.length')
    .replace(/\.AddItem\(/g, '.push(')
    .replace(/\s@\s/g, ' + " " + ')
    .replace(/\s\$\s/g, ' + ');
  // Bare locals have Unreal's zero/none defaults; mock actor reference locals
  // start at null, and containers start empty. New helper locals are checked here.
  body = body.replace(/let ([^;]+);/g, (_, names) => `let ${names.split(',').map(name => {
    const key = name.trim();
    return `${key} = ${key === 'Lines' ? '[]' : key.startsWith('b') ? 'false' : 'null'}`;
  }).join(', ')};`);
  return new Function('scope', `with (scope) { ${body} }`);
}
const serverSource = read('Include/Game/Server.uci');
const rconSource = read('Classes/XangModRCon.uc');
const adminSource = read('Include/PC/AdminCommands.uci');
const init = compile(serverSource, 'InitRemoteConsole');
const status = compile(adminSource, 'ServerAdminRConStatus');
const reusable = compile(rconSource, 'XangModCanReuseListener', true);
const listening = compile(rconSource, 'XangModIsListening', true);
const findListener = compile(rconSource, 'XangModFindListener');
const classes = {
  AOCRCon: {name: 'AOCRCon', default: {RConPort: 27960}},
  XangModRCon: {name: 'XangModRCon', default: {RConPort: 27960}},
  XangModRConSession: {name: 'XangModRConSession'},
  OtherRCon: {name: 'OtherRCon'}
};
for (const entry of Object.values(classes)) entry.toString = () => entry.name;
const RCON_Initialized = 'Initialized', RCON_Listening = 'Listening', RCON_Closing = 'Closing';
const STATE_Listening = 'STATE_Listening';
const cast = actor => actor && ['mod','session'].includes(actor.kind) ? actor : null;
const sessionCast = actor => actor?.kind === 'session' ? actor : null;
function environment(options = {}) {
  const events = [], actors = [];
  const scope = {
    classes, NM_DedicatedServer: 'dedicated', RemoteConsole: null,
    XangModRCon: cast, XangModRConSession: sessionCast,
    AOCGame: value => value?.isAOCGame ? value : null,
    GetCurrentMap: () => 'AOCLTS-Moor_p', MapCycleIndex: 0,
    LogAlwaysInternal: message => events.push(['log', message]),
    PlayerReplicationInfo: {bAdmin: true},
    ClientDisplayConsoleMessage: message => events.push(['console', message]),
    WorldInfo: {NetMode: options.netMode ?? 'dedicated', Game: null, AllActors(type) {
      return actors.filter(a => !a.bDeleteMe && (type === classes.AOCRCon || cast(a)));
    }},
    Spawn: () => {
      events.push(['spawn']);
      if (options.spawnFailure) return null;
      return add('mod', {RConState: RCON_Initialized, LinkState: 'STATE_Initialized', XangModBoundPort: 0});
    }
  };
  function add(kind, props = {}) {
    const actor = {
      kind, Class: classes[kind === 'mod' ? 'XangModRCon' : kind === 'session' ? 'XangModRConSession' : kind === 'foreign' ? 'OtherRCon' : 'AOCRCon'],
      RConPort: 27960, XangModBoundPort: 27960, bDeleteMe: false, ParentLink: null,
      AcceptClass: classes.XangModRConSession, RConState: RCON_Listening, LinkState: STATE_Listening, Sessions: [],
      Close() {events.push(['close', this]); return true;},
      Destroy() {events.push(['destroy', this]); if (props.destroyFailure) return false; this.bDeleteMe = true; return true;},
      GameEvent_MapChanged() {events.push(['map', this]);},
      XangModStatusLines(lines) {lines.push(`status for ${this.Class.name}`);},
      XangModStateName() {return this.RConState;},
      toString() {return this.Class.name;},
      ...props
    };
    const helperScope = extra => ({...actor, self: actor, classes, RCON_Initialized, RCON_Listening, RCON_Closing, STATE_Listening,
      XangModRCon: cast, XangModRConSession: sessionCast, ...extra});
    actor.XangModCanReuseListener = port => reusable?.(helperScope({RequiredPort: port}));
    actor.XangModIsListening = () => listening?.(helperScope());
    actors.push(actor); return actor;
  }
  return {scope,events,actors,add,run() {init(scope); return scope.RemoteConsole;}};
}
const actions = (env, kind) => env.events.filter(e => e[0] === kind);

test('cold start routes to the new actor while reporting that binding is pending', () => {
  const env=environment(); const selected=env.run();
  assert.equal(selected?.kind,'mod'); assert.equal(selected.XangModIsListening(),false);
  assert.equal(actions(env,'spawn').length,1);
  assert.ok(actions(env,'log').some(([,line])=>/waiting.*bind/i.test(line)));
  assert.ok(!actions(env,'log').some(([,line])=>/routed to listening/i.test(line)));
});
test('foreign vanilla listener is retired before a replacement is spawned', () => {
  const env = environment(), vanilla = env.add('vanilla');
  env.scope.RemoteConsole = vanilla;
  const selected = env.run();
  assert.equal(selected?.kind, 'mod');
  assert.equal(vanilla.bDeleteMe, true);
  const order = env.events.map(e => e[0]);
  assert.ok(order.indexOf('close') < order.indexOf('destroy'));
  assert.ok(order.indexOf('destroy') < order.indexOf('spawn'));
  assert.equal(actions(env,'map')[0][1], selected);
});
test('seamless travel retains the active valid listener and its accepted sessions', () => {
  const env = environment(), other = env.add('mod'), active = env.add('mod');
  const session = env.add('session', {ParentLink: active}); active.Sessions.push(session);
  env.scope.RemoteConsole = active;
  assert.equal(env.run(), active);
  assert.deepEqual(active.Sessions, [session]);
  assert.equal(actions(env,'spawn').length, 0); assert.equal(actions(env,'destroy').length,0);
  assert.equal(other.bDeleteMe,false);
});
for (const kind of ['foreign', 'vanilla']) {
  for (const order of ['before', 'after']) {
    test(`a ready listener survives a same-config-port ${kind} actor enumerated ${order}`, () => {
      for (const alreadyActive of [false, true]) {
        const env=environment();
        const other=order==='before' ? env.add(kind) : null;
        const ready=env.add('mod');
        const unrelated=other ?? env.add(kind);
        if (alreadyActive) env.scope.RemoteConsole=ready;
        assert.equal(env.run(),ready);
        assert.equal(unrelated.bDeleteMe,false);
        assert.equal(actions(env,'close').length,0);
        assert.equal(actions(env,'destroy').length,0);
        assert.equal(actions(env,'spawn').length,0);
      }
    });
  }
}
test('an existing initialized listener remains the pending route beside an unrelated actor', () => {
  const env=environment();const foreign=env.add('foreign');
  const pending=env.add('mod',{RConState:RCON_Initialized,LinkState:'STATE_Initialized',XangModBoundPort:0});
  env.scope.RemoteConsole=pending;
  assert.equal(env.run(),pending);
  assert.equal(foreign.bDeleteMe,false);assert.equal(actions(env,'spawn').length,0);
  assert.ok(actions(env,'log').some(([,line])=>/another actor.*configured|configured.*another actor/i.test(line)));
});
test('a native ready listener takes precedence over an initialized current target, which is retired', () => {
  const env=environment();const pending=env.add('mod',{RConState:RCON_Initialized,LinkState:'STATE_Initialized',XangModBoundPort:0});
  const ready=env.add('mod');env.scope.RemoteConsole=pending;
  assert.equal(env.run(),ready);assert.equal(pending.bDeleteMe,true);
  assert.equal(actions(env,'spawn').length,0);
  assert.deepEqual(actions(env,'destroy').map(([,actor])=>actor),[pending]);
});
test('a session or a listener not bound to its own configured port is never adopted', () => {
  const env=environment(); env.add('session');const other=env.add('mod',{RConPort:29000});
  assert.equal(env.run()?.RConPort,27960);
  assert.equal(other.bDeleteMe,false);
  assert.equal(actions(env,'spawn').length,1);
});
test('a vanilla listener on another port remains untouched', () => {
  const env=environment();const other=env.add('vanilla',{RConPort:29000});
  assert.equal(env.run()?.kind,'mod');assert.equal(other.bDeleteMe,false);
  assert.equal(actions(env,'close').length,0);assert.equal(actions(env,'destroy').length,0);
});
test('an unrelated custom listener is not destroyed to claim its port', () => {
  const env=environment();const foreign=env.add('foreign');
  assert.equal(env.run(),null);
  assert.equal(foreign.bDeleteMe,false);assert.equal(actions(env,'spawn').length,0);
  assert.ok(actions(env,'log').some(([,line])=>/conflict|foreign|occupied/i.test(line)));
});
for (const order of ['before', 'after']) {
  test(`an unresolved foreign conflict leaves vanilla intact when enumerated ${order}`, () => {
    const env=environment();
    if (order==='before') env.add('foreign');
    const vanilla=env.add('vanilla');
    if (order==='after') env.add('foreign');
    assert.equal(env.run(),null);assert.equal(vanilla.bDeleteMe,false);
    assert.equal(actions(env,'close').length,0);assert.equal(actions(env,'destroy').length,0);
    assert.equal(actions(env,'spawn').length,0);
  });
}
test('failed vanilla retirement aborts replacement without a false readiness message', () => {
  const env=environment();env.add('vanilla',{destroyFailure:true});
  assert.equal(env.run(),null);assert.equal(actions(env,'spawn').length,0);assert.equal(actions(env,'map').length,0);
  assert.ok(actions(env,'log').some(([,line])=>/failed|cannot/i.test(line)));
});
test('failed spawn leaves no event target and states the failure', () => {
  const env=environment({spawnFailure:true});
  assert.equal(env.run(),null);assert.equal(actions(env,'map').length,0);
  assert.ok(actions(env,'log').some(([,line])=>/failed|cannot/i.test(line)));
});
test('invalid custom listener does not masquerade as a ready event target', () => {
  const env=environment();const invalid=env.add('mod',{RConState:RCON_Closing});
  assert.equal(env.run(),null);assert.equal(invalid.bDeleteMe,false);assert.equal(actions(env,'spawn').length,0);
});
test('non-dedicated games do not replace their console', () => {
  const env=environment({netMode:'listen'}), prior=env.add('vanilla');env.scope.RemoteConsole=prior;
  assert.equal(env.run(),prior);assert.equal(env.events.length,0);
});
test('status reports the actual event target rather than an unrelated custom listener', () => {
  const env=environment();env.add('mod');const actual=env.add('vanilla');
  env.scope.WorldInfo.Game={isAOCGame:true,Class:{toString:()=> 'AOCGame'},RemoteConsole:actual};
  status(env.scope);
  const lines=actions(env,'console').map(([,line])=>line);
  assert.ok(lines.some(line=>line.includes('AOCRCon')));
  assert.ok(lines.some(line=>/65.?69|round telemetry|extended round/i.test(line)));
  assert.ok(!lines.includes('status for XangModRCon'));
});
test('status displays the current custom listener and runtime game class', () => {
  const env=environment();const actual=env.add('mod');
  env.scope.WorldInfo.Game={isAOCGame:true,Class:{toString:()=> 'XangMod.XangModLTS'},RemoteConsole:actual};
  status(env.scope);
  const lines=actions(env,'console').map(([,line])=>line);
  assert.ok(lines.includes('status for XangModRCon'));
  assert.ok(lines.some(line=>line.includes('XangMod.XangModLTS')));
});
test('accepted sessions attach to their actual owner regardless of enumeration order', () => {
  const env=environment();env.add('mod',{RConPort:29000});const accepting=env.add('mod');
  const session=env.add('session',{Owner:accepting});
  assert.equal(findListener({...env.scope,...session}),accepting);
});
test('a session without its owner falls back to the validated game event target', () => {
  const env=environment();env.add('mod',{RConPort:29000});const actual=env.add('mod');
  env.scope.WorldInfo.Game={isAOCGame:true,RemoteConsole:actual};
  assert.equal(findListener({...env.scope,RConPort:27960,Owner:null}),actual);
  // A session's own RConPort is the class default and says nothing about the listener.
  assert.equal(findListener({...env.scope,RConPort:29000,Owner:null}),actual);
});
test('deleted listeners and accepted sessions cannot become a session parent', () => {
  const env=environment();const deleted=env.add('mod',{bDeleteMe:true});const session=env.add('session');
  env.scope.WorldInfo.Game={isAOCGame:true,RemoteConsole:session};
  assert.equal(findListener({...env.scope,RConPort:27960,Owner:deleted}),null);
  assert.equal(findListener({...env.scope,RConPort:27960,Owner:session}),null);
});
test('readiness checks native state, bound port and the accepting class', () => {
  const env=environment();
  for (const props of [{LinkState:'STATE_Ready'},{XangModBoundPort:0},{AcceptClass:null}]) {
    const actor=env.add('mod',props);
    assert.equal(actor.XangModIsListening(),false);
    assert.equal(actor.XangModCanReuseListener(27960),false);
  }
});

// Production, 4-7 November 2026: hosts whose live listener port (5557) differed from the
// class default lost every game event after the first map change and dropped clients on
// each one after that. Listeners must be judged by their own port.
const hostPort = {RConPort: 5557, XangModBoundPort: 5557};
test('travel keeps a listener whose runtime port differs from the class default, with its sessions', () => {
  const env = environment(), active = env.add('mod', hostPort);
  const session = env.add('session', {ParentLink: active, RConPort: 27960}); active.Sessions.push(session);
  env.scope.RemoteConsole = active;
  assert.equal(env.run(), active);
  assert.deepEqual(active.Sessions, [session]);
  assert.equal(actions(env,'spawn').length, 0); assert.equal(actions(env,'destroy').length, 0);
  assert.equal(actions(env,'map')[0][1], active);
});
test('a carried listener is found by sweep when the new game has no event target yet', () => {
  const env = environment(), active = env.add('mod', hostPort);
  active.Sessions.push(env.add('session', {ParentLink: active}));
  assert.equal(env.run(), active);
  assert.equal(actions(env,'spawn').length, 0);
});
test('the listener holding the socket and sessions wins over the empty target left by the old rule', () => {
  const env = environment(), holding = env.add('mod', hostPort);
  holding.Sessions.push(env.add('session', {ParentLink: holding}));
  const empty = env.add('mod', {RConPort: 5557, RConState: RCON_Initialized, LinkState: 'STATE_Initialized', XangModBoundPort: 0});
  env.scope.RemoteConsole = empty;
  assert.equal(env.run(), holding);
  assert.equal(empty.bDeleteMe, true);
  assert.equal(actions(env,'spawn').length, 0);
  assert.equal(actions(env,'map')[0][1], holding);
});
test('between two pending listeners the one with sessions is kept and the idle one retired', () => {
  const env = environment(), pending = {RConPort: 5557, RConState: RCON_Initialized, LinkState: 'STATE_Initialized', XangModBoundPort: 0};
  const idle = env.add('mod', pending), withSessions = env.add('mod', pending);
  withSessions.Sessions.push(env.add('session', {ParentLink: withSessions}));
  env.scope.RemoteConsole = idle;
  assert.equal(env.run(), withSessions);
  assert.equal(idle.bDeleteMe, true);
});
test('a listener on another port is never retired as a duplicate', () => {
  const env = environment(), active = env.add('mod', hostPort);
  const elsewhere = env.add('mod', {RConPort: 6000, RConState: RCON_Initialized, LinkState: 'STATE_Initialized', XangModBoundPort: 0});
  env.scope.RemoteConsole = active;
  assert.equal(env.run(), active);
  assert.equal(elsewhere.bDeleteMe, false);
  assert.equal(actions(env,'destroy').length, 0);
});
test('a session attaches to a non-default-port target when ownership is unavailable', () => {
  const env = environment(), actual = env.add('mod', hostPort);
  env.scope.WorldInfo.Game = {isAOCGame: true, RemoteConsole: actual};
  assert.equal(findListener({...env.scope, RConPort: 27960, Owner: null}), actual);
});
