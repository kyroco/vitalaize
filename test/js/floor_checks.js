// Checks of the Floor tab's browser script, priv/static/js/floor.js.
//
// The script draws the board's sessions as people in an office. Here it
// runs under Node with a made-up page and a canvas that draws nothing, so
// what its people do can be checked without a browser: where they stand,
// how the games go, what a session says when it leaves.
//
//   node test/js/floor_checks.js <check>     run one check
//   node test/js/floor_checks.js             run them all
//
// Each check prints "ok <check>" or "FAIL <check>: why" and the run ends
// with status 1 if any failed. Every run uses the same made-up random
// numbers and the same time of day, so a check gives the same answer every
// time. test/wallboard/floor_script_test.exs runs each one as a test.
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");

// FLOOR_JS names another copy of the script to check: a copy broken on
// purpose, to see that a check catches the break. FLOOR_SEED is a number
// added to every run's made-up random numbers, to try other runs by hand.
const FILE = process.env.FLOOR_JS || path.join(__dirname, "..", "..", "priv", "static", "js", "floor.js");
const SOURCE = fs.readFileSync(FILE, "utf8");
// The script keeps its state to itself. This hands the checks the state and
// the lists of lines, by adding one line before the hook is registered.
const HOOK = "window.WallboardHooks.Floor = {";
const OPENED = SOURCE.replace(HOOK, "window.__F = F; window.__T = { BYE, SPATS, SPAT_END }; " + HOOK);

class Failed extends Error {}
// A check's claim: `why` says what is wrong when it does not hold.
const check = (holds, why) => { if (!holds) throw new Failed(why); };
// What a check needs in place before it can claim anything.
const need = (holds, why) => { if (!holds) throw new Failed("the check could not be set up: " + why); };

// One member of the cast, as Wallboard.Floor.cast sends it.
const m = (key, crew, role, mood, more) => Object.assign({
  key, crew, role, mood, tag: key, urgency: 0, long: false, days: 0, helpers: 0, tool: "claude", ghost: false,
  says: mood === "needs" ? "Which plan should I use?" : mood === "working" ? "Running the tests" : null,
}, more || {});
const idle = (count) => Array.from({ length: count }, (_, i) => m("i" + i, i % 2 ? "alpha" : "beta", "worker", "wandering"));
const mixed = () => [
  m("f1", "kyroco-main", "foreman", "working"), m("a1", "kyroco-main", "worker", "working", { helpers: 2 }),
  m("a2", "kyroco-main", "worker", "needs", { urgency: 1 }), m("a3", "kyroco-main", "worker", "needs", { urgency: 3 }),
  m("a4", "kyroco-main", "worker", "working", { long: true }), m("a5", "kyroco-main", "worker", "wandering"),
  m("a6", "kyroco-main", "worker", "asleep", { days: 3 }), m("f2", "vitalaize", "foreman", "needs", { urgency: 4 }),
  m("b1", "vitalaize", "worker", "working"), m("b2", "vitalaize", "worker", "working", { tool: "codex" }),
  m("b3", "vitalaize", "worker", "packed", { days: 9 }), m("b4", "vitalaize", "worker", "packed", { days: 12, tool: "codex" }),
  m("c1", "korium-docs", "worker", "working", { ghost: true }), m("c2", "korium-docs", "worker", "wandering"),
  m("c3", "korium-docs", "worker", "wandering"),
];

