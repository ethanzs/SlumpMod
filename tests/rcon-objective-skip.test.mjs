import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

const source = readFileSync(new URL('../Include/XangModTOGamemode.uci', import.meta.url), 'utf8');
const reportingSource = readFileSync(new URL('../Include/Game/RoundReporting.uci', import.meta.url), 'utf8');

function functionBody(name, text = source) {
    const signature = new RegExp(`function (?:\\w+ )?${name}\\([^)]*\\)\\s*\\{`).exec(text);
    assert(signature, `Missing ${name}`);
    const start = signature.index + signature[0].length;
    let depth = 1;
    let end = start;
    while (depth && end < text.length) {
        if (text[end] === '{') depth++;
        if (text[end] === '}') depth--;
        end++;
    }
    assert.equal(depth, 0, `Unclosed ${name}`);
    return text.slice(start, end - 1);
}

// Executes the real skip dispatch and both Timer branches after a narrow syntax
// translation, then the actual objective capture/wrapper/send functions. Kismet
// activation is mocked: these are source behavior checks, not an Unreal compiler
// or map integration test.
function translate(body) {
    return body.replace(/\/\/[^\n]*/g, '')
        .replace(/local array<SequenceObject> AllConsoleEvents;/g, 'let AllConsoleEvents = [];')
        .replace(/local (?:SeqEvent_Console|Sequence|AOCGame|AOCTeamObjective) (\w+);/g, 'let $1 = null;')
        .replace(/local XangModObjectiveReport (\w+);/g, 'let $1 = {bValid: false};')
        .replace(/local int (\w+);/g, 'let $1 = 0;')
        .replace(/local bool (\w+);/g, 'let $1 = false;')
        .replace(/class'SeqEvent_Console'/g, "'SeqEvent_Console'")
        .replace(/\bNone\b|\bnone\b/g, 'null')
        .replace(/\.Length\b/g, '.length');
}

const triggerBody = translate(functionBody('TriggerConsoleEvent'));
const timerBody = functionBody('Timer');
const skipStart = timerBody.indexOf('// CE Autoskip');
const skipEnd = timerBody.indexOf('// Only update scoreboard');
assert(skipStart >= 0 && skipEnd > skipStart, 'Could not identify the autoskip Timer branch');
const runAutoskip = new Function('scope', `with (scope) { ${translate(timerBody.slice(skipStart, skipEnd))} }`);
const makeTrigger = new Function('scope', `with (scope) { return function(EventName) { ${triggerBody} }; }`);
const reportingFunctions = [
    ['XangModCaptureObjectiveStage', 'Stage, bMatchEnd'],
    ['XangModSendObjectiveReport', 'RCon, Report'],
    ['XangModSendObjectiveStage', 'Stage, bMatchEnd']
].map(([name, params]) => [name, new Function('scope',
    `with (scope) { return function(${params}) { ${translate(functionBody(name, reportingSource))} }; }`)]);

function fixture(compForest, events, hasSequence = true) {
    const reports = [];
    const scope = {
        CurrentObjectiveStage: 0,
        TimeLeft: compForest ? 60 : 10,
        XangModObjSkipMark: 0,
        XangModRoundNumber: 1,
        XangModObjCompleted: 0,
        XangModObjSkipped: 0,
        AllObjectives: [{}, {}],
        TheWinningTeam: -1,
        AttackingTeam: 0,
        EFAC_None: -1,
        reports,
        RemoteConsole: {SendObjectiveStage(...args) { reports.push(args); }},
        AOCTeamObjective: game => game,
        AOCTUT: () => null,
        XangModRCon: console => console,
        XangModRoundMapName: () => 'AOCTO-CompForest_p',
        XangModRoundTeamIndex: faction => faction,
        bCECompForestAutoskipFired: false,
        bCEAutoskipEnabled: true,
        bCEAutoskipFired: false,
        IsCompForest: () => compForest,
        SeqEvent_Console: event => event,
        WorldInfo: {GetGameSequence: () => hasSequence ? {
            FindSeqObjectsByClass(_class, _recursive, into) { into.push(...events); }
        } : null}
    };
    scope.self = scope;
    scope.TriggerConsoleEvent = makeTrigger(scope);
    for (const [name, makeFunction] of reportingFunctions)
        scope[name] = makeFunction(scope);
    return scope;
}