// Opens the Floor on a board `w` by `h` pixels showing `cast`. Gives back
// the script's state (F), its lists of lines (T), and ways to move it on.
const open = ({ w, h, cast, seed }) => {
  need(OPENED !== SOURCE, "floor.js no longer has the line the checks hook into: " + HOOK);
  let s = ((seed || 1) + (Number(process.env.FLOOR_SEED) || 0)) >>> 0;
  const random = () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const brush = new Proxy({}, {
    get: (t, k) => (k === "measureText" ? (text) => ({ width: String(text).length * 6 }) : k in t ? t[k] : () => {}),
    set: (t, k, v) => { t[k] = v; return true; },
  });
  const stage = { clientWidth: w, clientHeight: h, appendChild() {} };
  const handlers = {}, keys = {};
  let resized = null;
  const canvas = () => ({
    width: 0, height: 0, style: {}, getContext: () => brush, setAttribute() {},
    addEventListener: (name, fn) => { handlers[name] = fn; },
    getBoundingClientRect: () => ({ left: 0, top: 0, width: stage.clientWidth, height: stage.clientHeight }),
  });
  const page = {
    console, __random: random,
    requestAnimationFrame: () => 1, cancelAnimationFrame() {},
    getComputedStyle: () => ({ getPropertyValue: () => "", fontFamily: "sans-serif" }),
    document: {
      documentElement: { dataset: {} }, body: {}, visibilityState: "visible",
      getElementById: () => null, querySelector: () => null, createElement: canvas,
      addEventListener: (name, fn) => { keys[name] = fn; }, removeEventListener() {},
    },
    ResizeObserver: function (fn) { resized = fn; this.observe = () => {}; this.disconnect = () => {}; },
  };
  page.window = { matchMedia: () => ({ matches: false }), devicePixelRatio: 2, ResizeObserver: page.ResizeObserver };
  vm.createContext(page);
  // The same random numbers every run, and always ten in the morning, so
  // lunch (which comes more often at midday) keeps to one timetable.
  vm.runInContext(`Math.random = __random;
    (() => { const Real = Date, TEN = Real.UTC(2026, 0, 15, 15, 0, 0);
      globalThis.Date = class extends Real { constructor(...a) { if (a.length) super(...a); else super(TEN); } static now() { return TEN; } }; })();`, page);
  vm.runInContext(OPENED, page);
  const hook = Object.create(page.window.WallboardHooks.Floor);
  hook.el = { dataset: { cast: JSON.stringify(cast), tz: "America/New_York" }, querySelector: () => stage, classList: { add() {} } };
  hook.pushEvent = () => {};
  hook.mounted();
  const F = page.window.__F;
  need(F.S, "the room was not laid out");
  return {
    F, T: page.window.__T,
    // Moves the floor on by `secs`, calling `each` after every frame.
    step(secs, each) { for (let i = 0; i < Math.round(secs * 30); i++) { hook.advance(1 / 30); if (each) each(); } },
    // The server sends a new cast.
    cast(next) { hook.el.dataset.cast = JSON.stringify(next); hook.updated(); },
    // A tap on the spot (x, y) of the room, in the room's own units.
    tap(x, y) { handlers.click({ clientX: (x / F.W) * stage.clientWidth, clientY: (y / F.H) * stage.clientHeight }); },
    key(k, down) { keys[down ? "keydown" : "keyup"]({ key: k }); },
    resize(nw, nh) { stage.clientWidth = nw; stage.clientHeight = nh; resized(); },
    random,
  };
};

// Moves the floor on until `test` holds, for `max` seconds at most. Says
// whether it came to hold.
const until = (world, max, test) => {
  for (let i = 0; i < max * 30; i++) { if (test()) return true; world.step(1 / 30); }
  return test();
};

// The piece of furniture a walker is inside, if any. Touching its edge
// does not count.
const inside = (F, o) => F.S.solids.find((r) => o.x > r.x0 + 0.6 && o.x < r.x1 - 0.6 && o.y > r.y0 + 0.6 && o.y < r.y1 - 0.6);
const desks = (F) => F.S.solids.filter((r) => r.name === "desk").map((r) => r.x0 + "," + r.y0).join(" ");

// You walk about: a tap somewhere every few seconds, and the keys.
const walkAbout = (world, frame) => {
  const F = world.F;
  if (frame % 80 === 0) world.tap(world.random() * F.W, world.random() * F.H);
  if (frame % 45 === 0) {
    "wasd".split("").forEach((k) => world.key(k, false));
    if (world.random() < 0.5) world.key("wasd"[Math.floor(world.random() * 4)], true);
  }
};

// Gives back a look to take after every frame: nobody may be inside a
// piece of furniture, not a person, not you, not the cat, not whoever
// brings the water. What is meant to be inside a box is let through:
// someone at their own desk, on a picnic bench or on the couch, with the
// step into the seat and the step back out of it; the two arguing across
// the far side of the ping pong table, with their step back from it; and
// the cat up on the table or the couch.
const watchFurniture = (world, room) => {
  const F = world.F, lastSat = new Map(), lastSpat = new Map();
  const holds = (r, p) => p.x > r.x0 && p.x < r.x1 && p.y > r.y0 && p.y < r.y1;
  return () => {
    const where = ", in the room " + room + " at " + F.t.toFixed(1) + " seconds";
    for (const a of F.actors.values()) {
      check(isFinite(a.x) && isFinite(a.y), a.key + " has no place on the floor");
      const r = inside(F, a);
      // In their own seat: sat still in it, or inside its box on the way in.
      const own = r && ((r.name === "desk" && a.seat && holds(r, a.seat)) || (r.name === "picnic" && a.where === "lunch")
        || (r.name === "couch" && a.where === "poi:couch"));
      if (own || (!a.path.length && (a.where === "seat" || a.where === "lunch" || a.where === "poi:couch"))) lastSat.set(a.key, F.t);
      if (a.spat) lastSpat.set(a.key, F.t);
      if (!r) continue;
      const ok = own
        || ((r.name === "desk" || r.name === "picnic" || r.name === "couch") && F.t - (lastSat.has(a.key) ? lastSat.get(a.key) : -9) < 1.2)
        || (r.name === "pong" && F.t - (lastSpat.has(a.key) ? lastSpat.get(a.key) : -9) < 0.7);
      check(ok, a.key + " (" + (a.leaving ? "leaving" : a.where || "nowhere yet") + ") is inside the " + r.name + where);
    }
    const you = inside(F, F.boss), cat = F.cat.on || F.cat.jump ? null : inside(F, F.cat);
    const carrier = F.cooler.runner ? inside(F, F.cooler.runner) : null;
    check(!you, "you are inside the " + (you || {}).name + where);
    check(!cat, "the cat is inside the " + (cat || {}).name + where);
    check(!carrier, "the water carrier is inside the " + (carrier || {}).name + where);
  };
};