function assertReport(scope, outcome, completed, skipped) {
    assert.equal(scope.reports.length, 1);
    assert.equal(scope.reports[0][4], outcome);
    assert.equal(scope.reports[0][6], completed);
    assert.equal(scope.reports[0][7], skipped);
    assert.equal(scope.XangModObjCompleted, completed);
    assert.equal(scope.XangModObjSkipped, skipped);
}

for (const [mode, compForest] of [['CompForest', true], ['generic', false]]) {
    test(`${mode}: absent sequence cannot mark a later real completion as skipped`, () => {
        const scope = fixture(compForest, [], false);
        runAutoskip(scope);
        assert.equal(scope.XangModObjSkipMark, 0);
        scope.XangModSendObjectiveStage(0, false);
        assertReport(scope, 1, 1, 0);
    });

    test(`${mode}: absent skip event leaves no skip marker`, () => {
        const scope = fixture(compForest, [null, {ConsoleEventName: 'unrelated'}]);
        runAutoskip(scope);
        assert.equal(scope.XangModObjSkipMark, 0);
        scope.XangModSendObjectiveStage(0, false);
        assertReport(scope, 1, 1, 0);
    });

    test(`${mode}: rejected activation leaves no skip marker and does not retry every tick`, () => {
        let attempts = 0;
        const scope = fixture(compForest, [{ConsoleEventName: 'skip', CheckActivate() { attempts++; return false; }}]);
        runAutoskip(scope);
        runAutoskip(scope);
        assert.equal(scope.XangModObjSkipMark, 0);
        assert.equal(attempts, 1);
        scope.XangModSendObjectiveStage(0, false);
        assertReport(scope, 1, 1, 0);
    });

    test(`${mode}: synchronous completion sees its marker and does not re-tag the next stage`, () => {
        let markedDuringActivation;
        const scope = fixture(compForest, [{ConsoleEventName: 'skip', CheckActivate(game) {
            markedDuringActivation = game.XangModObjSkipMark;
            game.XangModSendObjectiveStage(game.CurrentObjectiveStage, false);
            game.CurrentObjectiveStage++;
            return true;
        }}]);
        runAutoskip(scope);
        assert.equal(markedDuringActivation, 1);
        assert.equal(scope.CurrentObjectiveStage, 1);
        assert.equal(scope.XangModObjSkipMark, 0);
        assertReport(scope, 2, 0, 1);
    });

    test(`${mode}: accepted asynchronous activation retains the stage marker`, () => {
        const scope = fixture(compForest, [{ConsoleEventName: 'skip', CheckActivate() { return true; }}]);
        runAutoskip(scope);
        assert.equal(scope.CurrentObjectiveStage, 0);
        assert.equal(scope.XangModObjSkipMark, 1);
        assert.equal(scope.reports.length, 0);
        scope.XangModSendObjectiveStage(0, false);
        assertReport(scope, 2, 0, 1);
    });

    test(`${mode}: one rejected event cannot erase another accepted event`, () => {
        const attempted = [];
        const scope = fixture(compForest, [true, false, true].map((accepted, index) => ({
            ConsoleEventName: 'skip', CheckActivate() { attempted.push(index); return accepted; }
        })));
        runAutoskip(scope);
        assert.deepEqual(attempted, [0, 1, 2]);
        assert.equal(scope.XangModObjSkipMark, 1);
        scope.XangModSendObjectiveStage(0, false);
        assertReport(scope, 2, 0, 1);
    });
}