const CHECKS = {
  // A session joining a crew moves the crew's desks along, with the room
  // otherwise as it was. Whoever a desk lands on steps clear of it.
  desks_move_and_land_on_nobody() {
    [[6, 7], [7, 6], [9, 11], [4, 5]].forEach(([from, to], n) => {
      const crew = (count) => Array.from({ length: count }, (_, i) => m("w" + i, "alpha", "worker", i === 1 ? "asleep" : "working", { days: 2 }));
      const world = open({ w: 1600, h: 900, cast: crew(from), seed: 9 + n });
      const F = world.F;
      world.step(1);
      // You pop up beside a desk, as a tap on whoever sits there puts you. The
      // cat sits beside the sleeper's desk, where it goes for a nap.
      const sat = F.actors.get("w0"), bed = F.actors.get("w1").seat;
      world.tap(sat.x, sat.y - 8);
      Object.assign(F.cat, { x: bed.aisle, y: bed.y + 3, path: [], state: "sit", wait: 90, on: null, jump: null });
      need(!inside(F, F.boss) && !inside(F, F.cat), "you or the cat began inside furniture");
      const room = F.S.sig, before = desks(F);
      world.cast(crew(to));
      need(F.S.sig === room && desks(F) !== before, "going from " + from + " desks to " + to + " did not move the desks and leave the room alone");
      world.step(1, () => {
        check(!inside(F, F.boss), "with " + to + " desks where there were " + from + ", you are left standing inside a " + (inside(F, F.boss) || {}).name);
        check(!inside(F, F.cat), "with " + to + " desks where there were " + from + ", the cat is left inside a " + (inside(F, F.cat) || {}).name);
      });
      // And you are on your way to a spot among the desks when they move:
      // the spot you tapped, or the way to it, may now be under one.
      const look = watchFurniture(world, "of " + from + " and " + to + " desks");
      for (let k = 0; k < 10; k++) {
        world.tap(12 + world.random() * (F.S.officeW - 30), 50 + world.random() * (F.S.corridorY - 46));
        world.step(0.2 + world.random() * 1.5, look);
        world.cast(crew(k % 2 ? from : to));
        world.step(6, look);
      }
    });
  },

  // Nobody stands or walks inside the furniture, in five rooms where the
  // cast stays as it is and you walk about by taps and keys.
  nobody_inside_the_furniture() {
    const rooms = [
      { w: 1400, h: 800, cast: mixed().concat(idle(5)), seed: 101 },
      { w: 1400, h: 800, cast: idle(3), seed: 102 },
      { w: 700, h: 420, cast: mixed(), seed: 103 },
      { w: 820, h: 1100, cast: mixed().concat(idle(4)), seed: 104 },
      { w: 1024, h: 768, cast: idle(4).concat([m("n1", "alpha", "worker", "needs", { urgency: 3 })]), seed: 105 },
    ];
    let spats = 0;
    rooms.forEach((room) => {
      const world = open(room), F = world.F, P = F.pong, look = watchFurniture(world, room.w + " by " + room.h);
      let frame = 0, was = null;
      world.step(300, () => {
        walkAbout(world, frame++);
        if (P.spat && P.spat !== was) spats++;
        was = P.spat;
        look();
      });
    });
    need(spats >= 3, "only " + spats + " ping pong arguments in the five rooms");
  },

  // The same while sessions come and go, which moves the desks, changes
  // the size of the people and so of the room, and pushes the open floor
  // down a row; and while the board itself changes size. Every walk under
  // way was planned for the room as it was a moment ago.
  nobody_inside_the_furniture_as_sessions_come_and_go() {
    const crews = ["alpha", "beta", "gamma"], moods = ["working", "working", "wandering", "wandering", "needs", "asleep", "packed"];
    [{ w: 1400, h: 800, seed: 201, sizes: null }, { w: 1024, h: 768, seed: 202, sizes: [[768, 1024], [1180, 820], [1024, 768]] }].forEach((room) => {
      let cast = idle(4).concat([m("w0", "alpha", "worker", "working"), m("w1", "alpha", "worker", "working")]), born = 0, frame = 0;
      const world = open(Object.assign({ cast }, room)), F = world.F, look = watchFurniture(world, room.w + " by " + room.h + " with sessions coming and going");
      const pick = (list) => list[Math.floor(world.random() * list.length)];
      world.step(240, () => {
        walkAbout(world, frame);
        // Every three seconds a session joins, or one ends, or one changes what it is doing.
        if (frame % 90 === 45) {
          const roll = world.random();
          if (roll < 0.4 && cast.length < 26) cast = cast.concat([m("s" + born++, pick(crews), "worker", pick(moods), { urgency: 1 + Math.floor(world.random() * 4), days: 3 })]);
          else if (roll < 0.75 && cast.length > 2) cast = cast.filter((x) => x !== cast[Math.floor(world.random() * cast.length)]);
          else cast = cast.map((x, i) => (i === Math.floor(world.random() * cast.length) ? Object.assign({}, x, { mood: pick(moods), urgency: 2, days: 3 }) : x));
          world.cast(cast);
        }
        // In one room the board changes size every twenty seconds, as an iPad turned over does.
        if (room.sizes && frame % 600 === 300) { const size = room.sizes[(frame / 600 | 0) % room.sizes.length]; world.resize(size[0], size[1]); }
        frame++;
        look();
      });
    });
    // Someone is on the way in at the door when the board changes size.
    const cast = idle(3), world = open({ w: 1400, h: 800, cast, seed: 203 }), look = watchFurniture(world, "a board resized as someone walks in");
    world.step(3);
    world.cast(cast.concat([m("new", "alpha", "worker", "working")]));
    world.step(0.2);
    world.resize(900, 600);
    world.step(30, look);
  },

  // The two playing ping pong step in for a short ball and back for a deep one.
  ping_pong_players_move() {
    const world = open({ w: 1400, h: 800, cast: idle(2), seed: 11 });
    const F = world.F, P = F.pong, gaps = [];
    let shot = null, receiver = null;
    world.step(480, () => {
      const playing = P.on && P.st === "rally" ? P.shot : null;
      if (shot && playing !== shot) {
        // That ball was played. If it came back, its receiver's paddle (6 from the feet) was where it landed.
        if (!shot.miss && !shot.fault && P.on) {
          const landed = Math.abs(shot.x1 - F.S.pong.x), stood = Math.abs(receiver.x - F.S.pong.x);
          check(Math.abs(stood - (landed + 6)) < 2, "a ball landing " + landed.toFixed(1) + " from the net was returned by a player standing " + stood.toFixed(1) + " from it");
          gaps.push(stood);
        }
        shot = null;
      }
      if (playing && !shot) { shot = playing; receiver = P.players[shot.to]; }
    });
    need(gaps.length >= 40, "only " + gaps.length + " balls came back in 8 minutes");
    check(Math.min(...gaps) < 26, "nobody ever stepped in close: the nearest return was from " + Math.min(...gaps).toFixed(1));
    check(Math.max(...gaps) > 32, "nobody ever stepped back: the furthest return was from " + Math.max(...gaps).toFixed(1));
  },

  // An argument over a point ends with the point played again (the score
  // goes back by one) or left to stand, and then play goes on.
  arguments_end_and_play_goes_on() {
    const world = open({ w: 1400, h: 800, cast: idle(5), seed: 23 });
    const F = world.F, seen = { replay: 0, stand: 0 };
    const playing = { pong: ["serve", "rally"], foos: ["drop", "play"] };
    const watch = { pong: {}, foos: {} };
    world.step(900, () => {
      ["pong", "foos"].forEach((name) => {
        const G = F[name], w = watch[name], total = G.score[0] + G.score[1];
        if (G.spat && w.spat !== G.spat) Object.assign(w, { spat: G.spat, began: F.t, score: total });
        if (w.spat && G.spat === w.spat) check(F.t - w.began < 45, "an argument at the " + name + " table was still going after 45 seconds");
        if (w.spat && G.spat !== w.spat) {
          // It is over. Nobody was called away in this check, so it ended one of the two ways.
          check(w.spat.over, "an argument at the " + name + " table stopped before anyone gave in");
          check(total === w.score - (w.spat.replay ? 1 : 0), "the score after " + (w.spat.replay ? "a replay" : "a point that stood") + " went from " + w.score + " to " + total);
          seen[w.spat.replay ? "replay" : "stand"]++;
          Object.assign(w, { spat: null, ended: F.t });
        }
        if (w.ended && (!G.on || playing[name].indexOf(G.st) >= 0)) w.ended = 0;
        if (w.ended) check(F.t - w.ended < 25, "25 seconds after an argument the " + name + " game had not gone on (it is at '" + G.st + "')");
      });
    });
    need(seen.replay >= 2 && seen.stand >= 2, "saw " + seen.replay + " replays and " + seen.stand + " points that stood in 15 minutes");
  },

  // Foosball is one a side, for the idle, and a game is first to five. A
  // room too small for the table has none, and no game.
  foosball_is_first_to_five() {
    const world = open({ w: 1400, h: 800, cast: idle(3).concat([m("w1", "alpha", "worker", "working")]), seed: 5 });
    const F = world.F, K = F.foos;
    need(F.S.foos, "this room has no foosball table");
    let games = 0, was = "";
    world.step(900, () => {
      check(K.players.length <= 2, K.players.length + " people are playing foosball");
      check(Math.max(K.score[0], K.score[1]) <= 5, "a foosball score reached " + K.score.join(" : "));
      K.players.concat(K.watch).forEach((a) => check(a.d.mood === "wandering" && !a.d.ghost, a.key + " is at the foosball table but is not idle"));
      if (K.st === "done" && was !== "done") { games++; check(Math.max(K.score[0], K.score[1]) === 5, "a foosball game ended at " + K.score.join(" : ")); }
      was = K.st;
    });
    need(games >= 2, "only " + games + " foosball games ended in 15 minutes");

    const small = open({ w: 480, h: 300, cast: idle(3), seed: 5 });
    need(!small.F.S.foos, "the small room has a foosball table after all");
    small.step(240, () => check(!small.F.foos.on, "a foosball game started in a room with no table"));
  },

  // One who starts needing you, starts working or whose session ends is
  // out of the game at once, and the game goes on with another or stops.
  called_away_from_a_game() {
    const others = { needs: { mood: "needs", urgency: 1, says: "Ship it?" }, working: { mood: "working", says: "Back to work" }, ended: null };
    ["pong", "foos"].forEach((name, n) => Object.keys(others).forEach((how, k) => {
      const cast = idle(5), world = open({ w: 1400, h: 800, cast, seed: 31 + n * 7 + k });
      const F = world.F, G = F[name], mid = name === "pong" ? "rally" : "play";
      need(until(world, 240, () => G.on && G.st === mid), "no " + name + " game got going in 4 minutes");
      const gone = G.players[k % 2].key;
      world.cast(cast.filter((x) => x.key !== gone).concat(others[how] ? [Object.assign(m(gone, "alpha", "worker", "wandering"), others[how])] : []));
      const a = F.actors.get(gone);
      check(!a || (!a.pong && !a.foos), gone + " (" + how + ") is still in the " + name + " game after the cast changed");
      let quiet = 0;
      world.step(60, () => {
        for (const b of F.actors.values()) check(!(b.pong || b.foos) || (b.d.mood === "wandering" && !b.leaving), b.key + " is in a game but is not idle");
        check(!G.on || G.players.length === 2, "the " + name + " game is on with " + G.players.length + " players");
        // A game that is on keeps moving: it is never in one state for 40 seconds.
        quiet = G.on && G.st === G.was ? quiet + 1 / 30 : 0;
        G.was = G.st;
        check(quiet < 40, "the " + name + " game sat at '" + G.st + "' for 40 seconds after " + gone + " left it");
      });
    }));
  },

  // A session that ends says a goodbye from the lists, waves, walks out of
  // the door and is gone.
  goodbye_then_out_of_the_door() {
    const world = open({ w: 1400, h: 800, cast: mixed(), seed: 3 });
    const F = world.F, B = world.T.BYE, lines = B.first.concat(B.foreman, B.robot, B.camp);
    world.step(6);
    const going = ["a5", "f1", "b3", "b4", "a2"], said = {}, waved = {}, last = {};
    world.cast(mixed().filter((x) => going.indexOf(x.key) < 0));
    world.step(90, () => going.forEach((key) => {
      const a = F.actors.get(key);
      if (!a) return;
      check(a.leaving, key + " is on the floor but is not leaving");
      if (a.bye >= 1 && a.bub && !said[key]) said[key] = a.bub.text;
      if (a.waveT > F.t) waved[key] = true;
      last[key] = { x: a.x, y: a.y };
    }));
    going.forEach((key) => {
      check(lines.indexOf(said[key]) >= 0, key + " left saying " + JSON.stringify(said[key]) + ", which is not a goodbye line");
      check(waved[key], key + " left without a wave");
      check(!F.actors.get(key), key + " is still on the floor 90 seconds after its session ended");
      check(last[key].x < 0 && Math.abs(last[key].y - F.S.door.y) < 3, key + " was last seen at " + Math.round(last[key].x) + ", " + Math.round(last[key].y) + ", not going out of the door");
    });
  },

  // One that has waited on you for half an hour lies down on the floor now
  // and then. When its session ends it gets up, says goodbye and waves
  // like anyone else: it does not leave lying flat.
  long_wait_gets_up_to_say_goodbye() {
    const cast = [m("n1", "alpha", "worker", "needs", { urgency: 4 }), m("w1", "alpha", "worker", "working"), m("w2", "alpha", "worker", "working")];
    // Its session ends while it lies flat, then at four moments while it stands.
    [null, 1, 3.5, 6, 8.5].forEach((after, n) => {
      const world = open({ w: 1400, h: 800, cast, seed: 60 + n });
      const F = world.F, a = F.actors.get("n1");
      if (after === null) need(until(world, 60, () => a.flop > 0.5), "n1 never lay down in a minute of waiting");
      else world.step(after);
      const when = after === null ? "lying flat" : after + " seconds in";
      world.cast(cast.slice(1));
      let waved = false;
      world.step(40, () => {
        if (!F.actors.get("n1")) return;
        check(a.flop <= 0, "n1, whose session ended " + when + ", is lying flat while it leaves");
        if (a.waveT > F.t) waved = true;
      });
      check(waved, "n1, whose session ended " + when + ", left without a wave");
      check(!F.actors.get("n1"), "n1, whose session ended " + when + ", is still on the floor after 40 seconds");
    });
  },

  // A session that comes back into the cast before its person is out of
  // the door stays on the floor.
  back_before_it_left() {
    [0.5, 2.5, 5, 9].forEach((wait, n) => {
      const world = open({ w: 1400, h: 800, cast: mixed(), seed: 40 + n });
      const F = world.F;
      world.step(4);
      world.cast(mixed().filter((x) => x.key !== "a5"));
      world.step(wait);
      need(F.actors.get("a5") && F.actors.get("a5").leaving, "a5 was already gone " + wait + " seconds after its session ended");
      world.cast(mixed());
      world.step(60);
      const a = F.actors.get("a5");
      check(a && !a.leaving, "a5 came back " + wait + " seconds into leaving and is not on the floor");
      check(a.x >= 4 && a.x <= F.S.W, "a5 came back but stands at " + Math.round(a.x) + ", outside the room");
    });
  },

  // Nothing draws the sign that used to sit in the middle of the floor.
  no_you_are_here_sign() {
    check(SOURCE.toUpperCase().indexOf("YOU ARE HERE") < 0, "floor.js still holds the words YOU ARE HERE");
  },
};

const asked = process.argv.slice(2);
const names = asked.length ? asked : Object.keys(CHECKS);
let failed = 0;
names.forEach((name) => {
  if (!CHECKS[name]) { console.log("FAIL " + name + ": there is no check of that name"); failed++; return; }
  try { CHECKS[name](); console.log("ok " + name); }
  catch (e) {
    if (!(e instanceof Failed)) throw e;
    console.log("FAIL " + name + ": " + e.message);
    failed++;
  }
});
process.exit(failed ? 1 : 0);
