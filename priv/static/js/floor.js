// The Floor tab in the browser: the board's sessions as little people in an
// office. The server says who everyone is and what they are doing (see
// Wallboard.Floor); this file only draws them and moves them about. All the
// art is drawn here, one small rectangle at a time; no picture is loaded.
//
// Needs JavaScript because it is a moving picture on a canvas, 30 times a
// second, which the server cannot send. Without it the page shows the same
// cast as a plain list.
(() => {
  "use strict";

  const TAU = Math.PI * 2;
  const rnd = (a, b) => a + Math.random() * (b - a);
  const pick = (list) => list[Math.floor(Math.random() * list.length)];
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const hash = (text) => {
    let h = 2166136261;
    for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 16777619); }
    return h >>> 0;
  };

  // ---- What they say when nothing real is going on ---------------------------
  // A session's own words (its question, its current step) come from the
  // server and sit in a solid bubble. These are jokes, drawn fainter and in
  // italics so nobody takes them for news.
  const SAY = {
    worker: [
      "It works on my machine.", "Who wrote this? Oh. Me.", "One more test run.", "Just a tiny refactor.",
      "Naming things is hard.", "It is always DNS.", "LGTM (did not read).", "Why is this green?",
      "Why is this red?", "Reading the docs. Desperate times.", "I will write the test later.",
      "It was a semicolon.", "99 little bugs in the code...", "Have you tried turning it off and on?",
    ],
    long: [
      "Almost done. I said that an hour ago.", "This is fine.", "Send snacks.", "Is my laptop meant to smoke?",
      "Still going. Still going.", "I can see through time.",
    ],
    watched: ["Typing faster now.", "Yes boss. On it, boss.", "Totally was not on a break."],
    foreman: [
      "I do not do the work. I supervise the work.", "Who is on the PR?", "Less typing, more shipping.",
      "Scope creep! I saw scope creep!", "Looks busy. Good.", "Is it done? How about now?",
      "My clipboard says no.", "One question at a time, people.", "Nobody merges until I say so.",
    ],
    foremanIdle: [
      "Supervising the coffee.", "A crew this good runs itself.", "I am thinking. It looks like this.",
      "Somebody give me something to inspect.",
    ],
    idle: [
      "Coffee first.", "Is it Friday yet?", "Between tasks. Honest.", "Nice plant.", "Waiting for orders, boss.",
      "Stretch break.", "Did someone say standup?", "You could archive me. Just saying.", "So... any work?",
    ],
    grass: ["Touching grass.", "So this is outside.", "Fresh air. Weird."],
    asleep: ["zzz... merge conflict... zzz", "zzz... five more minutes", "zzz... rebase... zzz", "zzz... did you forget me?"],
    packed: [
      "Archive me, boss.", "We shipped, right?", "Marshmallow?", "It was a good branch.",
      "Bag is packed. Ready when you are.", "Tell main I said goodbye.",
    ],
    robot: ["Beep.", "Boop. Compiling.", "I am not a robot. Wait.", "01101000 01101001"],
    ghost: ["Boo. My Mac is offline.", "Can anybody hear me?", "I was working. Once."],
    you: ["So many questions.", "I just wanted coffee.", "One at a time, please."],
    lunch: [
      "Who took my sandwich?", "No laptops at the table.", "Five more minutes.", "Tests can wait. Tacos cannot.",
      "I am on break. Legally.", "Is that the cat's?", "Best standup all week.",
    ],
    workingLunch: ["Working lunch. Honest.", "Crumbs in the keyboard again.", "Eating with one hand, typing with the other."],
    couch: ["Five minute break. Maybe ten.", "This couch has seen things.", "I think better sitting down.", "Do not wake me for standup."],
    coffee: ["Third cup. Do not judge.", "Hot. Hot. Hot.", "This is mostly milk.", "Now I can think."],
  };
  // Where the lunch group sits at the picnic table, far side first.
  const LUNCH = [[-12, -3], [12, -3], [-12, 16], [12, 16]];

  // Small talk: two who are near each other take turns, a line each. All of
  // it is made up and none of it is about a real session. Keep it clean.
  const CHATS = [
    ["Tabs or spaces?", "Yes.", "That is not an answer.", "It is the only answer."],
    ["Did you see the game?", "I only watch the build.", "Who won?", "Main. Barely."],
    ["Is a hot dog a sandwich?", "Is a pull request a letter?", "...", "I need to sit down."],
    ["What is for lunch?", "Tacos.", "It was tacos yesterday.", "And it worked."],
    ["My code ran on the first try.", "What did you break?", "Nothing!", "Check again."],
    ["Knock knock.", "Who is there?", "Merge.", "Merge who?", "Merge conflict. Sorry."],
    ["I named a variable 'data'.", "Bold.", "Then 'data2'.", "Stop while you are ahead."],
    ["Do you think the cat likes us?", "It sat on my keyboard.", "So yes?", "It deleted my branch."],
    ["How was your weekend?", "I do not have weekends.", "Same.", "Nice."],
    ["Is the boss watching?", "The boss is always watching.", "Look busy.", "I AM busy."],
    ["I read the whole README.", "Nobody reads the README.", "I know. It was lonely in there."],
    ["What does a foreman do all day?", "Walks. Nods. Writes things.", "I want that job."],
    ["Pineapple on pizza?", "Only on Fridays.", "Why Fridays?", "No deploys. Fewer witnesses."],
    ["My rubber duck says hi.", "Did it fix your bug?", "It just looked at me.", "Fair."],
    ["I dreamed in JSON last night.", "Was it valid?", "Trailing comma.", "A nightmare, then."],
    ["Coffee?", "I run on electricity.", "So... coffee?", "Yes."],
    ["Guess how many tests I wrote.", "Three?", "Lower.", "Two?", "...yes."],
    ["The plant looks thirsty.", "The cooler is right there.", "I am not carrying that."],
    ["Is it lunch yet?", "It is 9 AM.", "So, soon."],
    ["Nice weather.", "We are indoors.", "The window looks nice."],
    ["I fixed it.", "What was it?", "A space.", "One space?", "One space."],
    ["Who left the campfire on?", "The archived ones.", "They seem happy.", "Do not get ideas."],
    ["What is your favorite number?", "200.", "Mine is 404.", "Why?", "I can never find it."],
    ["If we finish early...", "We never finish early.", "But if.", "Then more work."],
    ["An octopus has three hearts.", "And I have zero reviews. Help.", "After lunch."],
    ["Does this look right to you?", "No.", "You did not look.", "I did not need to."],
    ["I think the cat is in charge.", "It does supervise.", "And it never answers.", "Promote it."],
    ["Ping pong later?", "You always win.", "So that is a yes?", "That is a maybe."],
    ["What are you working on?", "A thing.", "For whom?", "The boss.", "Ah. The thing."],
    ["I counted the floor tiles.", "Why?", "I was between tasks.", "How many?", "I lost count."],
    ["Do robots dream?", "Beep.", "Is that a yes?", "Boop."],
    ["Someone ate my sandwich.", "Describe it.", "Ham. Cheese. Hope.", "I saw the cat with hope."],
  ];
  const CHATS_FOREMAN = [
    ["Status?", "Almost done.", "You said that yesterday.", "I was almost done yesterday too."],
    ["Good work today.", "Really?", "Keep going and it will be."],
    ["Where is the pull request?", "In my heart.", "Put it on GitHub."],
    ["Any blockers?", "The cat is on my keyboard.", "Noted. Carry on."],
    ["How long will it take?", "Two hours.", "In real hours?", "...six."],
    ["I like your attitude.", "Thank you!", "Now I would like your tests."],
    ["Who approved this?", "You did.", "Then it is excellent."],
  ];
  // Things someone yells for no reason, and what the room says back.
  const YELL = [
    "EUREKA!", "IT COMPILES!", "WHO BROKE MAIN?", "SHIP IT!", "COFFEE!", "TESTS PASS!", "NOT IT!", "I LOVE THIS JOB!",
    "PIZZA?", "IS IT FRIDAY?", "TO THE CLOUD!", "BEHOLD!", "WHEEE!", "SNACK TIME!", "GREEN BUILD!", "ONE MORE BUG!",
    "HIGH FIVE!", "YESSS!", "TA-DA!", "PLOT TWIST!", "I FOUND IT!", "TEAMWORK!", "WHO WANTS CAKE?",
  ];
  const REPLY = ["Not me!", "Shh.", "Same!", "Nice!", "Congrats!", "Again?", "Me!", "Good for you.", "We know."];
  const PONG = {
    point: ["Ha!", "Nice shot!", "Lucky.", "Spin!", "Got you!", "Oof."],
    miss: ["Nooo.", "Ugh.", "How?!", "I blinked.", "Too fast.", "My shoe was untied."],
    out: ["Out!", "Long!", "Way out.", "That one left the building."],
    net: ["Net.", "Into the net.", "The net says no."],
    smash: ["SMASH!", "Take that!", "Boom!"],
    win: ["Winner stays!", "Who is next?", "Too easy.", "Champion!"],
    lose: ["Rematch!", "I let you win.", "My paddle slipped.", "Good game."],
    next: ["My turn!", "I am up.", "Watch this."],
    chat: ["Best of five?", "That was out.", "Watch the spin.", "My paddle is lagging.", "No slams. House rules."],
  };
  const FOOS = {
    goal: ["GOAL!", "GOOOAL!", "Back of the net!", "Top corner!"],
    lose: ["Lucky bounce.", "My goalie was asleep.", "Offside. Probably.", "I was not ready!"],
    win: ["Champion of the table!", "Unbeaten since lunch.", "Too easy."],
    chat: ["No spinning.", "Loose wrists.", "Watch the goalie.", "Next goal wins?", "Best table in the building."],
  };
  // Arguments over a point. Whoever lost the point starts, and they take
  // turns. All of it is made up. Keep it clean.
  const SPATS = {
    pong: [
      ["That was out!", "It hit the line.", "There is no line.", "There is a line in my heart."],
      ["Edge ball. My point.", "That was the floor.", "The floor is part of the table.", "It is not.", "Ask the cat."],
      ["I was not ready!", "You were holding the paddle.", "I was thinking.", "Think faster."],
      ["Double bounce!", "One bounce. I counted.", "You count from zero.", "Low blow."],
      ["That went through the net.", "Over the net.", "Through.", "Over.", "We need a camera."],
      ["My point.", "Check the replay.", "There is no replay.", "Then check the logs.", "There are no logs.", "Classic."],
      ["You moved the table.", "I did not move the table.", "It was closer before.", "Tables do not move.", "This one has wheels."],
      ["That hit your shirt.", "Shirts are in play.", "Since when?", "Since the house rules.", "Show me the pull request."],
      ["It is 2 to 1.", "It is 1 to 2.", "Same thing.", "Order matters. Ask any database."],
      ["You served too fast.", "It is called a serve.", "It is called an ambush.", "Ambushes are legal."],
    ],
    foos: [
      ["No spinning!", "That was a flick.", "It went round four times.", "A long flick."],
      ["You lifted the table!", "The floor is uneven.", "Only on your side?", "Strange, I know."],
      ["That went in and came out.", "Then it is out.", "It was in first!", "Last write wins."],
      ["My goalie was stuck.", "Oil it.", "With what?", "Try the coffee. It is slippery enough."],
      ["You scored while I was talking.", "Then stop talking.", "Never."],
      ["Goalie goals count double.", "Since when?", "Since I scored one."],
      ["You shook the table.", "I breathed.", "Breathe further away."],
    ],
  };
  const SPAT_END = {
    replay: ["Fine. Play it again.", "Okay, okay. Replay.", "Let. Do it over.", "Replay, and no more talking."],
    stand: ["Fine. Your point.", "Whatever. It stands.", "Keep it. I will win the next one.", "You win this round of talking."],
  };
  const SPAT_CROWD = ["It was in.", "It was out.", "I was not looking.", "Play on!", "Replay it.", "Can we have the table, then?", "I saw nothing."];
  // What one says on the way out when its session ends, the last word at
  // the door, and what the room says back.
  const BYE = {
    first: [
      "Good luck, everyone!", "Have a good one, team!", "Bye all! Be kind to main.", "I am off. Do not break the build.",
      "See you on the next branch!", "Good luck with the reviews!", "It has been a pleasure. Mostly.", "Keep the tests green!",
      "Have a great day, folks!", "My work here is done. Probably.", "Somebody water the plant.", "Save me a taco.",
      "Go easy on the foreman.", "Tell the cat I said bye.", "May your merges be clean!", "Good luck. You will need it. Kidding!",
      "Clocking out. Be good!", "Think of me when you read the git log.", "Have a good day. Do not work too hard.",
      "Wish me luck out there!", "It was fun. Same time tomorrow?",
    ],
    foreman: ["Crew, you are on your own. Behave.", "Keep shipping. I will know.", "Good luck, crew. Hard hats on.", "Nobody merges while I am gone. Kidding. Maybe."],
    robot: ["Beep. Goodbye, humans.", "Powering down. Good luck.", "Boop. It was an honor."],
    camp: ["Archived at last. Bye, all!", "Thanks for the marshmallows.", "Off to the big repo in the sky.", "Good luck, you lot. Keep the fire going."],
    door: [
      "Last one out turns off the lights.", "Bye for real this time.", "Do I get to keep the badge?", "Okay. Leaving now. Really.",
      "Do not all cry at once.", "And... archived.", "Good luck!", "Have a good day!", "Be good to each other.",
    ],
    reply: [
      "Bye!", "See you!", "Good luck!", "Take care!", "Have a good one!", "We will miss you!", "Bring snacks next time!",
      "Do not forget to write!", "Dibs on the chair.", "Good luck out there!", "Bye! Great work.", "Come back soon!",
    ],
  };
  // What one that needs you yells, by how loud it has become (2, 3), and
  // what a foreman adds.
  const SHOUT = {
    2: ["Boss?", "Over here!", "Hello?", "Excuse me!", "Quick question!"],
    3: ["HELLO?!", "BOSS!", "I HAVE A QUESTION!", "PLEASE!", "ANYONE?!"],
    foreman: ["TWEEET!", "THE CREW IS WAITING!", "BOSS! BOSS!", "WE ARE BLOCKED!"],
  };
  // The picket signs of one that has waited half an hour.
  const SIGNS = ["ANSWER ME", "STILL WAITING", "HELLO??", "PLS", "ON STRIKE", "BLOCKED", "DAY 3"];
  const POSTERS = [
    ["IT", "COMPILES.", "SHIP IT."], ["NO", "REFACTORS", "ON FRIDAY"], ["HANG", "IN", "THERE"],
    ["ONE", "QUESTION", "AT A TIME"], ["HAVE YOU", "TRIED", "MAIN?"],
  ];
  const GLYPHS = ["{ }", ";", "fn", "=>", "git", "01", "if", "()", "ok", "++"];

  // ---- Colors ---------------------------------------------------------------
  const SKIN = ["#f6d3b3", "#e8b98f", "#c98f62", "#9a6a44", "#6f4a2e"];
  const HAIR = ["#2b1d14", "#5a3a1f", "#a8642a", "#d9b25f", "#8a8f98", "#b5452c", "#1e2a44"];
  // One per crew: its shirts, its rug and its name on the floor.
  const CREW = ["#3b82c4", "#c4573b", "#3ba37a", "#8a5bc4", "#c49a3b", "#3ba3b8"];
  const ROOM = {
    light: {
      floor: "#eadfc8", floor2: "#e3d6bb", wall: "#c3ccd6", wallLow: "#9aa7b4", grass: "#93c46f", grass2: "#84b862",
      deskTop: "#c99a62", deskEdge: "#dcb07a", deskFront: "#a57a48", deskLeg: "#7d5a33", rug: 0.26, fence: "#8d6a45",
    },
    dark: {
      floor: "#3b404c", floor2: "#363b46", wall: "#2a2f3a", wallLow: "#1e222b", grass: "#2f5a3a", grass2: "#2a5034",
      deskTop: "#8a6a44", deskEdge: "#9c7a52", deskFront: "#6b5034", deskLeg: "#4f3a25", rug: 0.3, fence: "#5a452e",
    },
  };

  // ---- The one floor ----------------------------------------------------------
  const WALL = 30, CW = 34, CH = 34;
  const F = {
    hook: null, stage: null, canvas: null, bg: null, cast: [], actors: new Map(), S: null,
    t: 0, last: 0, shake: 0, parts: [], keys: {}, lunch: null,
    dir: {
      askT: 0, askI: 0, infoT: 1, infoI: 0, jokeT: 5, gagT: 20, lunchT: rnd(34, 48), chatT: 2.5, yellT: 7, pongT: 4, foosT: 13,
    },
    // Small talk under way, things to do a moment from now, the water left
    // in the cooler (1 is full), and the two games: ping pong and foosball.
    chats: [], later: [], cooler: { level: 1, target: 1, refillT: 0, runner: null },
    pong: {
      on: false, players: [], queue: [], score: [0, 0], games: 0, streak: 0, st: "walk", t: 0, ball: null, loose: false,
      shot: null, drop: null, want: [null, null], server: 0, rally: 0, spat: null, sinceSpat: 0, last: null, fetcher: null,
    },
    foos: {
      on: false, players: [], watch: [], score: [0, 0], st: "walk", t: 0, ball: null, men: [0, 0, 0, 0], spin: [0, 0, 0, 0],
      spat: null, sinceSpat: 0, last: null,
    },
    boss: { x: 0, y: 0, path: [], face: 1, phase: 0, moving: false, bub: null },
    cat: { x: 0, y: 0, path: [], wait: 2, state: "sit", flip: false, on: null, jump: null, goal: null, lift: 0 },
    bug: null, plane: null, tumble: null, firstCast: true, bgDirty: true, raf: 0, minute: -1,
  };
  let g = null; // whichever canvas is being drawn on

  // Art is drawn in "art pixels", each PX board pixels wide; words are drawn
  // in board pixels so they stay sharp.
  const R = (x, y, w, h, c) => { g.fillStyle = c; g.fillRect(x, y, w, h); };
  const art = (sx) => g.setTransform(F.U, 0, 0, F.U, (sx || 0) * F.U, 0);
  const ui = (sx) => g.setTransform(F.k, 0, 0, F.k, (sx || 0) * F.U, 0);
  const css = (name, fallback) => (getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback);
  const darkNow = () => {
    const t = document.documentElement.dataset.theme;
    if (t) return t === "dark";
    return !!(window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
  };
  const font = (size, weight, italic) =>
    `${italic ? "italic " : ""}${weight || 500} ${size}px ${F.fontFamily || "system-ui, sans-serif"}`;

  // The hour and minute in the board's time zone, for the sky and the clock.
  const wallTime = () => {
    try {
      const parts = new Intl.DateTimeFormat("en-US", { timeZone: F.tz, hour: "numeric", minute: "numeric", hourCycle: "h23" })
        .formatToParts(new Date());
      const get = (type) => parseInt(parts.find((p) => p.type === type).value, 10);
      return { h: get("hour"), m: get("minute") };
    } catch (_) {
      const d = new Date();
      return { h: d.getHours(), m: d.getMinutes() };
    }
  };

  // ---- Laying out the room ----------------------------------------------------
  // Each crew gets a rug with its desks on it, side by side under the wall.
  // Below the desks is the open floor: the door, the coffee, the couch and
  // you. On the right, outside, is the campfire for the ones ready to archive.
  const crewsOf = (cast) => {
    const by = new Map();
    cast.forEach((m) => { if (!by.has(m.crew)) by.set(m.crew, []); by.get(m.crew).push(m); });
    return Array.from(by.keys()).sort().map((name) => ({
      name,
      members: by.get(name).slice().sort((a, b) =>
        (a.role === "foreman" ? 0 : 1) - (b.role === "foreman" ? 0 : 1) || (a.key < b.key ? -1 : 1)),
    }));
  };

  const layout = () => {
    const w = F.stage.clientWidth, h = F.stage.clientHeight;
    if (w < 120 || h < 120) return false;
    const crews = crewsOf(F.cast);
    const fits = (px, rows) => {
      const W = Math.floor(w / px), H = Math.floor(h / px);
      const yardW = clamp(Math.round(W * 0.17), 58, 84), officeW = W - yardW;
      const cols = crews.reduce((n, c) => n + Math.ceil(c.members.length / rows), 0);
      const width = cols * CW + crews.length * 8 + Math.max(0, crews.length - 1) * 6;
      const deskBottom = WALL + 10 + (crews.length ? rows * CH : 0);
      return { px, rows, W, H, yardW, officeW, width, deskBottom, ok: width <= officeW - 12 && H - deskBottom >= 64 };
    };
    // The biggest people the room has space for: few sessions, or a tall
    // room (an iPad held upright), get larger ones.
    let plan = null;
    for (const px of [5, 4, 3, 2]) {
      for (let rows = 1; rows <= 6 && !plan; rows++) { const p = fits(px, rows); if (p.ok) plan = p; }
      if (plan) break;
    }
    // More people than desks fit: the most rows the room is tall enough for,
    // and whoever has no desk stands about.
    if (!plan) {
      let rows = 1;
      while (rows < 8 && fits(2, rows + 1).H - fits(2, rows + 1).deskBottom >= 64) rows++;
      plan = fits(2, rows);
    }

    const dpr = window.devicePixelRatio || 1;
    const scale = parseFloat(getComputedStyle(document.getElementById("board") || document.body).getPropertyValue("--scale")) || 1;
    F.PX = plan.px; F.k = clamp(Math.ceil(dpr * scale), 1, 2); F.U = F.PX * F.k;
    F.W = plan.W; F.H = plan.H;
    [F.canvas, F.bg].forEach((c) => { c.width = Math.round(w * F.k); c.height = Math.round(h * F.k); });
    F.canvas.style.width = w + "px"; F.canvas.style.height = h + "px";

    const S = { W: plan.W, H: plan.H, officeW: plan.officeW, yardW: plan.yardW, rows: plan.rows, zones: [], seats: new Map() };
    S.deskBottom = plan.deskBottom;
    S.corridorY = S.deskBottom + 8;
    const loungeH = S.H - S.corridorY;
    let x = Math.max(6, Math.round((S.officeW - plan.width) / 2));
    const taken = new Set();
    crews.forEach((crew) => {
      const cols = Math.ceil(crew.members.length / plan.rows);
      let ci = hash(crew.name) % CREW.length;
      while (taken.has(ci) && taken.size < CREW.length) ci = (ci + 1) % CREW.length;
      taken.add(ci);
      const zone = { name: crew.name, color: CREW[ci], x, y: WALL + 4, w: cols * CW + 8, h: plan.rows * CH + 6, count: crew.members.length, seats: [] };
      crew.members.forEach((m, j) => {
        const col = j % cols, row = Math.floor(j / cols);
        const seat = {
          x: zone.x + 4 + col * CW + 15, y: WALL + 10 + row * CH + 20, aisle: zone.x + 4 + col * CW + 31,
          key: m.key, foreman: m.role === "foreman", zone,
        };
        if (seat.x + 12 < S.officeW - 4) { zone.seats.push(seat); S.seats.set(m.key, seat); }
      });
      S.zones.push(zone);
      x += zone.w + 6;
    });

    S.door = { x: 0, y: Math.round(S.corridorY + loungeH * 0.6) };
    // The doorway to the yard, kept clear of the coffee counter above it.
    S.yardDoorY = Math.round(S.corridorY + Math.max(loungeH * 0.5, 40));
    S.fire = { x: Math.round(S.officeW + S.yardW / 2 + 2), y: Math.round(clamp(S.H * 0.74, WALL + 70, S.H - 24)) };
    S.tent = { x: S.fire.x, y: WALL + 26 };
    // The picnic table, between the tent and the fire, where lunch is eaten.
    S.table = { x: S.fire.x, y: Math.round((S.tent.y + S.fire.y) / 2) + 6 };
    // The ping pong table, on the open floor to the right.
    S.pong = {
      x: Math.max(60, Math.min(Math.round(S.officeW * 0.72), S.officeW - 74)),
      y: Math.round(S.corridorY + loungeH * 0.34),
    };
    // The foosball table, left of it, in a room with the space for one.
    const foosX = Math.min(Math.round(S.officeW * 0.45), S.pong.x - 68);
    S.foos = foosX >= 58 && loungeH >= 72 ? { x: foosX, y: Math.round(S.corridorY + loungeH * 0.4) } : null;
    // Where you start.
    S.home = { x: Math.round(S.officeW * 0.34), y: Math.round(S.corridorY + loungeH * 0.58) };
    S.pois = [
      { name: "coffee", x: S.officeW - 30, y: S.corridorY + 20 },
      { name: "cooler", x: 22, y: S.corridorY + 16 },
      { name: "plant", x: 24, y: S.H - 6 },
      { name: "couch", x: Math.round(S.officeW * 0.62), y: S.H - 13 },
      { name: "grass", x: S.fire.x - 6, y: S.H - 10 },
    ];

    // Where no feet may stand: every piece of furniture is a box, a little
    // wider than its picture, since feet are the middle of a person. A
    // thing painted into the room's picture (the couch, the plant) blocks
    // all of its picture. The two games tables block a little more behind
    // them, so nobody's name tag lands on the game.
    const [coffee, cooler, plant, couch] = S.pois, wx = S.officeW;
    // In a narrow yard the picnic table's box is cut down, to leave a way past it.
    const picnicW = Math.min(24, Math.floor((S.yardW - 14) / 2));
    S.solids = [
      box("wall", wx - 7, 0, wx + 4, S.yardDoorY - 11), box("wall", wx - 7, S.yardDoorY + 5, wx + 4, S.H + 20),
      box("coffee", coffee.x + 2, coffee.y - 21, wx - 6, coffee.y + 6),
      box("cooler", 0, cooler.y - 18, cooler.x - 4, cooler.y + 5),
      box("plant", 0, plant.y - 18, plant.x - 3, S.H + 20),
      box("couch", couch.x - 23, couch.y - 9, couch.x + 23, couch.y + 7),
      box("pong", S.pong.x - 21, S.pong.y - 13, S.pong.x + 21, S.pong.y + 12),
      box("tent", S.tent.x - 16, S.tent.y - 13, S.tent.x + 16, S.tent.y + 2),
      box("picnic", S.table.x - picnicW, S.table.y - 12, S.table.x + picnicW, S.table.y + 13),
      box("fire", S.fire.x - 11, S.fire.y - 5, S.fire.x + 11, S.fire.y + 4),
      box("tree", S.W - 24, S.H - 36, S.W + 20, S.H - 6),
    ];
    if (S.foos) S.solids.push(box("foos", S.foos.x - 13, S.foos.y - 17, S.foos.x + 13, S.foos.y + 17));
    S.zones.forEach((z) => z.seats.forEach((s) => S.solids.push(box("desk", s.x - 15, s.y - 6, s.x + 15, s.y + 9))));
    // The corners people walk round, and which corner can be walked to
    // from which (worked out the first time it is asked, then kept).
    S.nodes = [];
    const roomy = (x, y) => x >= 4 && x <= S.W - 4 && y >= WALL + 16 && y <= S.H - 2;
    S.solids.forEach((r) => [[r.x0 - 1, r.y0 - 1], [r.x1 + 1, r.y0 - 1], [r.x0 - 1, r.y1 + 1], [r.x1 + 1, r.y1 + 1]].forEach(([nx, ny]) => {
      if (roomy(nx, ny) && !S.solids.some((q) => inBox(q, nx, ny))) S.nodes.push([nx, ny]);
    }));
    S.sees = new Int8Array(S.nodes.length * S.nodes.length);
    // Where the furniture of the open floor and the yard stands follows from these.
    S.sig = [S.W, S.H, S.officeW, S.corridorY].join();
    // The desks move on their own, when a crew gains or loses one.
    S.desks = S.solids.filter((r) => r.name === "desk").map((r) => r.x0 + "," + r.y0).join(" ");
    F.S = S;
    F.bgDirty = true;
    return true;
  };

  const clampPt = (x, y) => ({ x: clamp(x, 7, F.S.W - 7), y: clamp(y, WALL + 18, F.S.H - 3) });
  const loungePt = () => ({ x: rnd(26, F.S.officeW - 44), y: rnd(F.S.corridorY + 8, F.S.H - 8) });

  // ---- Things that take up floor ----------------------------------------------
  // Nobody walks through the furniture. A walk is a straight line when
  // nothing is in the way; otherwise it goes from corner to corner by the
  // shortest way round.
  const box = (name, x0, y0, x1, y1) => ({ name, x0, y0, x1, y1 });
  const inBox = (r, x, y) => x > r.x0 && x < r.x1 && y > r.y0 && y < r.y1;
  const solidAt = (x, y) => F.S.solids.find((r) => inBox(r, x, y));
  // Does the walk from (ax, ay) to (bx, by) cut through the box? Brushing
  // along its edge does not count.
  const cuts = (r, ax, ay, bx, by) => {
    const x0 = r.x0 + 0.3, x1 = r.x1 - 0.3, y0 = r.y0 + 0.3, y1 = r.y1 - 0.3, dx = bx - ax, dy = by - ay;
    let t0 = 0, t1 = 1;
    const clip = (p, q) => {
      if (p === 0) return q > 0;
      const t = q / p;
      if (p < 0) { if (t > t1) return false; if (t > t0) t0 = t; }
      else { if (t < t0) return false; if (t < t1) t1 = t; }
      return true;
    };
    return clip(-dx, ax - x0) && clip(dx, x1 - ax) && clip(-dy, ay - y0) && clip(dy, y1 - ay) && t0 < t1;
  };
  const clear = (ax, ay, bx, by) => !F.S.solids.some((r) => cuts(r, ax, ay, bx, by));

  // The nearest spot to (x, y) where feet may stand.
  const freePt = (x, y) => {
    const S = F.S;
    let p = { x, y };
    for (let n = 0; n < 4; n++) {
      const r = solidAt(p.x, p.y);
      if (!r) return p;
      const from = p;
      const outs = [[r.x0 - 1, p.y], [r.x1 + 1, p.y], [p.x, r.y0 - 1], [p.x, r.y1 + 1]]
        .filter((q) => q[0] >= 4 && q[0] <= S.W - 4 && q[1] >= WALL + 16 && q[1] <= S.H - 2)
        .sort((a, b) => Math.hypot(a[0] - from.x, a[1] - from.y) - Math.hypot(b[0] - from.x, b[1] - from.y));
      const out = outs.find((q) => !solidAt(q[0], q[1])) || outs[0];
      if (!out) return p;
      p = { x: out[0], y: out[1] };
    }
    return p;
  };

  // The way from one spot to another, as a list of points to walk to in
  // turn. Starting or ending inside a box (getting up from a chair) adds a
  // step out of it or into it.
  const pathTo = (ax, ay, bx, by) => {
    const S = F.S, N = S.nodes, n = N.length, out = [];
    const s = freePt(ax, ay), e = freePt(bx, by);
    if (s.x !== ax || s.y !== ay) out.push([s.x, s.y]);
    if (!clear(s.x, s.y, e.x, e.y)) {
      // The shortest way over the corners: n is the start, n + 1 the end.
      const dist = new Float64Array(n + 2).fill(Infinity), prev = new Int32Array(n + 2).fill(-1), done = new Uint8Array(n + 2);
      const pt = (i) => (i < n ? N[i] : i === n ? [s.x, s.y] : [e.x, e.y]);
      const sees = (i, j) => {
        if (i >= n || j >= n) { const p = pt(i), q = pt(j); return clear(p[0], p[1], q[0], q[1]); }
        const k = i * n + j;
        if (!S.sees[k]) S.sees[k] = S.sees[j * n + i] = clear(N[i][0], N[i][1], N[j][0], N[j][1]) ? 1 : 2;
        return S.sees[k] === 1;
      };
      dist[n] = 0;
      for (;;) {
        let u = -1;
        for (let i = 0; i < n + 2; i++) if (!done[i] && dist[i] < Infinity && (u < 0 || dist[i] < dist[u])) u = i;
        if (u < 0 || u === n + 1) break;
        done[u] = 1;
        const p = pt(u);
        for (let v = 0; v < n + 2; v++) {
          if (done[v] || v === n) continue;
          const q = pt(v), d = dist[u] + Math.hypot(p[0] - q[0], p[1] - q[1]);
          if (d < dist[v] && sees(u, v)) { dist[v] = d; prev[v] = u; }
        }
      }
      // With no way round found, what is left is the straight line.
      const mid = [];
      for (let v = prev[n + 1]; v >= 0 && v !== n; v = prev[v]) mid.unshift([N[v][0], N[v][1]]);
      mid.forEach((p) => out.push(p));
    }
    out.push([e.x, e.y]);
    if (e.x !== bx || e.y !== by) out.push([bx, by]);
    return out;
  };

  // One step of `sp` along a walker's path. Says whether it moved.
  const walk = (o, sp) => {
    if (!o.path.length) return false;
    const [tx, ty] = o.path[0], dx = tx - o.x, dy = ty - o.y, dist = Math.hypot(dx, dy);
    if (Math.abs(dx) > 0.3) o.face = dx < 0 ? -1 : 1;
    if (dist <= sp) { o.x = tx; o.y = ty; o.path.shift(); }
    else { o.x += (dx / dist) * sp; o.y += (dy / dist) * sp; }
    return true;
  };

  // One step toward something that moves (you, the bug): straight at it
  // when nothing is in the way, otherwise round, looking again twice a
  // second. A target under a table is followed from the nearest floor.
  // Says whether it moved.
  const seek = (o, tx, ty, sp, dt) => {
    const aim = freePt(tx, ty);
    tx = aim.x; ty = aim.y;
    o.trailT = (o.trailT || 0) - dt;
    if (clear(o.x, o.y, tx, ty)) o.trail = null;
    else if (!o.trail || !o.trail.length || o.trailT <= 0) { o.trail = pathTo(o.x, o.y, tx, ty); o.trailT = 0.5; }
    const next = o.trail && o.trail.length ? o.trail[0] : [tx, ty];
    const dx = next[0] - o.x, dy = next[1] - o.y, dist = Math.hypot(dx, dy);
    if (Math.abs(dx) > 0.3) o.face = dx < 0 ? -1 : 1;
    if (dist <= sp) { o.x = next[0]; o.y = next[1]; if (o.trail) o.trail.shift(); return dist > 0.05; }
    o.x += (dx / dist) * sp; o.y += (dy / dist) * sp;
    return true;
  };

  // A step that stops at the furniture, sliding along it where it can.
  const slide = (x, y, dx, dy) => {
    const stuck = !!solidAt(x, y);
    for (const [mx, my] of [[dx, dy], [dx, 0], [0, dy]]) {
      const p = clampPt(x + mx, y + my);
      if ((mx || my) && (stuck || !solidAt(p.x, p.y))) return p;
    }
    return { x, y };
  };

  // Is someone already standing at, or headed for, this spot?
  const crowded = (a, x, y) => {
    for (const b of F.actors.values()) {
      if (b === a || b.leaving) continue;
      const e = b.path.length ? b.path[b.path.length - 1] : [b.x, b.y];
      if (Math.abs(e[0] - x) < 11 && Math.abs(e[1] - y) < 6) return true;
    }
    return Math.abs(F.boss.x - x) < 11 && Math.abs(F.boss.y - y) < 6;
  };
  // A free spot from `make`, tried a few times to find one with nobody on it.
  const spotFrom = (a, make) => {
    let p = null;
    for (let n = 0; n < 6; n++) {
      const q = make();
      p = freePt(q.x, q.y);
      if (!crowded(a, p.x, p.y)) break;
    }
    return p;
  };

  // ---- People -----------------------------------------------------------------
  const newActor = (m) => {
    const h = hash(m.key);
    return {
      key: m.key, d: m, x: 0, y: 0, path: [], speed: 26, where: "", seat: null, face: 1, trail: null,
      phase: (h % 1000) / 100, skin: SKIN[h % SKIN.length], hair: HAIR[(h >>> 4) % HAIR.length], style: (h >>> 8) % 5,
      wait: 0, moving: false, bub: null, needIdx: 0, campIdx: 0, lunch: null, lunchIdx: 0,
      chat: null, pong: null, foos: null, spat: null, cheer: 0, drank: false, cup: 0, couchI: -1, bye: 0, waveT: 0,
      orbit: rnd(0, TAU), patrolI: 0, watched: false,
      shoutT: rnd(1, 3), glyphT: rnd(0, 1), flopT: rnd(6, 10), flop: 0, signI: h % SIGNS.length, leaving: false, gone: false,
    };
  };

  // Draws one person standing on (x, y), 16 art pixels tall. Returns nothing;
  // everything about how they look is in `o`.
  const person = (x, y, o) => {
    x = Math.round(x); y = Math.round(y);
    const t = F.t + (o.phase || 0);
    const step = o.walking ? Math.floor(t * 9) % 2 : -1;
    const robot = o.tool === "codex";
    const skin = robot ? "#b3bcc7" : o.skin;
    const metal = "#8793a1", dark = "#22252b";
    if (!o.ghost && !o.flat) R(x - 5, y - 1, 10, 2, "rgba(0,0,0,0.16)");
    y -= Math.round(o.hop || 0);
    if (o.ghost) { g.globalAlpha = 0.5; y -= 2 + Math.round(Math.sin(t * 2)); }

    if (!o.seated) {
      if (o.ghost) {
        R(x - 4, y - 3, 8, 2, o.shirt); R(x - 4, y - 1, 2, 1, o.shirt); R(x - 1, y - 1, 2, 1, o.shirt); R(x + 2, y - 1, 2, 1, o.shirt);
      } else {
        const pants = robot ? "#4a5361" : o.pants || "#39414f";
        R(x - 3, y - 3, 2, step === 1 ? 2 : 3, pants);
        R(x + 1, y - 3, 2, step === 0 ? 2 : 3, pants);
      }
    }
    const by = y - 8;
    R(x - 4, by, 8, 5, o.vest ? "#f28c28" : robot ? metal : o.shirt);
    if (o.vest) { R(x - 3, by, 1, 5, "#ffe14d"); R(x + 2, by, 1, 5, "#ffe14d"); R(x - 4, by + 3, 8, 1, "#ffe14d"); }
    if (robot) R(x - 2, by + 1, 4, 3, o.shirt);
    if (o.tie) { R(x - 1, by, 2, 1, "#fff"); R(x, by + 1, 1, 3, "#d43a3a"); }

    // Arms: down, up, one of each for a wave, or held out to the side.
    const sleeve = robot ? metal : o.shirt;
    const f = Math.floor(t * 6) % 2;
    const arm = (ax, up, out) => {
      if (out) { R(ax + (out < 0 ? -2 : 0), by + 1, 3, 1, sleeve); R(ax + out * 3, by + 1, 1, 1, skin); }
      else if (up) { R(ax, by - 3, 1, 4, sleeve); R(ax, by - 4, 1, 1, skin); }
      else { R(ax, by, 1, 4, sleeve); R(ax, by + 4, 1, 1, skin); }
    };
    const pose = o.pose || "down";
    arm(x - 5, pose === "cheer" || pose === "holdL" || (pose === "wave" && f === 0), pose === "outL" ? -1 : 0);
    arm(x + 4, pose === "cheer" || pose === "hold" || (pose === "wave" && f === 1), pose === "outR" ? 1 : 0);

    const hy = y - 16 + (o.headDrop || 0);
    if (robot) {
      R(x - 5, hy, 10, 8, skin); R(x - 4, hy + 2, 8, 3, "#14202e");
      const lit = o.sleeping ? "#35506a" : Math.floor(t * 2) % 7 === 0 ? "#35506a" : "#5fe0ff";
      R(x - 3 + (o.look || 0), hy + 3, 2, 1, lit); R(x + 1 + (o.look || 0), hy + 3, 2, 1, lit);
      R(x, hy - 2, 1, 2, metal); R(x - 1, hy - 3, 2, 1, Math.floor(t * 3) % 2 ? "#ff5a4d" : "#7a2620");
    } else {
      R(x - 4, hy, 8, 1, skin); R(x - 5, hy + 1, 10, 6, skin); R(x - 4, hy + 7, 8, 1, skin);
      const hair = o.hair;
      if (o.style === 2) { R(x - 4, hy, 8, 1, hair); R(x - 5, hy + 1, 10, 1, hair); }
      else {
        R(x - 4, hy, 8, 1, hair); R(x - 5, hy + 1, 10, 2, hair);
        const side = o.style === 1 ? 5 : 2;
        R(x - 5, hy + 3, 1, side, hair); R(x + 4, hy + 3, 1, side, hair);
        if (o.style === 3 && !o.hat) { R(x - 3, hy - 1, 1, 1, hair); R(x, hy - 1, 1, 1, hair); R(x + 3, hy - 1, 1, 1, hair); }
        if (o.style === 4 && !o.hat) R(x - 1, hy - 2, 3, 2, hair);
      }
      const look = o.look || 0;
      if (o.out) {
        // Fainted: crosses for eyes.
        R(x - 3, hy + 4, 1, 1, dark); R(x - 2, hy + 5, 1, 1, dark); R(x + 2, hy + 4, 1, 1, dark); R(x + 1, hy + 5, 1, 1, dark);
      } else if (o.sleeping || (t % 3.7) < 0.13) {
        R(x - 3, hy + 5, 2, 1, dark); R(x + 1, hy + 5, 2, 1, dark);
      } else {
        R(x - 3 + look, hy + 4, 1, 2, dark); R(x + 2 + look, hy + 4, 1, 2, dark);
      }
      if (o.mouth) R(x - 1, hy + 6, 2, o.mouth, "#5a1e1e");
      if (o.mustache) R(x - 2, hy + 6, 4, 1, hair);
      if (o.blush) { R(x - 4, hy + 6, 1, 1, "#f08a7a"); R(x + 3, hy + 6, 1, 1, "#f08a7a"); }
    }
    if (o.hat) {
      R(x - 4, hy - 3, 8, 2, "#ffd21f"); R(x - 5, hy - 1, 10, 2, "#ffd21f"); R(x - 6, hy + 1, 12, 1, "#d9a900");
      R(x - 1, hy - 3, 2, 4, "#fff2a8");
      if (o.siren) {
        const red = Math.floor(t * 7) % 2 === 0;
        R(x - 1, hy - 5, 2, 2, red ? "#ff3b30" : "#3b82ff");
        g.fillStyle = red ? "rgba(255,59,48,0.22)" : "rgba(59,130,255,0.22)";
        g.beginPath(); g.arc(x, hy - 4, 7 + (f ? 1 : 0), 0, TAU); g.fill();
      }
    }
    if (o.crown) {
      R(x - 4, hy - 2, 8, 2, "#ffd21f"); R(x - 4, hy - 4, 1, 2, "#ffd21f"); R(x - 1, hy - 4, 2, 2, "#ffd21f");
      R(x + 3, hy - 4, 1, 2, "#ffd21f"); R(x, hy - 2, 1, 1, "#e0443a");
    }
    g.globalAlpha = 1;
  };

  const lookOf = (a) => ({
    phase: a.phase, skin: a.skin, hair: a.hair, style: a.style, shirt: a.color || CREW[0], tool: a.d.tool, ghost: a.d.ghost,
    hat: a.d.role === "foreman", vest: a.d.role === "foreman" && a.d.tool !== "codex", mustache: a.d.role === "foreman",
  });

  // A helper (subagent): a half-size person running papers past the desk.
  // The same small figure brings the water: `carry` is the color of the
  // bottle on its head, in place of the papers.
  const helper = (x, y, color, t, carry) => {
    x = Math.round(x); y = Math.round(y);
    const step = Math.floor(t * 10) % 2;
    R(x - 3, y, 6, 1, "rgba(0,0,0,0.14)");
    R(x - 2, y - 2, 1, step ? 1 : 2, "#39414f"); R(x + 1, y - 2, 1, step ? 2 : 1, "#39414f");
    R(x - 2, y - 5, 4, 3, color); R(x - 3, y - 9, 6, 4, "#f1c9a5"); R(x - 3, y - 9, 6, 1, "#5a3a1f");
    R(x - 1, y - 7, 1, 1, "#22252b"); R(x + 1, y - 7, 1, 1, "#22252b");
    if (carry) { R(x - 2, y - 15, 4, 6, carry); R(x - 1, y - 16, 2, 1, "#f4f4f4"); R(x - 2, y - 15, 4, 1, "#e9f7ff"); }
    else { R(x - 2, y - 12, 4, 3, "#ffffff"); R(x - 1, y - 11, 2, 1, "#b8c0cc"); }
  };

  // ---- Furniture ----------------------------------------------------------------
  // A desk seen from the front: whoever sits there is behind it, facing us,
  // so its top covers their legs. `a` is who owns it, or nothing.
  const desk = (s, a) => {
    const x = s.x, y = s.y, P = F.pal, t = F.t + (a ? a.phase : 0);
    const here = a && a.where === "seat" && !a.path.length;
    const mood = a ? a.d.mood : "";
    R(x - 11, y - 5, 22, 6, P.deskTop); R(x - 11, y - 5, 22, 1, P.deskEdge);
    R(x - 11, y + 1, 22, 4, P.deskFront);
    if (s.foreman) for (let i = 0; i < 11; i++) R(x - 11 + i * 2, y + 1, 2, 2, i % 2 ? "#1d1d1d" : "#ffd21f");
    R(x - 11, y + 5, 2, 2, P.deskLeg); R(x + 9, y + 5, 2, 2, P.deskLeg);
    R(x + 7, y - 6, 2, 3, "#f4f4f4"); R(x + 9, y - 5, 1, 1, "#f4f4f4");

    if (here && mood === "working") {
      R(x - 4, y - 8, 8, 4, "#2a2f3a"); R(x - 4, y - 8, 8, 1, "#444c5c");
      R(x - 1, y - 7, 2, 2, Math.floor(t * 2) % 2 ? a.color : "#dfe6f0");
      const fast = a.watched ? 18 : a.d.long ? 13 : 9;
      const f = Math.floor(t * fast) % 2;
      const skin = a.d.tool === "codex" ? "#b3bcc7" : a.skin;
      R(x - 7, y - 4 - f, 2, 1, skin); R(x + 4, y - 3 - (1 - f), 2, 1, skin);
      if (a.d.long) {
        // Working past the limit: the laptop has caught fire. This is fine.
        // The flames stand either side of it, so the face still shows.
        for (let i = 0; i < 4; i++) {
          const fh = 1 + Math.floor(Math.abs(Math.sin(t * 9 + i * 1.7)) * 4);
          R(i < 2 ? x - 8 + i * 2 : x + 1 + i * 2, y - 5 - fh, 2, fh, i % 2 ? "#ffb02e" : "#ff5a1f");
        }
      }
    } else {
      R(x - 4, y - 4, 8, 3, "#444c5c"); R(x - 4, y - 4, 8, 1, "#5a6272");
    }
    if (a && mood === "needs") { R(x - 9, y - 4, 3, 3, "#ff5a4d"); R(x - 8, y - 4, 1, 1, "#fff"); }
    // Out to lunch: a little card says so.
    if (a && a.lunch && !here) { R(x - 10, y - 5, 5, 3, "#ffffff"); R(x - 9, y - 4, 3, 1, "#22252b"); }
    if (a && mood === "packed") { R(x - 10, y - 9, 7, 5, "#b98a55"); R(x - 10, y - 9, 7, 1, "#d9ab74"); R(x - 7, y - 8, 1, 3, "#8a6238"); }
    if (a && mood === "asleep") {
      // Cobwebs, more of them the longer it has slept.
      const web = "rgba(235,238,245,0.85)", n = clamp(a.d.days, 1, 6);
      R(x - 11, y - 9, 1, 4, web); R(x - 10, y - 8, 1, 1, web); R(x - 9, y - 7, 1, 1, web); R(x - 10, y - 6, 3, 1, web);
      if (n >= 3) { R(x + 10, y - 9, 1, 4, web); R(x + 9, y - 8, 1, 1, web); R(x + 8, y - 7, 1, 1, web); R(x + 8, y - 6, 3, 1, web); }
      if (n >= 5) { for (let i = 0; i < 6; i++) R(x - 5 + i * 2, y - 3 + (i % 2), 1, 1, web); }
    }
  };

  const fire = (lit) => {
    const { x, y } = F.S.fire, t = F.t;
    R(x - 7, y - 1, 14, 2, "rgba(0,0,0,0.18)");
    R(x - 6, y - 2, 12, 2, "#6b4a2b"); R(x - 4, y - 3, 8, 1, "#845c36"); R(x - 6, y - 2, 2, 1, "#3d2a18"); R(x + 4, y - 2, 2, 1, "#3d2a18");
    for (let i = 0; i < 7; i++) R(x - 7 + i * 2 + (i % 2), y + (i % 3 === 0 ? 0 : 1), 2, 1, "#8a8f98");
    if (!lit) return;
    g.fillStyle = "rgba(255,170,60,0.16)"; g.beginPath(); g.arc(x, y - 4, 20 + Math.sin(t * 5) * 1.5, 0, TAU); g.fill();
    for (let i = 0; i < 5; i++) {
      const fh = 3 + Math.floor(Math.abs(Math.sin(t * 8 + i * 1.3)) * 6) - Math.abs(i - 2);
      R(x - 5 + i * 2, y - 3 - fh, 2, fh, "#ff5a1f");
      if (fh > 3) R(x - 5 + i * 2, y - 3 - fh + 2, 2, fh - 3, "#ffb02e");
      if (fh > 5) R(x - 5 + i * 2 + (i % 2), y - 5, 1, 2, "#fff3b0");
    }
  };

  // The picnic table. Whoever sits on its far side is drawn before it, so
  // its top covers their legs; plates appear once lunch is being eaten.
  const table = () => {
    const { x, y } = F.S.table, L = F.lunch;
    R(x - 21, y + 10, 42, 2, "rgba(0,0,0,0.16)");
    R(x - 20, y - 10, 40, 2, "#8a6238");
    R(x - 17, y + 2, 2, 7, "#6b4a2b"); R(x + 15, y + 2, 2, 7, "#6b4a2b");
    R(x - 20, y - 7, 40, 10, "#b98a55"); R(x - 20, y - 7, 40, 1, "#d9ab74"); R(x - 20, y - 2, 40, 1, "#a57a48");
    R(x - 20, y + 7, 40, 3, "#8a6238");
    if (L && L.phase === "eat") {
      // Plates, a jug and something red to share.
      [-12, 12].forEach((dx) => { R(x + dx - 2, y - 5, 5, 1, "#ffffff"); R(x + dx - 2, y, 5, 1, "#ffffff"); });
      R(x - 2, y - 5, 3, 4, "#8fd0f5"); R(x + 3, y - 2, 2, 2, "#e0352b");
    }
  };

  // The water in the cooler's bottle: lower with every drink, bubbling as
  // it drains, and a red light on the tap when it is empty.
  const coolerWater = () => {
    const w = F.S.pois[1], C = F.cooler, x = w.x - 16, y = w.y - 16;
    const h = Math.round(clamp(C.level, 0, 1) * 9);
    if (h > 0) { R(x, y + 10 - h, 7, h, "#4fb0ea"); R(x, y + 10 - h, 7, 1, "#a5dcfa"); }
    if (C.level > C.target + 0.01 && h > 2) {
      R(x + 1 + (Math.floor(F.t * 6) % 5), y + 9 - (Math.floor(F.t * 11) % (h - 1)), 1, 1, "#e9f7ff");
      R(x + 5 - (Math.floor(F.t * 5) % 4), y + 9 - (Math.floor(F.t * 8 + 2) % (h - 1)), 1, 1, "#e9f7ff");
    }
    if (C.level <= 0.01) R(w.x - 14, w.y - 3, 2, 1, Math.floor(F.t * 3) % 2 ? "#ff3b30" : "#7a1410");
  };

  // The ping pong table, seen from above: a player at each end.
  const pongTable = () => {
    const { x, y } = F.S.pong;
    R(x - 16, y + 8, 32, 2, "rgba(0,0,0,0.16)");
    R(x - 14, y + 5, 2, 5, "#39414f"); R(x + 12, y + 5, 2, 5, "#39414f");
    R(x - 16, y - 8, 32, 14, "#f4f4f4"); R(x - 15, y - 7, 30, 12, "#2f8f5b"); R(x - 15, y - 2, 30, 1, "#57b381");
    R(x, y - 10, 1, 17, "#e6ebf0"); R(x - 1, y - 10, 3, 1, "#39414f"); R(x - 1, y + 6, 3, 1, "#39414f");
  };
  // The ball: `y` is the table or the floor under it, `h` how high it is.
  // Orange, so it shows on the table and on the floor.
  const pongBall = () => {
    const b = F.pong.ball, x = Math.round(b.x), y = Math.round(b.y);
    if (b.floor || Math.abs(b.x - F.S.pong.x) < 15) R(x, y, 2, 1, "rgba(0,0,0,0.2)");
    R(x, y - 2 - Math.round(b.h), 2, 2, "#ff9a2e");
  };

  // The foosball table, seen from above: a goal at the top and at the
  // bottom, and four rods across it. A rod's handle sticks out on the side
  // of whoever plays it; left plays red, right plays blue.
  const RODS = [{ y: -7, team: 0 }, { y: -2, team: 1 }, { y: 3, team: 0 }, { y: 8, team: 1 }];
  const foosTable = () => {
    const { x, y } = F.S.foos, K = F.foos;
    R(x - 9, y + 15, 18, 2, "rgba(0,0,0,0.16)");
    R(x - 8, y + 11, 2, 5, "#39414f"); R(x + 6, y + 11, 2, 5, "#39414f");
    R(x - 8, y - 12, 16, 24, "#6b4a2b"); R(x - 8, y - 12, 16, 1, "#8a6238"); R(x - 8, y + 11, 16, 1, "#4f3a25");
    R(x - 6, y - 10, 12, 20, "#2f8f5b"); R(x - 6, y, 12, 1, "#57b381");
    R(x - 2, y - 11, 4, 1, "#f4f4f4"); R(x - 2, y + 10, 4, 1, "#f4f4f4");
    RODS.forEach((rod, i) => {
      const ry = y + rod.y, spin = F.t < K.spin[i], mx = x + Math.round(K.on ? K.men[i] : 0);
      R(x - 10, ry, 20, 1, "#c8ced6");
      R(rod.team ? x + 10 : x - 12, ry - (spin ? 1 : 0), 2, spin ? 3 : 1, "#22252b");
      [-3, 3].forEach((o) => R(mx + o - 1, ry - 1, 2, spin ? 3 : 2, rod.team ? "#3b82c4" : "#d43a3a"));
    });
    if (K.on && K.ball) R(x + Math.round(K.ball.x) - 1, y + Math.round(K.ball.y) - 1, 2, 2, "#ffffff");
  };

  const drawCat = () => {
    const c = F.cat, x = Math.round(c.x), y = Math.round(c.y - (c.lift || 0)), t = F.t, fur = "#e59a3c", stripe = "#b86e1f";
    const d = c.flip ? -1 : 1;
    R(x - 4, y, 9, 1, "rgba(0,0,0,0.14)");
    if (c.state === "sleep") {
      R(x - 4, y - 3, 8, 3, fur); R(x - 3, y - 4, 6, 1, fur); R(x - 2, y - 3, 1, 3, stripe); R(x + 1, y - 3, 1, 3, stripe);
      R(x + 3 * d, y - 4, 2, 2, fur); R(x + 4 * d, y - 1, 1, 1, stripe);
      return;
    }
    const walk = c.state === "walk" || c.state === "hunt";
    const step = walk ? Math.floor(t * 10) % 2 : 0;
    R(x - 3, y - 4, 6, 3, fur); R(x - 1, y - 4, 1, 3, stripe); R(x + 1, y - 4, 1, 3, stripe);
    R(x - 3 + step, y - 1, 1, 1, fur); R(x + 2 - step, y - 1, 1, 1, fur);
    const hx = x + 3 * d;
    R(hx - 1, y - 7, 4, 4, fur); R(hx - 1, y - 8, 1, 1, fur); R(hx + 2, y - 8, 1, 1, fur);
    R(hx + (d > 0 ? 1 : 0), y - 6, 1, 1, "#22252b"); R(hx + (d > 0 ? 2 : -1) + (d > 0 ? 0 : 1), y - 6, 1, 1, "#22252b");
    const wag = Math.round(Math.sin(t * (walk ? 9 : 3)) * 1);
    R(x - 4 * d - (d > 0 ? 0 : -1), y - 5 + wag, 1, 2, stripe); R(x - 5 * d - (d > 0 ? 0 : -1), y - 6 + wag, 1, 2, stripe);
  };

  // ---- The room that does not move ---------------------------------------------
  const drawBackground = () => {
    const S = F.S, P = F.pal, main = g;
    g = F.bg.getContext("2d");
    g.imageSmoothingEnabled = false;
    art();
    g.clearRect(0, 0, S.W + 2, S.H + 2);

    // Floor tiles.
    R(0, 0, S.officeW, S.H + 1, P.floor);
    for (let row = 0, ty = WALL; ty < S.H; ty += 12, row++) for (let tx = row % 2 ? 0 : 12; tx < S.officeW; tx += 24) R(tx, ty, 12, 12, P.floor2);

    // Outside: grass, a fence, a tree, the tent.
    R(S.officeW, 0, S.yardW + 2, S.H + 1, P.grass);
    for (let i = 0; i < 46; i++) {
      const gx = S.officeW + 5 + ((i * 37) % (S.yardW - 8)), gy = 8 + ((i * 53) % (S.H - 12));
      R(gx, gy, 1, 2, P.grass2);
      if (i % 9 === 0) R(gx + 2, gy, 1, 1, i % 2 ? "#f6e36b" : "#f3a6c8");
    }
    for (let fx = S.officeW + 4; fx < S.W; fx += 8) { R(fx, 2, 2, 9, P.fence); }
    R(S.officeW + 3, 5, S.yardW, 1, P.fence); R(S.officeW + 3, 8, S.yardW, 1, P.fence);
    const tx = S.W - 13, ty = S.H - 14;
    R(tx - 1, ty - 4, 3, 10, "#7a5633"); R(tx - 7, ty - 18, 15, 12, "#3f8f4f"); R(tx - 5, ty - 21, 11, 4, "#3f8f4f"); R(tx - 4, ty - 16, 4, 3, "#57a866");
    const T = S.tent;
    for (let i = 0; i < 12; i++) R(T.x - i - 1, T.y - 12 + i, (i + 1) * 2, 1, i % 2 ? "#4f7fc0" : "#456fae");
    for (let i = 0; i < 7; i++) R(T.x - Math.ceil(i / 2), T.y - 7 + i, Math.ceil(i / 2) * 2 + 1, 1, "#1c2433");

    // The wall the office backs onto, with windows on the sky of the hour.
    R(0, 0, S.officeW, WALL, P.wall); R(0, WALL - 4, S.officeW, 4, P.wallLow);
    const { h } = wallTime();
    const sky = h >= 7 && h < 17 ? ["#8fd0f5", "#bfe6fb"] : h >= 17 && h < 19 ? ["#f08a4b", "#f7c779"]
      : h >= 6 && h < 7 ? ["#f3b48f", "#fbe3b5"] : ["#18214a", "#27336b"];
    const night = sky[0] === "#18214a";
    const mid = Math.round(S.officeW / 2);
    let slot = 0;
    for (let wx = 10; wx + 24 < S.officeW - 6; wx += 38, slot++) {
      if (wx + 24 > mid - 50 && wx < mid + 50) continue;
      if (slot % 3 === 2) {
        const lines = POSTERS[(slot / 3 | 0) % POSTERS.length], bgc = ["#f4e3b1", "#d7ecd9", "#f5d0c5", "#d3e0f5"][slot % 4];
        R(wx + 2, 5, 20, 18, "#5b4632"); R(wx + 3, 6, 18, 16, bgc);
        ui(); g.fillStyle = "#3a2f25"; g.textAlign = "center"; g.textBaseline = "middle"; g.font = font(8 * F.PX / 3, 800);
        lines.forEach((line, i) => g.fillText(line, (wx + 12) * F.PX, (9.5 + i * 4.6) * F.PX));
        art();
        continue;
      }
      R(wx, 5, 24, 17, "#5b6675"); R(wx + 1, 6, 22, 15, sky[0]); R(wx + 1, 14, 22, 7, sky[1]);
      if (night) { R(wx + 5, 9, 1, 1, "#fff"); R(wx + 14, 8, 1, 1, "#fff"); R(wx + 19, 12, 1, 1, "#fff"); if (slot % 2 === 0) R(wx + 16, 8, 3, 3, "#f5f0c8"); }
      else { R(wx + 4, 9, 6, 2, "#ffffff"); R(wx + 6, 8, 3, 1, "#ffffff"); if (slot % 2 === 0) R(wx + 16, 8, 4, 4, "#ffe27a"); }
      R(wx + 12, 6, 1, 15, "#5b6675"); R(wx, 22, 24, 1, "#46505d");
    }
    // The sign and the clock sit in the middle; their faces are drawn live.
    R(mid - 36, 7, 72, 15, "#16181d"); R(mid - 35, 8, 70, 13, "#0b0c0f");
    R(mid - 48, 9, 2, 3, "#5b6675"); R(mid - 50, 12, 6, 2, "#5b6675");

    // Each crew's rug, and its name on the floor below its desks.
    S.zones.forEach((z) => {
      g.globalAlpha = P.rug; R(z.x, z.y, z.w, z.h, z.color); g.globalAlpha = 1;
      g.globalAlpha = 0.5; R(z.x, z.y, z.w, 1, z.color); R(z.x, z.y + z.h - 1, z.w, 1, z.color);
      R(z.x, z.y, 1, z.h, z.color); R(z.x + z.w - 1, z.y, 1, z.h, z.color); g.globalAlpha = 1;
      ui(); g.fillStyle = z.color; g.textAlign = "center"; g.textBaseline = "top"; g.font = font(11, 800);
      const name = z.name.length > 22 ? z.name.slice(0, 21) + "…" : z.name;
      g.fillText(name.toUpperCase() + "  " + z.count, (z.x + z.w / 2) * F.PX, (z.y + z.h + 1.5) * F.PX);
      art();
    });

    // The way in, on the left.
    R(0, S.door.y - 14, 3, 18, "#6b4a2b"); R(0, S.door.y - 13, 2, 16, "#8a6238"); R(1, S.door.y - 5, 1, 2, "#ffd21f");
    R(4, S.door.y - 3, 12, 8, "#7d6b56"); R(5, S.door.y - 2, 10, 6, "#93806a");

    // The wall to the yard, with its doorway.
    R(S.officeW - 3, WALL, 3, S.yardDoorY - 12 - WALL, P.wallLow); R(S.officeW - 3, S.yardDoorY + 6, 3, S.H, P.wallLow);
    R(S.officeW - 3, S.yardDoorY - 12, 3, 1, "#5b4632");

    // Coffee: a counter against the yard wall.
    const c = S.pois[0];
    R(c.x + 6, c.y - 20, 16, 24, "#7d6b56"); R(c.x + 6, c.y - 20, 16, 2, "#a8957c");
    R(c.x + 10, c.y - 17, 8, 9, "#2a2f3a"); R(c.x + 11, c.y - 16, 6, 3, "#c0392b"); R(c.x + 12, c.y - 11, 4, 3, "#f4f4f4");
    R(c.x + 10, c.y - 5, 3, 3, "#f4f4f4"); R(c.x + 15, c.y - 5, 3, 3, "#f4f4f4");
    // The water cooler, by the left wall. Only the stand and the glass of
    // the bottle: the water in it is drawn live (see coolerWater).
    const w = S.pois[1];
    R(w.x - 17, w.y - 6, 9, 9, "#e6ebf0"); R(w.x - 17, w.y - 17, 9, 11, "#b9d3e6"); R(w.x - 16, w.y - 16, 7, 10, "#e3f1fa");
    R(w.x - 14, w.y - 3, 2, 1, "#3b82c4");
    // A plant.
    const p = S.pois[2];
    R(p.x - 16, p.y - 4, 8, 6, "#b5653a"); R(p.x - 17, p.y - 5, 10, 2, "#c97a4a");
    R(p.x - 15, p.y - 13, 6, 8, "#3f8f4f"); R(p.x - 18, p.y - 10, 3, 4, "#57a866"); R(p.x - 9, p.y - 12, 3, 5, "#57a866"); R(p.x - 13, p.y - 17, 2, 5, "#3f8f4f");
    // The couch.
    const s = S.pois[3];
    R(s.x - 17, s.y - 6, 34, 12, "#6c7fa6"); R(s.x - 17, s.y - 8, 34, 4, "#8094bd"); R(s.x - 19, s.y - 5, 4, 11, "#56678a"); R(s.x + 15, s.y - 5, 4, 11, "#56678a");
    ui(); g.textAlign = "center"; g.textBaseline = "middle";
    g.fillStyle = css("--text-muted", "#777"); g.font = font(10, 700);
    g.fillText("CAMP ARCHIVE", S.tent.x * F.PX, (S.tent.y + 6) * F.PX);
    art();

    g = main;
    F.bgDirty = false;
  };

  // ---- Moving about -------------------------------------------------------------
  // Sends `a` to (tx, ty), round whatever is in between. `enter` is one
  // more step, into a seat that is inside its furniture: the chair behind
  // a desk, the far bench of the picnic table, the couch.
  const go = (a, where, tx, ty, speed, enter) => {
    a.where = where; a.speed = speed; a.drank = false; a.trail = null;
    a.path = pathTo(a.x, a.y, tx, ty);
    if (enter) a.path.push(enter);
  };
  const far = (a, x, y) => Math.hypot(a.x - x, a.y - y) > 2;

  const CAMP = [[-18, 2], [18, 2], [-18, -14], [18, -14], [-18, 18], [18, 18], [0, -24]];
  const campSpot = (a) => {
    const o = CAMP[a.campIdx % CAMP.length];
    return freePt(clamp(F.S.fire.x + o[0], F.S.officeW + 8, F.S.W - 7), clamp(F.S.fire.y + o[1], WALL + 22, F.S.H - 4));
  };
  const SLOTS = [[-27, 0], [27, 0], [-17, 24], [17, 24], [-48, 12], [48, 12], [0, 40], [-42, 34], [42, 34]];
  const bossSlot = (a) => {
    const o = SLOTS[a.needIdx % SLOTS.length], ring = 1 + Math.floor(a.needIdx / SLOTS.length) * 0.6;
    const p = clampPt(F.boss.x + o[0] * ring, F.boss.y + o[1] * ring);
    return freePt(p.x, p.y);
  };
  // The two ends of the ping pong table, and the two sides of the foosball
  // table: where the players stand.
  const pongEnd = (side) => freePt(F.S.pong.x + (side ? 26 : -26), F.S.pong.y + 5);
  const foosSide = (side, dy) => freePt(F.S.foos.x + (side ? 15.5 : -15.5), F.S.foos.y + 6 + (dy || 0));

  // One that needs you comes to wherever you are, and stays on you.
  const chase = (a, dt) => {
    const B = F.boss, d = a.d;
    let t = bossSlot(a);
    if (d.urgency === 3) {
      // Ten minutes in: laps around you with a bullhorn.
      a.orbit += dt * 2.4;
      const p = clampPt(B.x + Math.cos(a.orbit) * 25, B.y + 4 + Math.sin(a.orbit) * 13);
      t = freePt(p.x, p.y);
    }
    a.where = "boss";
    if (Math.hypot(t.x - a.x, t.y - a.y) > 1.2) a.moving = seek(a, t.x, t.y, (40 + d.urgency * 9) * dt, dt);
  };

  // A session that ended says its goodbyes on the way out: a line and a
  // wave where it stands, the room waves back, and a last word at the door.
  const leave = (a, dt) => {
    const S = F.S, d = a.d;
    a.wait -= dt;
    if (a.wait > 0) return;
    if (a.bye === 0) {
      a.bye = 1; a.wait = 1.8; a.waveT = F.t + 1.8;
      const lines = d.mood === "packed" ? BYE.camp : d.tool === "codex" && Math.random() < 0.5 ? BYE.robot
        : d.role === "foreman" && Math.random() < 0.6 ? BYE.foreman : BYE.first;
      a.bub = { text: pick(lines), kind: "chat", until: F.t + 3.4 };
      Array.from(F.actors.values())
        .filter((b) => !b.leaving && awake(b) && Math.hypot(b.x - a.x, b.y - a.y) < 140)
        .sort((p, q) => Math.hypot(p.x - a.x, p.y - a.y) - Math.hypot(q.x - a.x, q.y - a.y))
        .slice(0, 2)
        .forEach((b, i) => soon(0.9 + i * 0.7, () => {
          if (F.actors.get(b.key) !== b || b.leaving) return;
          b.waveT = F.t + 1.3;
          word(pick(BYE.reply), b.x, b.y - 26, css("--text-body", "#555"), 11, 1.7);
        }));
    } else if (a.bye === 1) {
      a.bye = 2;
      const p = freePt(11, S.door.y + 1);
      go(a, "door", p.x, p.y, 32);
    } else if (a.bye === 2) {
      // At the door: a turn back to the room.
      a.bye = 3; a.wait = 1.5; a.waveT = F.t + 1.5; a.face = 1;
      if (Math.random() < 0.75) a.bub = { text: pick(BYE.door), kind: "chat", until: F.t + 2.6 };
    } else if (a.bye === 3) {
      a.bye = 4;
      go(a, "door", -9, S.door.y, 34);
    } else a.gone = true;
  };

  const think = (a, dt) => {
    const S = F.S, d = a.d;
    if (a.leaving) return leave(a, dt);
    // Lunch is for the idle and the working; anything else ends it.
    if (a.lunch && d.mood !== "wandering" && d.mood !== "working") a.lunch = null;
    if (d.mood === "needs") return chase(a, dt);
    // Mid-conversation, nobody wanders off.
    if (a.chat) return;
    if (a.pong && d.mood === "wandering") {
      // At the table: an end each for the two playing, who are moved about
      // by the game once they are there. The rest watch from in front of it.
      const P = F.pong, T = S.pong, side = P.players.indexOf(a), spot = P.queue.indexOf(a);
      const p = side >= 0 ? pongEnd(side) : freePt(T.x - 7 + spot * 14, T.y + 27);
      if (a.where !== "pong" || (far(a, p.x, p.y) && (side < 0 || P.st === "walk"))) go(a, "pong", p.x, p.y, 30);
      return;
    }
    if (a.foos && d.mood === "wandering") {
      const K = F.foos, T = S.foos, side = K.players.indexOf(a), spot = K.watch.indexOf(a);
      const p = side >= 0 ? foosSide(side) : freePt(T.x - 7 + spot * 14, T.y + 32);
      if (a.where !== "foos" || (far(a, p.x, p.y) && (side < 0 || K.st === "walk"))) go(a, "foos", p.x, p.y, 28);
      return;
    }
    if (a.lunch) {
      // First everyone meets by the yard door, then they go out together.
      if (a.lunch.phase === "meet") {
        const i = a.lunchIdx;
        if (a.where !== "lunch-meet") {
          const p = freePt(S.officeW - 14 - (i % 2) * 9, S.yardDoorY - 1 + Math.floor(i / 2) * 8);
          go(a, "lunch-meet", p.x, p.y, 30);
        }
      } else if (a.where !== "lunch") {
        // The far bench is reached from behind the table.
        const o = LUNCH[a.lunchIdx % LUNCH.length], tx = S.table.x + o[0], ty = S.table.y + o[1];
        if (o[1] < 0) go(a, "lunch", tx, S.table.y - 13.5, 24, [tx, ty]);
        else go(a, "lunch", tx, ty, 24);
      }
      return;
    }
    let want = "seat";
    if (d.mood === "packed") want = "camp";
    else if (d.mood === "wandering") want = "wander";
    else if (d.mood === "working" && d.role === "foreman") want = "patrol";
    if (!a.seat && want === "seat") want = "wander";

    if (want === "seat") {
      // The chair is behind the desk: round to the back of it, then sit.
      if (a.where !== "seat" || far(a, a.seat.x, a.seat.y)) go(a, "seat", a.seat.x, a.seat.y - 7, 28, [a.seat.x, a.seat.y]);
    } else if (want === "camp") {
      const p = campSpot(a);
      if (a.where !== "camp" || far(a, p.x, p.y)) go(a, "camp", p.x, p.y, 22);
    } else if (want === "wander") {
      a.wait -= dt;
      if (a.wait <= 0 || a.where.indexOf("poi") !== 0) {
        const foremanCoffee = d.role === "foreman" && Math.random() < 0.5;
        // The water cooler is the popular spot.
        const poi = foremanCoffee ? S.pois[0] : Math.random() < 0.66 ? pick(S.pois.concat([S.pois[1]])) : null;
        a.wait = rnd(5, 12);
        if (poi && poi.name === "couch") {
          // A sit on the couch, if there is a place left on it.
          const taken = Array.from(F.actors.values()).filter((b) => b !== a && b.where === "poi:couch").map((b) => b.couchI);
          const i = [0, 1].find((n) => taken.indexOf(n) < 0);
          if (i != null) {
            const sx = poi.x + (i ? 3 : -9);
            a.couchI = i; a.wait = rnd(10, 20);
            return go(a, "poi:couch", sx, poi.y + 8.5, 17, [sx, poi.y + 3]);
          }
        }
        const beside = poi && (poi.name === "cooler" || poi.name === "plant");
        const p = spotFrom(a, () => (!poi || poi.name === "couch" ? loungePt()
          : { x: poi.x + (beside ? rnd(-2, 6) : rnd(-5, 5)), y: poi.y + rnd(-2, 3) }));
        go(a, "poi:" + (poi && poi.name !== "couch" ? poi.name : "floor"), p.x, p.y, 17);
      }
    } else {
      // A working foreman does the rounds of the crew's desks.
      a.wait -= dt;
      if (a.wait > 0) return;
      const mates = Array.from(F.actors.values()).filter((m) =>
        m !== a && m.d.crew === d.crew && m.seat && m.where === "seat" && !m.path.length && !m.leaving);
      a.patrolI++;
      if (a.seat && (a.patrolI % 4 === 0 || !mates.length)) {
        if (!mates.length && a.where === "seat") { a.wait = 3; return; }
        go(a, "seat", a.seat.x, a.seat.y - 7, 24, [a.seat.x, a.seat.y]);
        a.wait = rnd(4, 7);
      } else if (mates.length) {
        // Beside the desk, in the gap between it and the next one.
        const m = mates[a.patrolI % mates.length], p = freePt(m.seat.aisle, m.seat.y + 7);
        go(a, "watch:" + m.key, p.x, p.y, 24);
        a.wait = rnd(3.5, 6);
        a.checked = false;
      } else {
        const p = spotFrom(a, loungePt);
        go(a, "poi:floor", p.x, p.y, 20);
        a.wait = rnd(3, 6);
      }
    }
  };

  const stepActor = (a, dt) => {
    a.moving = false;
    // A session that starts needing you drops everything, mid-walk too.
    if (a.path.length && a.d.mood === "needs" && !a.leaving) a.path = [];
    if (a.path.length) { a.moving = walk(a, a.speed * dt); return; }
    think(a, dt);
  };

  // ---- Bits that fly about: sweat, smoke, sparks, words ---------------------------
  const spark = (p) => { if (F.parts.length < 260) F.parts.push(p); };
  const word = (text, x, y, color, size, life) =>
    spark({ text, x, y, vx: rnd(-2, 2), vy: -9, life: life || 1.3, max: life || 1.3, color, size: size || 11 });
  // Something to do a moment from now, such as an answer to a shout.
  const soon = (secs, run) => F.later.push({ at: F.t + secs, run });
  const poof = (x, y) => {
    for (let i = 0; i < 12; i++) spark({ x: x + rnd(-4, 4), y: y - rnd(0, 14), vx: rnd(-14, 14), vy: rnd(-16, 2), life: 0.5, max: 0.5, color: "#e9edf3", s: 2 });
  };

  const emit = (a, dt) => {
    const d = a.d, seated = a.where === "seat" && !a.path.length, eating = a.where === "lunch" && !a.path.length;
    if (a.cheer > 0) a.cheer -= dt;
    // A drink at the water cooler takes a quarter of the bottle.
    if (a.where === "poi:cooler" && !a.path.length && !a.drank) {
      a.drank = true;
      const C = F.cooler;
      if (C.target > 0.01) {
        C.target = Math.max(0, C.target - 0.25);
        word("glug glug", a.x - 4, a.y - 24, "#2a8fd0", 10, 1.5);
        if (C.target <= 0.01) { C.refillT = rnd(6, 10); soon(1.6, () => word("That was the last of it.", a.x, a.y - 24, css("--text", "#222"), 11, 1.8)); }
      } else {
        word(pick(["Empty!", "No water?!", "Who drank it all?", "Not again.", "Dry as a README."]), a.x, a.y - 24, css("--text", "#222"), 11, 1.7);
      }
    }
    // A coffee is poured, then carried about for a while.
    if (a.where === "poi:coffee" && !a.path.length && !a.drank) {
      a.drank = true; a.cup = F.t + rnd(25, 45);
      word("psssht", a.x + 8, a.y - 22, css("--text-muted", "#888"), 10, 1.3);
    }
    if (eating && Math.random() < dt * 1.5) {
      spark({ x: a.x + rnd(-2, 3), y: a.y - 9, vx: rnd(-5, 5), vy: -3, g: 26, life: 0.5, max: 0.5, color: "#e8c98f", s: 1 });
    }
    if (d.mood === "working" && (seated || eating)) {
      a.glyphT -= dt;
      if (a.glyphT <= 0) {
        a.glyphT = rnd(0.5, 1.4) / (a.watched ? 2 : 1);
        spark({ text: pick(GLYPHS), x: a.x + rnd(-9, 9), y: a.y - 16, vx: rnd(-2, 2), vy: -7, life: 1.1, max: 1.1, color: a.color, size: 9, mono: true });
        if (d.long) {
          spark({ x: a.x + rnd(-3, 3), y: a.y - 12, vx: rnd(-2, 2), vy: -9, life: 1.4, max: 1.4, color: "rgba(120,125,135,0.7)", s: 2 });
          spark({ x: a.x + (Math.random() < 0.5 ? -6 : 6), y: a.y - 12, vx: rnd(-10, 10), vy: -4, g: 30, life: 0.5, max: 0.5, color: "#6cc5ff", s: 1 });
        }
      }
    }
    if (d.mood === "asleep" && seated) {
      a.glyphT -= dt;
      if (a.glyphT <= 0) { a.glyphT = 1.1; spark({ text: pick(["z", "Z", "z"]), x: a.x + 5, y: a.y - 12, vx: 3, vy: -6, life: 1.8, max: 1.8, color: css("--text-muted", "#888"), size: 11 }); }
    }
    // Not one whose session has ended: it has stopped waiting on you.
    if (d.mood === "needs" && a.where === "boss" && !a.leaving) {
      a.shoutT -= dt;
      if (a.shoutT <= 0) {
        a.shoutT = rnd(2.2, 4.5) / Math.max(1, d.urgency - 1);
        const foreman = d.role === "foreman";
        if (d.urgency >= 2 || foreman) {
          const lines = foreman && Math.random() < 0.6 ? SHOUT.foreman : SHOUT[Math.min(d.urgency, 3)] || SHOUT[2];
          const text = pick(lines);
          word(text, a.x, a.y - (d.urgency >= 4 ? 48 : 30), css("--alert", "#d43a3a"), d.urgency >= 3 ? 13 : 11, 1.5);
          if (text === "TWEEET!") F.shake = 0.25;
        }
        if (d.urgency >= 2) spark({ x: a.x + (Math.random() < 0.5 ? -6 : 6), y: a.y - 13, vx: rnd(-12, 12), vy: -6, g: 34, life: 0.5, max: 0.5, color: "#6cc5ff", s: 1 });
      }
      // Half an hour in: now and then it gives up and lies down.
      if (d.urgency >= 4) {
        if (a.flop > 0) a.flop -= dt;
        else { a.flopT -= dt; if (a.flopT <= 0) { a.flop = 2.6; a.flopT = rnd(8, 14); a.signI++; } }
      } else a.flop = 0;
    }
    if (d.mood === "packed" && a.where === "camp" && !a.path.length && Math.random() < dt * 0.8) {
      spark({ x: F.S.fire.x + rnd(-3, 3), y: F.S.fire.y - 8, vx: rnd(-3, 3), vy: -14, life: 0.9, max: 0.9, color: "#ffb02e", s: 1 });
    }
    // A foreman at someone's desk: a tick on the clipboard, or a wake-up call.
    if (a.where.indexOf("watch:") === 0 && !a.path.length && !a.checked) {
      a.checked = true;
      const m = F.actors.get(a.where.slice(6));
      if (m && m.d.mood === "asleep") word("WAKE UP!", a.x, a.y - 24, css("--alert", "#d43a3a"), 11, 1.4);
      else word(Math.random() < 0.8 ? "✓" : "✗", a.x + 4, a.y - 22, Math.random() < 0.8 ? css("--ok", "#2c9a5a") : css("--alert", "#d43a3a"), 14, 1.3);
    }
  };

  // ---- Who says what, and when ------------------------------------------------------
  const joke = (a) => {
    const d = a.d;
    if (d.ghost) return pick(SAY.ghost);
    if (d.mood === "asleep") return pick(SAY.asleep);
    if (d.mood === "packed") return pick(SAY.packed);
    if (a.pong && a.where === "pong" && !a.path.length) return pick(PONG.chat);
    if (a.foos && a.where === "foos" && !a.path.length) return pick(FOOS.chat);
    if (a.where === "poi:couch" && !a.path.length) return pick(SAY.couch);
    if (a.cup > F.t && d.mood === "wandering" && Math.random() < 0.5) return pick(SAY.coffee);
    if (a.where === "lunch" && !a.path.length) return pick(d.mood === "working" ? SAY.workingLunch : SAY.lunch);
    if (d.tool === "codex" && Math.random() < 0.5) return pick(SAY.robot);
    if (a.watched) return pick(SAY.watched);
    if (d.role === "foreman") return pick(d.mood === "working" ? SAY.foreman : SAY.foremanIdle);
    if (d.mood === "working") return pick(d.long ? SAY.long : SAY.worker);
    if (a.where === "poi:grass" && !a.path.length) return pick(SAY.grass);
    return pick(SAY.idle);
  };

  // ---- Small talk, shouting, ping pong and foosball -----------------------------------
  // None of this says anything about a session. One that needs you is
  // never part of it, and drops out the moment it starts needing you.
  const awake = (a) => !a.leaving && a.d.mood !== "needs" && a.d.mood !== "asleep" && a.flop <= 0;
  const free = (a) => awake(a) && !a.chat && !a.pong && !a.foos && !(a.lunch && a.lunch.phase === "meet");

  const endChat = (c) => {
    c.who.forEach((a) => { if (a.chat === c) { a.chat = null; a.wait = Math.min(a.wait, 1); } });
    return false;
  };

  // Two standing near each other strike up a conversation. If nobody is
  // near anybody, one idle walks over to another.
  const startChat = (all) => {
    const able = all.filter((a) => free(a) && !a.bub), still = able.filter((a) => !a.path.length);
    const near = [];
    still.forEach((a, i) => still.slice(i + 1).forEach((b) => {
      if (Math.hypot(a.x - b.x, a.y - b.y) < 44 && (a.x > F.S.officeW) === (b.x > F.S.officeW)) near.push([a, b]);
    }));
    const idle = able.filter((a) => a.d.mood === "wandering" && !a.lunch && a.x < F.S.officeW && a.y >= F.S.corridorY);
    let pair = null;
    if (near.length && (idle.length < 2 || Math.random() < 0.7)) pair = pick(near);
    else if (idle.length >= 2) {
      // One stays put (someone standing still, for choice) and the other
      // comes over to stand beside them.
      const stood = idle.filter((x) => !x.path.length);
      const a = pick(stood.length ? stood : idle), b = pick(idle.filter((x) => x !== a));
      const q = clampPt(a.x + (b.x < a.x ? -14 : 14), Math.max(a.y, F.S.corridorY + 2)), p = freePt(q.x, q.y);
      if (!solidAt(a.x, a.y)) a.path = [];
      go(b, "poi:chat", p.x, p.y, 24);
      pair = [a, b];
    }
    if (!pair) return;
    const boss = pair.find((a) => a.d.role === "foreman");
    const who = boss ? [boss, pair.find((a) => a !== boss)] : Math.random() < 0.5 ? pair : [pair[1], pair[0]];
    const chat = { who, lines: pick(boss && Math.random() < 0.65 ? CHATS_FOREMAN : CHATS), i: 0, t: 0.4, age: 0 };
    who.forEach((a) => { a.chat = chat; });
    F.chats.push(chat);
  };

  const runChats = (all, dt) => {
    const D = F.dir;
    F.chats = F.chats.filter((c) => {
      const [a, b] = c.who;
      c.age += dt;
      if (!c.who.every((x) => F.actors.get(x.key) === x && awake(x)) || c.age > 40) return endChat(c);
      // Still walking over.
      if (a.path.length || b.path.length) return true;
      if (Math.hypot(a.x - b.x, a.y - b.y) > 64) return endChat(c);
      c.t -= dt;
      if (c.t <= 0) {
        if (c.i >= c.lines.length) return endChat(c);
        const speaker = c.who[c.i % 2], other = c.who[(c.i + 1) % 2];
        speaker.bub = { text: c.lines[c.i], kind: "chat", until: F.t + 2.8 };
        if (other.bub && other.bub.kind === "chat") other.bub = null;
        c.i++; c.t = 3;
      }
      return true;
    });
    D.chatT -= dt;
    if (D.chatT <= 0) {
      D.chatT = rnd(5, 9);
      if (F.chats.length < (all.length > 8 ? 2 : 1)) startChat(all);
    }
  };

  // Someone yells something cheerful, arms in the air. Sometimes the room
  // answers. Never in the red of a session that needs you.
  const runYells = (all, dt) => {
    const D = F.dir;
    D.yellT -= dt;
    if (D.yellT > 0) return;
    D.yellT = rnd(8, 15);
    const able = all.filter((a) => free(a) && !a.bub && a.d.mood !== "packed");
    if (!able.length) return;
    const a = pick(able), ink = css("--text", "#222");
    word(pick(YELL), a.x, a.y - 28, ink, 13, 1.9);
    a.cheer = 1.3;
    const ears = able.filter((x) => x !== a && Math.hypot(x.x - a.x, x.y - a.y) < 110);
    if (ears.length && Math.random() < 0.6) {
      const b = pick(ears);
      soon(0.9, () => word(pick(REPLY), b.x, b.y - 26, css("--text-body", "#555"), 11, 1.5));
    }
  };

  // An argument over a point, at either table. The two take turns through
  // a script, arms going, and it ends one of two ways: the point is played
  // again, or it stands.
  const startSpat = (G, loser, winner, lines) => {
    const spat = { who: [loser, winner], lines, i: 0, t: 0.5, replay: Math.random() < 0.5, over: false };
    G.spat = spat; G.sinceSpat = 0;
    spat.who.forEach((a) => { a.spat = spat; a.bub = null; });
  };
  const endSpat = (G) => {
    if (!G.spat) return;
    G.spat.who.forEach((a) => { if (a.spat === G.spat) a.spat = null; });
    G.spat = null;
  };
  // Moves the argument on. Says true once it is over. `crowd` is whoever
  // is watching, who may have a view of their own.
  const runSpat = (G, dt, crowd) => {
    const s = G.spat;
    if (s.who.some((a) => a.path.length)) return false;
    s.t -= dt;
    if (s.t > 0) return false;
    if (s.over) return true;
    const say = (a, text, secs) => {
      s.who.forEach((x) => { if (x.bub && x.bub.kind === "chat") x.bub = null; });
      a.bub = { text, kind: "chat", until: F.t + secs };
    };
    if (s.i < s.lines.length) {
      say(s.who[s.i % 2], s.lines[s.i], 2.3);
      s.i++; s.t = 2.5;
      if (s.i === 3 && crowd.length && Math.random() < 0.7) {
        const c = pick(crowd);
        soon(1.1, () => word(pick(SPAT_CROWD), c.x, c.y - 26, css("--text-body", "#555"), 11, 1.6));
      }
      return false;
    }
    // Whoever won the point agrees to play it again, or the loser gives in.
    say(s.who[s.replay ? 1 : 0], pick(s.replay ? SPAT_END.replay : SPAT_END.stand), 2);
    s.over = true; s.t = 2.1;
    return false;
  };

  const pongReset = { score: [0, 0], st: "walk", server: 0, rally: 0, ball: null, loose: false, shot: null, drop: null, fetcher: null };
  const pongOver = () => {
    const P = F.pong;
    endSpat(P);
    P.players.concat(P.queue).forEach((a) => { a.pong = null; a.wait = 0; });
    Object.assign(P, pongReset, { on: false, players: [], queue: [], score: [0, 0], want: [null, null], games: 0, streak: 0 });
    F.dir.pongT = rnd(35, 70);
  };

  // One shot: where it is going, how hard, and what becomes of it. Most
  // come back. Some are missed, some go into the net and some go long.
  const pongHit = (from) => {
    const P = F.pong, T = F.S.pong, to = 1 - from, hitter = P.players[from], recv = P.players[to];
    const sgn = to ? 1 : -1;
    const smash = P.rally >= 2 && Math.random() < 0.15;
    const fault = P.rally >= 1 && Math.random() < 0.08 ? pick(["net", "out"]) : null;
    const miss = !fault && Math.random() < (smash ? 0.5 : 0.16);
    // Across the table it lands high or low (lat), short or deep.
    const lat = rnd(-1, 1), depth = smash ? rnd(8, 12) : pick([rnd(0, 2), rnd(3, 6), rnd(3, 6), rnd(7, 10)]);
    const x0 = hitter.x + (from ? -6 : 6), y0 = hitter.y - 5;
    let x1 = T.x + sgn * (17 + depth), y1 = T.y - 1 + lat * 5, dur;
    // Where the receiver's feet must be for the paddle to meet it.
    const q = clampPt(x1 + sgn * 6, y1 + 5), feet = freePt(q.x, q.y);
    if (fault === "net") { x1 = T.x - sgn * 1.5; dur = Math.abs(x1 - x0) / 70; }
    else if (fault === "out") { x1 = T.x + sgn * rnd(34, 42); y1 += 5; dur = Math.abs(x1 - x0) / 95; }
    else {
      dur = Math.abs(x1 - x0) / (smash ? 130 : rnd(60, 86));
      // A ball that comes back is one the receiver had time to reach.
      if (!miss) dur = Math.max(dur, Math.hypot(feet.x - recv.x, feet.y - recv.y) / 46 + 0.05);
    }
    const kb = clamp((T.x + sgn * rnd(5, 12) - x0) / (x1 - x0), 0.3, 0.9);
    P.shot = { from, to, x0, y0, x1, y1, t: 0, dur, kb, smash, miss, fault };
    // The receiver steps in for a short one and back for a deep one: all
    // the way, or not far enough. The hitter gets back to the middle.
    const home = pongEnd(from);
    P.want[to] = fault ? null : miss ? { x: (feet.x + recv.x) / 2, y: recv.y + (feet.y - recv.y) * rnd(-0.3, 0.5) } : feet;
    P.want[from] = { x: home.x + rnd(-2, 2), y: home.y + rnd(-2, 2) };
    hitter.swingUntil = F.t + 0.22;
    P.rally++; P.st = "rally";
    if (smash) {
      hitter.jumpUntil = F.t + 0.35;
      word(pick(PONG.smash), hitter.x, hitter.y - 28, css("--text", "#222"), 12, 1.1);
    }
  };

  // A point is won. The ball ends up past whoever missed it, out on the
  // floor, or dribbling back off the net.
  const pongPoint = (won, how) => {
    const P = F.pong, T = F.S.pong, winner = P.players[won], loser = P.players[1 - won], s = P.shot, sgn = s.to ? 1 : -1;
    const ink = css("--text", "#222");
    P.last = { won, how, server: P.server };
    P.score[won]++; P.rally = 0; P.sinceSpat++; P.server = 1 - won; P.want = [null, null];
    if (how === "net") {
      P.drop = { x0: s.x1, y0: s.y1, h0: 2, x1: T.x - sgn * 12, y1: s.y1, bounce: 1, floor: false, t: 0 };
      P.loose = false;
    } else {
      const q = how === "miss" ? clampPt(s.x1 + sgn * rnd(14, 24), s.y1 + 5 + rnd(0, 8)) : clampPt(s.x1 + sgn * rnd(4, 9), s.y1 + rnd(-2, 3));
      const lie = freePt(q.x, q.y);
      P.drop = { x0: s.x1, y0: how === "miss" ? s.y1 + 5 : s.y1, h0: how === "miss" ? 9 : 0, x1: lie.x, y1: lie.y, bounce: 3, floor: true, t: 0 };
      P.loose = true;
    }
    if (how === "out") word(pick(PONG.out), winner.x, winner.y - 26, ink, 11, 1.3);
    else if (how === "net") word(pick(PONG.net), winner.x, winner.y - 26, ink, 11, 1.3);
    else if (Math.random() < 0.6) word(pick(PONG.point), winner.x, winner.y - 26, ink, 11, 1.3);
    if (how === "miss" && Math.random() < 0.5) soon(0.5, () => word(pick(PONG.miss), loser.x, loser.y - 26, css("--text-body", "#555"), 11, 1.3));
    if (Math.random() < 0.35) winner.cheer = 0.7;
    P.st = "point"; P.t = 1.2;
  };

  // After a point: whoever is nearer fetches the ball if it is on the
  // floor, then both go back to their ends for the serve.
  const pongNext = () => {
    const P = F.pong, b = P.ball;
    if (P.loose && b) {
      const who = P.players.slice().sort((p, q) => Math.hypot(p.x - b.x, p.y - b.y) - Math.hypot(q.x - b.x, q.y - b.y))[0];
      go(who, "pong", b.x, b.y, 34);
      P.fetcher = who; P.st = "fetch";
      // The other one goes back to their end meanwhile: after an argument
      // they are both still at the net.
      P.players.forEach((a, side) => {
        const end = pongEnd(side);
        if (a !== who && far(a, end.x, end.y)) go(a, "pong", end.x, end.y, 30);
      });
    } else P.st = "walk";
  };

  // Game. The loser goes; so does a winner on a second win in a row.
  const pongGame = (won, pool) => {
    const P = F.pong, winner = P.players[won], loser = P.players[1 - won];
    P.games++; P.streak = P.lastWinner === winner ? P.streak + 1 : 1; P.lastWinner = winner;
    winner.cheer = 1.4;
    word(pick(PONG.win), winner.x, winner.y - 28, css("--ok", "#2c9a5a"), 12, 1.8);
    soon(0.8, () => word(pick(PONG.lose), loser.x, loser.y - 26, css("--text-body", "#555"), 11, 1.6));
    const fresh = pool();
    const waiting = P.queue.length + fresh.length;
    // Five games and the table rests; two, when it is the same pair again.
    if (P.games >= (waiting === 0 ? 2 : 5)) return pongOver();
    // With nobody else free to play, the same two play again.
    const out = waiting === 0 ? [] : P.streak >= 2 && waiting >= 2 ? [loser, winner] : [loser];
    const stay = P.players.filter((x) => out.indexOf(x) < 0);
    out.forEach((x) => { x.pong = null; x.wait = 0; });
    while (stay.length < 2) {
      const next = P.queue.shift() || fresh.shift();
      next.pong = P;
      stay.push(next);
      soon(1.4, () => word(pick(PONG.next), next.x, next.y - 26, css("--text", "#222"), 11, 1.5));
    }
    // The winner takes the left end; whoever is new, or lost, the right.
    // A pair playing again change ends.
    P.players = stay[0] === loser ? [stay[1], stay[0]] : stay;
    if (out.indexOf(winner) >= 0) { P.streak = 0; P.lastWinner = null; }
    Object.assign(P, pongReset, { score: [0, 0], want: [null, null] });
  };

  // Ping pong for the idle: first to three, then the loser makes way for
  // whoever is waiting. Two wins in a row and the winner steps aside too,
  // so everybody gets a turn. The two playing move like players: in for a
  // short ball, back for a deep one, a jump for a smash, a walk to fetch
  // the ball. Now and then a point is argued over.
  const runPong = (all, dt) => {
    const P = F.pong, D = F.dir, T = F.S.pong;
    const fit = (a) => F.actors.get(a.key) === a && !a.leaving && a.d.mood === "wandering" && a.pong === P;
    const pool = () => all.filter((a) => a.d.mood === "wandering" && free(a) && !a.lunch && !a.d.ghost);
    if (!P.on) {
      D.pongT -= dt;
      if (D.pongT > 0) return;
      D.pongT = 8;
      const up = pool().sort(() => Math.random() - 0.5).slice(0, 4);
      if (up.length < 2) return;
      up.forEach((a) => { a.pong = P; a.bub = null; });
      Object.assign(P, pongReset, { on: true, players: up.slice(0, 2), queue: up.slice(2), score: [0, 0], want: [null, null], games: 0, streak: 0, sinceSpat: 0 });
      word("PING PONG?", up[0].x, up[0].y - 26, css("--text", "#222"), 12, 1.7);
      return;
    }
    // Anyone called away (a question for you, real work, the session ending) drops out.
    P.players.concat(P.queue).forEach((a) => { if (!fit(a) && a.pong === P) a.pong = null; });
    P.queue = P.queue.filter(fit);
    const left = P.players.filter(fit);
    if (left.length < 2) {
      const sub = P.queue.shift() || pool()[0];
      if (!sub || !left.length) return pongOver();
      sub.pong = P;
      endSpat(P);
      Object.assign(P, pongReset, { players: left.concat([sub]), score: [0, 0], want: [null, null] });
    }
    if (P.st === "walk") {
      // To their ends: think() walks them there.
      if (P.players.some((a, side) => { const e = pongEnd(side); return a.where !== "pong" || a.path.length || far(a, e.x, e.y); })) return;
      P.st = "serve"; P.t = 0.9;
      return;
    }
    if (P.st === "serve") {
      // The server bounces the ball on the paddle, then hits it.
      const s = P.players[P.server];
      P.t -= dt;
      P.ball = { x: s.x + (P.server ? -6 : 6), y: s.y - 5, h: 3 + (P.t < 0.45 ? Math.abs(Math.sin((0.45 - P.t) * 7)) * 4 : 0), floor: false };
      if (P.t <= 0) pongHit(P.server);
      return;
    }
    if (P.st === "rally") {
      // Over the net, down onto the table, and up to the paddle.
      const s = P.shot;
      s.t += dt;
      const k = Math.min(1, s.t / s.dur);
      let h;
      if (s.fault === "net") h = 3 - k + Math.sin(k * Math.PI) * 3;
      else if (s.fault === "out") h = 3 * (1 - k) + Math.sin(k * Math.PI) * 10;
      else if (k < s.kb) h = 3 * (1 - k / s.kb) + Math.sin((k / s.kb) * Math.PI) * (s.smash ? 3 : 6);
      else h = Math.sin(((k - s.kb) / (1 - s.kb)) * Math.PI * 0.5) * 4;
      P.ball = { x: s.x0 + (s.x1 - s.x0) * k, y: s.y0 + (s.y1 - s.y0) * k, h, floor: false };
      P.players.forEach((a, side) => {
        const w = P.want[side];
        if (!w) return;
        const dx = w.x - a.x, dy = w.y - a.y, dist = Math.hypot(dx, dy), sp = Math.min(46 * dt, dist);
        if (dist < 0.4) return;
        a.x += (dx / dist) * sp; a.y += (dy / dist) * sp;
        a.shuffle = F.t + 0.12;
      });
      if (k < 1) return;
      if (s.fault) return pongPoint(s.to, s.fault);
      if (s.miss) return pongPoint(s.from, "miss");
      return pongHit(s.to);
    }
    if (P.st === "point") {
      // The ball bounces away and comes to rest.
      const d = P.drop;
      d.t = Math.min(1, d.t + dt / 0.8);
      const k = d.t;
      P.ball = {
        x: d.x0 + (d.x1 - d.x0) * k, y: d.y0 + (d.y1 - d.y0) * k, floor: d.floor,
        h: d.h0 * (1 - k) * (1 - k) + Math.abs(Math.sin(k * Math.PI * 2.5)) * d.bounce * (1 - k),
      };
      P.t -= dt;
      if (P.t > 0) return;
      const won = P.last.won, winner = P.players[won], loser = P.players[1 - won];
      if (P.score[won] >= 3) return pongGame(won, pool);
      if (P.sinceSpat >= 2 && P.last.how !== "net" && Math.random() < 0.3) {
        // The point is disputed. They meet at the net, across the far side
        // of the table, to have it out.
        startSpat(P, loser, winner, pick(SPATS.pong));
        P.players.forEach((a, side) => go(a, "pong", T.x + (side ? 10 : -10), T.y - 14, 30, [T.x + (side ? 10 : -10), T.y - 7]));
        P.st = "argue";
        return;
      }
      return pongNext();
    }
    if (P.st === "argue") {
      if (!runSpat(P, dt, P.queue)) return;
      if (P.spat.replay) { P.score[P.last.won]--; P.server = P.last.server; }
      endSpat(P);
      return pongNext();
    }
    if (P.st === "fetch" && !P.fetcher.path.length) { P.loose = false; P.ball = null; P.st = "walk"; }
  };

  const foosOver = () => {
    const K = F.foos;
    endSpat(K);
    K.players.concat(K.watch).forEach((a) => { a.foos = null; a.wait = 0; });
    Object.assign(K, { on: false, players: [], watch: [], score: [0, 0], st: "walk", ball: null });
    F.dir.foosT = rnd(40, 80);
  };

  const foosGoal = (won) => {
    const K = F.foos, T = F.S.foos, winner = K.players[won], loser = K.players[1 - won];
    K.score[won]++; K.sinceSpat++; K.last = { won }; K.ball = null;
    winner.cheer = 1.1;
    word(pick(FOOS.goal), T.x, T.y - 22, css("--ok", "#2c9a5a"), 13, 1.5);
    if (Math.random() < 0.45) soon(0.7, () => word(pick(FOOS.lose), loser.x, loser.y - 26, css("--text-body", "#555"), 11, 1.5));
    K.st = "goal"; K.t = 1.7;
  };

  // Foosball for the idle: one a side, first to five. The ball really does
  // bounce about the table: the little men slide across to meet it and
  // kick it on, and a goal is a ball that got past them.
  const runFoos = (all, dt) => {
    const K = F.foos, D = F.dir, T = F.S.foos;
    if (!T) { if (K.on) foosOver(); return; }
    const fit = (a) => F.actors.get(a.key) === a && !a.leaving && a.d.mood === "wandering" && a.foos === K;
    const pool = () => all.filter((a) => a.d.mood === "wandering" && free(a) && !a.lunch && !a.d.ghost);
    if (!K.on) {
      D.foosT -= dt;
      if (D.foosT > 0) return;
      D.foosT = 9;
      const up = pool().sort(() => Math.random() - 0.5).slice(0, 3);
      if (up.length < 2) return;
      up.forEach((a) => { a.foos = K; a.bub = null; });
      Object.assign(K, { on: true, players: up.slice(0, 2), watch: up.slice(2), score: [0, 0], st: "walk", ball: null, men: [0, 0, 0, 0], sinceSpat: 0 });
      word("FOOSBALL?", up[0].x, up[0].y - 26, css("--text", "#222"), 12, 1.7);
      return;
    }
    K.players.concat(K.watch).forEach((a) => { if (!fit(a) && a.foos === K) a.foos = null; });
    K.watch = K.watch.filter(fit);
    const left = K.players.filter(fit);
    if (left.length < 2) {
      const sub = K.watch.shift() || pool()[0];
      if (!sub || !left.length) return foosOver();
      sub.foos = K;
      endSpat(K);
      Object.assign(K, { players: left.concat([sub]), score: [0, 0], st: "walk", ball: null });
    }
    if (K.st === "walk") {
      if (K.players.some((a, side) => { const e = foosSide(side); return a.where !== "foos" || a.path.length || far(a, e.x, e.y); })) return;
      K.st = "drop"; K.t = 0.9;
    } else if (K.st === "drop") {
      // The ball is dropped in at the middle.
      K.t -= dt;
      K.ball = { x: 0, y: 0, vx: 0, vy: 0 };
      if (K.t <= 0) { K.ball.vx = rnd(-12, 12); K.ball.vy = (Math.random() < 0.5 ? -1 : 1) * rnd(16, 22); K.st = "play"; }
    } else if (K.st === "play") {
      const B = K.ball, was = B.y;
      B.x += B.vx * dt; B.y += B.vy * dt;
      if (B.x < -5) { B.x = -5; B.vx = Math.abs(B.vx); } else if (B.x > 5) { B.x = 5; B.vx = -Math.abs(B.vx); }
      RODS.forEach((rod, i) => {
        // The two men on a rod are 6 apart; the nearer one goes for it.
        const want = clamp(B.x >= 0 ? B.x - 3 : B.x + 3, -2, 2);
        K.men[i] += clamp(want - K.men[i], -13 * dt, 13 * dt);
        if ((was - rod.y) * (B.y - rod.y) > 0 || was === B.y) return;
        const reach = Math.min(Math.abs(B.x - K.men[i] + 3), Math.abs(B.x - K.men[i] - 3));
        if (reach > 1.6 || Math.random() < 0.2) return;
        // Kicked on, toward the other one's goal: red plays down the table, blue up it.
        const dir = rod.team ? -1 : 1;
        B.y = rod.y + dir * 0.6; B.vy = dir * rnd(20, 32); B.vx = clamp((rnd(-3, 3) - B.x) * rnd(0.8, 2.4), -18, 18);
        K.spin[i] = F.t + 0.22; K.players[rod.team].swingUntil = F.t + 0.2;
      });
      if (Math.abs(B.y) > 10) {
        const top = B.y < 0;
        if (Math.abs(B.x) <= 2.2) return foosGoal(top ? 1 : 0);
        B.y = top ? -10 : 10; B.vy = -B.vy;
      }
      // Each leans along the table toward the rod the ball is near.
      K.players.forEach((a, side) => {
        const p = foosSide(side, clamp(B.y * 0.45, -4, 4)), dy = p.y - a.y;
        if (Math.abs(dy) > 0.4) { a.y += clamp(dy, -18 * dt, 18 * dt); a.shuffle = F.t + 0.12; }
      });
    } else if (K.st === "goal") {
      K.t -= dt;
      if (K.t > 0) return;
      const won = K.last.won, winner = K.players[won], loser = K.players[1 - won];
      if (K.score[won] >= 5) {
        winner.cheer = 1.6;
        word(pick(FOOS.win), winner.x, winner.y - 28, css("--ok", "#2c9a5a"), 12, 1.9);
        K.st = "done"; K.t = 2.6;
      } else if (K.sinceSpat >= 2 && Math.random() < 0.28) {
        // They are already face to face across the table: it is argued there.
        startSpat(K, loser, winner, pick(SPATS.foos));
        K.st = "argue";
      } else { K.st = "drop"; K.t = 0.9; }
    } else if (K.st === "argue") {
      if (!runSpat(K, dt, K.watch)) return;
      if (K.spat.replay) K.score[K.last.won]--;
      endSpat(K);
      K.st = "drop"; K.t = 0.9;
    } else if (K.st === "done") {
      K.t -= dt;
      if (K.t <= 0) foosOver();
    }
  };

  // Lunch comes round every couple of minutes, twice as often at midday.
  const lunchGap = () => {
    const { h, m } = wallTime(), mins = h * 60 + m;
    return rnd(90, 150) / (mins >= 690 && mins <= 810 ? 2 : 1);
  };

  // A few of the idle go out to the picnic table together. With fewer than
  // two idle, someone working comes along and brings the laptop: lunch
  // never changes what a session is said to be doing.
  const startLunch = (all) => {
    const idle = all.filter((a) => a.d.mood === "wandering" && !a.d.ghost && !a.pong && !a.foos).sort(() => Math.random() - 0.5);
    const busy = all.filter((a) => a.d.mood === "working" && a.d.role !== "foreman" && !a.d.ghost && a.where === "seat" && !a.path.length);
    const group = idle.slice(0, LUNCH.length);
    while (group.length < 2 && busy.length) group.push(busy.splice(Math.floor(Math.random() * busy.length), 1)[0]);
    F.dir.lunchT = lunchGap();
    if (group.length < 2) return;
    const L = { phase: "meet", gather: F.t + 10, until: 0 };
    group.forEach((a, i) => { a.lunch = L; a.lunchIdx = i; a.bub = null; });
    F.lunch = L;
    word("LUNCH!", group[0].x, group[0].y - 24, css("--ok", "#2c9a5a"), 13, 1.8);
    group.slice(1).forEach((a) => word(pick(["Coming!", "Finally.", "Yes!", "Wait for me!"]), a.x, a.y - 24, css("--text", "#222"), 11, 1.6));
  };

  const runLunch = (all, dt) => {
    const L = F.lunch;
    if (!L) {
      F.dir.lunchT -= dt;
      if (F.dir.lunchT <= 0) startLunch(all);
      return;
    }
    const group = all.filter((a) => a.lunch === L);
    const there = (where) => group.every((a) => a.where === where && !a.path.length);
    if (L.phase === "meet" && group.length && (there("lunch-meet") || F.t > L.gather)) { L.phase = "eat"; L.until = 0; }
    // The meal is timed from when the last one sits down.
    if (L.phase === "eat" && !L.until && group.length && there("lunch")) L.until = F.t + rnd(20, 28);
    if (group.length < 2 || (L.until && F.t > L.until)) {
      if (group.length) word("Back to it.", group[0].x, group[0].y - 24, css("--text", "#222"), 11, 1.5);
      group.forEach((a) => { a.lunch = null; a.wait = 0; });
      F.lunch = null;
      F.dir.lunchT = lunchGap();
    }
  };

  const direct = (dt) => {
    const D = F.dir, all = Array.from(F.actors.values()).filter((a) => !a.leaving);
    runLunch(all, dt);
    runChats(all, dt);
    runYells(all, dt);
    runPong(all, dt);
    runFoos(all, dt);
    const needs = all.filter((a) => a.d.mood === "needs").sort((a, b) => b.d.urgency - a.d.urgency || (a.key < b.key ? -1 : 1));
    const packed = all.filter((a) => a.d.mood === "packed").sort((a, b) => (a.key < b.key ? -1 : 1));
    D.askT -= dt;
    if (D.askT <= 0) { D.askT = 4.5; D.askI++; }
    // Two questions on show at a time, so their bubbles never pile up.
    const shown = Math.min(needs.length, 2);
    needs.forEach((a, i) => {
      a.needIdx = i; a.bub = null;
      a.asking = needs.length <= shown || ((i - D.askI) % needs.length + needs.length) % needs.length < shown;
    });
    packed.forEach((a, i) => { a.campIdx = i; });
    F.needs = needs; F.campers = packed.filter((a) => a.where === "camp" && !a.path.length).length;

    all.forEach((a) => { a.watched = false; if (a.bub && F.t > a.bub.until) a.bub = null; });
    all.forEach((a) => {
      if (a.where.indexOf("watch:") === 0 && !a.path.length) { const m = F.actors.get(a.where.slice(6)); if (m) m.watched = true; }
    });
    // A crew whose foreman is waiting on you stops and stares at you.
    const blocked = new Set(needs.filter((a) => a.d.role === "foreman" && a.d.urgency >= 2).map((a) => a.d.crew));
    all.forEach((a) => { a.staring = blocked.has(a.d.crew) && a.d.mood === "working" && a.d.role !== "foreman"; });

    D.infoT -= dt;
    if (D.infoT <= 0) {
      D.infoT = all.length > 8 ? 2.4 : 3.6;
      const busy = all.filter((a) => a.d.mood === "working" && a.d.says && !a.bub);
      if (busy.length) { const a = busy[D.infoI++ % busy.length]; a.bub = { text: a.d.says, kind: "info", until: F.t + 5 }; }
    }
    D.jokeT -= dt;
    if (D.jokeT <= 0) {
      D.jokeT = rnd(6, 11);
      const quiet = all.filter((a) => a.d.mood !== "needs" && !a.bub && !a.chat && !a.spat);
      if (quiet.length) { const a = pick(quiet); a.bub = { text: joke(a), kind: "joke", until: F.t + 4.2 }; }
      if (needs.length >= 3 && Math.random() < 0.5) F.boss.bub = { text: pick(SAY.you), kind: "joke", until: F.t + 3.5 };
    }
    if (F.boss.bub && F.t > F.boss.bub.until) F.boss.bub = null;

    // Now and then, something silly.
    D.gagT -= dt;
    if (D.gagT <= 0) {
      D.gagT = rnd(22, 40);
      const seated = all.filter((a) => a.where === "seat" && !a.path.length && a.d.mood === "working");
      if (seated.length >= 2 && Math.random() < 0.55) {
        const from = pick(seated), to = pick(seated.filter((a) => a !== from));
        F.plane = { x0: from.x, y0: from.y - 14, to, t: 0, dur: clamp(Math.hypot(to.x - from.x, to.y - from.y) / 60, 0.8, 2.4) };
      } else if (!F.bug) {
        const y = rnd(F.S.corridorY + 10, F.S.H - 8), left = Math.random() < 0.5;
        F.bug = { x: left ? 6 : F.S.officeW - 10, y, vx: left ? 13 : -13, squashed: 0 };
        if (all.length) word("BUG!", pick(all).x, pick(all).y - 26, css("--alert", "#d43a3a"), 11, 1.4);
      }
    }
  };

  // ---- One tick ---------------------------------------------------------------------
  // The spots the cat jumps up to: where it lies, and the floor it jumps
  // from and back down to.
  const perch = (name) => {
    const S = F.S, s = S.pois[3];
    return name === "pong" ? { x: S.pong.x - 6, y: S.pong.y + 1, fx: S.pong.x - 6, fy: S.pong.y + 13.5 }
      : { x: s.x + 13, y: s.y + 2, fx: s.x + 13, fy: s.y + 8.5 };
  };
  const catHop = (name, up) => {
    const c = F.cat, p = perch(name);
    c.jump = { x0: c.x, y0: c.y, x1: up ? p.x : p.fx, y1: up ? p.y : p.fy, t: 0, up, name };
    c.path = []; c.trail = null; c.goal = null; c.state = "walk";
  };

  // The cat: naps beside a sleeper, on the ping pong table or on the
  // couch, hunts the bug, otherwise strolls. It walks round the furniture
  // like everyone else, and gets onto it with a jump.
  const stepCat = (dt) => {
    const S = F.S, c = F.cat;
    if (c.jump) {
      const j = c.jump;
      j.t += dt;
      const k = Math.min(1, j.t / 0.38);
      c.x = j.x0 + (j.x1 - j.x0) * k; c.y = j.y0 + (j.y1 - j.y0) * k; c.lift = Math.sin(k * Math.PI) * 6;
      if (Math.abs(j.x1 - j.x0) > 0.5) c.flip = j.x1 < j.x0;
      if (k >= 1) {
        c.jump = null; c.lift = 0; c.on = j.up ? j.name : null;
        c.state = j.up ? "sleep" : "sit"; c.wait = j.up ? rnd(14, 26) : rnd(1, 3);
      }
      return;
    }
    // A game on the table it was asleep on: off it goes.
    if (c.on === "pong" && F.pong.on) {
      word("meow!", c.x, c.y - 12, "#b86e1f", 10, 1.2);
      return catHop("pong", false);
    }
    if (F.bug && !F.bug.squashed) {
      if (c.on) return catHop(c.on, false);
      c.state = "hunt"; c.goal = null; c.path = [];
      seek(c, F.bug.x, F.bug.y, 30 * dt, dt);
      c.flip = c.face < 0;
      if (Math.hypot(c.x - F.bug.x, c.y - F.bug.y) < 7) {
        F.bug.squashed = 1.2; c.state = "sit"; c.wait = 3; c.trail = null;
        word("pounce!", c.x, c.y - 12, "#b86e1f", 10, 1.1);
      }
      return;
    }
    if (c.state === "hunt") { c.state = "sit"; c.wait = 3; c.trail = null; return; }
    if (c.state === "walk") {
      if (walk(c, 13 * dt)) { c.flip = c.face < 0; return; }
      // There. Up onto the table or the couch, or down for a sit or a nap.
      if (c.goal && !(c.goal === "pong" && F.pong.on)) return catHop(c.goal, true);
      c.goal = null;
      c.state = c.nap ? "sleep" : "sit"; c.wait = c.nap ? rnd(14, 26) : rnd(3, 8);
      return;
    }
    c.wait -= dt;
    if (c.wait > 0) return;
    if (c.on) return catHop(c.on, false);
    const sleepers = Array.from(F.actors.values()).filter((a) => a.d.mood === "asleep" && a.where === "seat" && !a.path.length);
    c.nap = sleepers.length > 0 && Math.random() < 0.4;
    const s = c.nap ? pick(sleepers).seat : null;
    // At lunch the cat begs by the picnic table.
    const beg = !s && F.lunch && F.lunch.phase === "eat" && Math.random() < 0.6;
    // With nobody playing, the ping pong table is a fine place to nap. So is the couch.
    const up = s || beg ? null : !F.pong.on && Math.random() < 0.22 ? "pong" : Math.random() < 0.16 ? "couch" : null;
    const p = s ? { x: s.aisle, y: s.y + 3 } : beg ? { x: S.table.x + 17, y: S.table.y + 15 }
      : up ? { x: perch(up).fx, y: perch(up).fy } : loungePt();
    const q = freePt(p.x, p.y);
    c.goal = up; c.path = pathTo(c.x, c.y, q.x, q.y); c.state = "walk";
  };

  const update = (dt) => {
    const S = F.S, B = F.boss;
    direct(dt);
    for (const a of F.actors.values()) {
      stepActor(a, dt);
      emit(a, dt);
      if (a.leaving && a.bub && F.t > a.bub.until) a.bub = null;
      if (a.gone) F.actors.delete(a.key);
    }

    // You: the keys, or a walk to wherever was tapped. The furniture is in
    // your way too.
    const kx = (F.keys.d ? 1 : 0) - (F.keys.a ? 1 : 0), ky = (F.keys.s ? 1 : 0) - (F.keys.w ? 1 : 0);
    if (kx || ky) {
      const n = Math.hypot(kx, ky), p = slide(B.x, B.y, (kx / n) * 64 * dt, (ky / n) * 64 * dt);
      B.moving = p.x !== B.x || p.y !== B.y;
      if (kx) B.face = kx;
      B.x = p.x; B.y = p.y; B.path = [];
    } else B.moving = walk(B, 64 * dt);

    // What was put off until now.
    F.later = F.later.filter((job) => { if (job.at > F.t) return true; job.run(); return false; });

    // The water cooler drains as they drink. Once it is dry, someone comes
    // in by the door with a full bottle and carries the empty one out.
    const C = F.cooler, W = S.pois[1];
    if (C.level > C.target) C.level = Math.max(C.target, C.level - 0.2 * dt);
    else if (C.level < C.target) C.level = Math.min(C.target, C.level + 0.7 * dt);
    if (C.level <= 0.01 && C.target <= 0.01 && !C.runner) {
      C.refillT -= dt;
      if (C.refillT <= 0) {
        const to = freePt(W.x - 2, W.y + 4);
        C.runner = { x: -8, y: S.door.y, full: true, pause: 0, path: pathTo(-8, S.door.y, to.x, to.y) };
      }
    }
    if (C.runner) {
      const r = C.runner;
      if (r.pause > 0) r.pause -= dt;
      else if (walk(r, 36 * dt)) { /* on the way */ }
      else if (r.full) {
        r.full = false; r.pause = 1.1; C.target = 1; r.path = pathTo(r.x, r.y, -9, S.door.y);
        word("Fresh water!", W.x, W.y - 26, "#2a8fd0", 11, 1.8);
      } else C.runner = null;
    }

    stepCat(dt);
    if (F.bug) {
      if (F.bug.squashed) { F.bug.squashed -= dt; if (F.bug.squashed <= 0) F.bug = null; }
      else { F.bug.x += F.bug.vx * dt; F.bug.y += Math.sin(F.t * 7) * 6 * dt; if (F.bug.x < 2 || F.bug.x > S.officeW - 6) F.bug = null; }
    }
    if (F.plane) {
      F.plane.t += dt;
      if (F.plane.t >= F.plane.dur) { word("Hey!", F.plane.to.x, F.plane.to.y - 26, css("--text", "#222"), 11, 1.2); F.plane = null; }
    }
    // Nobody home: a tumbleweed.
    if (!F.actors.size) {
      if (!F.tumble) F.tumble = { x: -8 };
      F.tumble.x += 24 * dt;
      if (F.tumble.x > S.officeW - 10) F.tumble.x = -8;
    } else F.tumble = null;

    for (let i = F.parts.length - 1; i >= 0; i--) {
      const p = F.parts[i];
      p.life -= dt; p.x += p.vx * dt; p.y += p.vy * dt; if (p.g) p.vy += p.g * dt;
      if (p.life <= 0) F.parts.splice(i, 1);
    }
    if (F.shake > 0) F.shake -= dt;
  };

  // ---- Drawing a frame ----------------------------------------------------------------
  const wrap = (text, max) => {
    const words = text.split(" "), lines = [];
    let line = "";
    words.forEach((w) => {
      const next = line ? line + " " + w : w;
      if (g.measureText(next).width <= max || !line) line = next;
      else { lines.push(line); line = w; }
    });
    if (line) lines.push(line);
    if (lines.length > 3) { lines.length = 3; lines[2] = lines[2].replace(/.{0,2}$/, "…"); }
    return lines;
  };

  // A speech bubble over (ax, ay) in art pixels. Solid for a session's own
  // words, fainter and in italics for a joke or a line of small talk.
  const bubble = (b, ax, ay, placed) => {
    const PX = F.PX, joking = b.kind === "joke" || b.kind === "chat", ask = b.kind === "ask";
    g.font = font(joking ? 12 : 13, ask ? 700 : 500, joking);
    const lines = wrap(b.text, ask ? 210 : 180);
    const tw = Math.max.apply(null, lines.map((l) => g.measureText(l).width));
    const w = Math.ceil(tw) + 18, lh = joking ? 15 : 16, h = lines.length * lh + 11;
    const cx = ax * PX, cw = F.W * PX;
    // Over the head, or under the feet for one standing in front of the others.
    let x = clamp(cx - w / 2, 4, cw - w - 4), y = b.below ? ay * PX + 27 : ay * PX - h - 9;
    for (let n = 0; n < 4; n++) {
      const hit = placed.find((r) => x < r.x + r.w + 4 && x + w + 4 > r.x && y < r.y + r.h + 4 && y + h + 4 > r.y);
      if (!hit) break;
      y = b.below ? hit.y + hit.h + 5 : hit.y - h - 5;
    }
    y = clamp(y, 3, F.H * PX - h - 3);
    placed.push({ x, y, w, h });
    g.globalAlpha = joking ? 0.9 : 1;
    g.fillStyle = ask ? css("--alert", "#d43a3a") : css("--surface", "#fff");
    g.strokeStyle = ask ? css("--alert", "#d43a3a") : css("--border-strong", "#999");
    g.lineWidth = 1.2;
    g.beginPath();
    if (g.roundRect) g.roundRect(x, y, w, h, 8); else g.rect(x, y, w, h);
    g.fill(); g.stroke();
    const tipX = clamp(cx, x + 12, x + w - 12);
    g.beginPath();
    if (b.below) { g.moveTo(tipX - 6, y + 0.5); g.lineTo(tipX, y - 7); g.lineTo(tipX + 6, y + 0.5); }
    else { g.moveTo(tipX - 6, y + h - 0.5); g.lineTo(tipX, y + h + 7); g.lineTo(tipX + 6, y + h - 0.5); }
    g.closePath(); g.fill();
    g.fillStyle = ask ? "#fff" : joking ? css("--text-body", "#555") : css("--text", "#222");
    g.textAlign = "left"; g.textBaseline = "top";
    lines.forEach((l, i) => g.fillText(l, x + 9, y + 6 + i * lh));
    g.globalAlpha = 1;
  };

  const tag = (text, ax, ay, kind, max) => {
    const PX = F.PX;
    g.font = font(10.5, 700);
    let label = text;
    while (label.length > 4 && g.measureText(label).width > (max || 88)) label = label.slice(0, -2).trimEnd() + "…";
    const w = Math.ceil(g.measureText(label).width) + 10, x = clamp(ax * PX - w / 2, 2, F.W * PX - w - 2), y = ay * PX + 3;
    g.globalAlpha = 0.92;
    g.fillStyle = kind === "needs" ? css("--alert", "#d43a3a") : kind === "foreman" ? "#ffd21f" : kind === "you" ? css("--info", "#2a78d6") : css("--surface", "#fff");
    g.beginPath();
    if (g.roundRect) g.roundRect(x, y, w, 15, 7.5); else g.rect(x, y, w, 15);
    g.fill();
    g.globalAlpha = 1;
    g.fillStyle = kind === "needs" || kind === "you" ? "#fff" : kind === "foreman" ? "#1d1d1d" : css("--text", "#222");
    g.textAlign = "center"; g.textBaseline = "middle";
    g.fillText(label, x + w / 2, y + 8);
  };

  // The red "!" over one that needs you: bigger and flashing as it waits.
  const mark = (a, top) => {
    const u = a.d.urgency, t = F.t + a.phase;
    const bounce = Math.round(Math.abs(Math.sin(t * (3 + u))) * (1 + u));
    const twin = u >= 3 || a.d.role === "foreman";
    const flash = u >= 2 && Math.floor(t * 5) % 2 === 0;
    const one = (x) => {
      const y = top - 11 - bounce;
      R(x - 3, y, 6, 9, flash ? "#ffd21f" : "#e0352b"); R(x - 2, y - 1, 4, 11, flash ? "#ffd21f" : "#e0352b");
      const ink = flash ? "#7a1410" : "#fff";
      R(x - 1, y + 1, 2, 4, ink); R(x - 1, y + 6, 2, 2, ink);
    };
    if (twin) { one(a.x - 4); one(a.x + 4); } else one(Math.round(a.x));
  };

  const drawActor = (a) => {
    const d = a.d, o = lookOf(a), S = F.S, t = F.t + a.phase;
    const seated = a.where === "seat" && !a.path.length && a.seat && !far(a, a.seat.x, a.seat.y);
    o.walking = a.moving || F.t < (a.shuffle || 0);
    if (a.moving) o.look = a.face;
    // On the couch: sat down, legs out of sight.
    if (a.where === "poi:couch" && !a.path.length) o.seated = true;
    if (seated) {
      o.seated = true;
      if (d.mood === "asleep") { o.sleeping = true; o.headDrop = 3; }
      if (d.mood === "working" && d.long) o.blush = true;
      if (a.staring) o.look = F.boss.x < a.x ? -1 : 1;
      if (a.watched) o.blush = true;
    }
    if (d.mood === "needs" && !a.leaving) {
      const u = d.urgency;
      o.mouth = u >= 3 ? 2 : 1;
      if (a.where === "boss") {
        o.hop = Math.abs(Math.sin(t * (5 + u))) * (1 + Math.min(u, 2));
        o.pose = u >= 4 ? "hold" : u === 3 ? "hold" : u === 2 ? "wave" : "down";
        if (d.role === "foreman") { o.siren = true; if (u < 3) o.pose = "cheer"; }
      } else if (d.role === "foreman") o.siren = true;
    }
    if (d.mood === "packed" && a.where === "camp" && !a.path.length) {
      o.seated = true;
      o.pose = Math.floor(t / 5) % 4 === 0 ? "wave" : "down";
    }
    const eating = a.where === "lunch" && !a.path.length;
    if (eating) { o.seated = true; o.pose = Math.floor(t * 1.3) % 2 ? "hold" : "down"; o.mouth = Math.floor(t * 4) % 2; }
    const atCoffee = a.where === "poi:coffee" && !a.path.length;
    const atCooler = a.where === "poi:cooler" && !a.path.length;
    if (a.where.indexOf("watch:") === 0 && !a.path.length) o.pose = "hold";
    // Talking: they face each other, and whoever has the floor moves a mouth.
    if (a.chat && d.mood !== "needs") {
      const other = a.chat.who[0] === a ? a.chat.who[1] : a.chat.who[0];
      o.look = other.x < a.x ? -1 : 1;
      if (a.bub && a.bub.kind === "chat") o.mouth = Math.floor(t * 6) % 2;
    }
    // A coffee carried about, with a sip now and then.
    const cup = a.cup > F.t && d.mood === "wandering" && !a.pong && !a.foos && !a.lunch && !a.leaving;
    const sip = cup && !a.moving && Math.floor(t * 0.6) % 4 === 0;
    if (sip) o.pose = "hold";
    if (a.cheer > 0 && d.mood !== "needs") { o.pose = "cheer"; o.mouth = 2; o.hop = Math.abs(Math.sin(t * 9)) * 2; }
    // Ping pong: the paddle hand is the one nearer the table. The two
    // playing bounce on their toes and jump for a smash; those waiting
    // their turn watch the ball.
    const P = F.pong, side = a.pong && a.where === "pong" && !a.path.length ? P.players.indexOf(a) : -1;
    const watching = a.pong && side < 0 && a.where === "pong" && !a.path.length;
    const swing = side >= 0 && F.t < (a.swingUntil || 0);
    if (side >= 0 && !a.spat) {
      o.look = side ? -1 : 1;
      if (swing) o.pose = side ? "holdL" : "hold";
      if (P.st === "rally" && a.cheer <= 0) o.hop = Math.abs(Math.sin(t * 8));
      if (F.t < (a.jumpUntil || 0)) o.hop = Math.sin(((a.jumpUntil - F.t) / 0.35) * Math.PI) * 5;
    }
    if (watching && P.ball) o.look = P.ball.x > F.S.pong.x ? 1 : -1;
    // Foosball: a hand on the rods, jerking as they turn; those watching
    // follow the ball.
    const K = F.foos, fside = a.foos && a.where === "foos" && !a.path.length ? K.players.indexOf(a) : -1;
    if (fside >= 0 && !a.spat && a.cheer <= 0) {
      o.look = fside ? -1 : 1;
      const jerk = K.st === "play" && (F.t < (a.swingUntil || 0) || Math.floor(t * 9) % 3 === 0);
      o.pose = jerk ? "down" : fside ? "outL" : "outR";
    }
    if (a.foos && fside < 0 && a.where === "foos" && !a.path.length && K.ball) o.look = K.ball.x > 0 ? 1 : -1;
    // An argument: face to face, and whoever has the floor waves their arms.
    if (a.spat && !a.path.length) {
      const other = a.spat.who[0] === a ? a.spat.who[1] : a.spat.who[0];
      o.look = other.x < a.x ? -1 : 1;
      if (a.bub && a.bub.kind === "chat") {
        o.mouth = 1 + (Math.floor(t * 6) % 2);
        o.pose = Math.floor(t * 3) % 2 ? "cheer" : other.x < a.x ? "outL" : "outR";
        o.hop = Math.abs(Math.sin(t * 10)) * 1.5;
      }
    }
    // A wave goodbye, or a wave back.
    if (F.t < a.waveT && (a.leaving || d.mood !== "needs")) { o.pose = "wave"; if (a.leaving) o.mouth = 1; }

    if (a.flop > 0) {
      // Flat on the floor, sign and all.
      g.save(); g.translate(Math.round(a.x) - 6, Math.round(a.y)); g.rotate(-Math.PI / 2);
      o.out = true; o.flat = true; o.pose = "down"; o.hop = 0; o.walking = false;
      person(0, 0, o);
      g.restore();
      return;
    }
    person(a.x, a.y, o);
    const x = Math.round(a.x), y = Math.round(a.y) - Math.round(o.hop || 0);

    // What is in the hands.
    if (d.mood === "needs" && !a.leaving && a.where === "boss" && d.urgency === 3) {
      // A bullhorn, and the noise coming out of it.
      R(x + 5, y - 12, 2, 2, "#d8dde5"); R(x + 7, y - 13, 2, 4, "#e0352b"); R(x + 9, y - 14, 1, 6, "#e0352b");
      const n = Math.floor(t * 6) % 4;
      for (let i = 0; i < n; i++) { R(x + 12 + i * 3, y - 14 - i, 1, 2, "#e0352b"); R(x + 12 + i * 3, y - 9 + i, 1, 2, "#e0352b"); }
    }
    if (d.mood === "needs" && !a.leaving && a.where === "boss" && d.urgency >= 4) {
      R(x + 4, y - 26, 1, 15, "#7a5633"); R(x - 9, y - 37, 27, 12, "#e0352b"); R(x - 8, y - 36, 25, 10, "#ffffff");
      a.sign = { x: x + 4.5, y: y - 31 };
    } else a.sign = null;
    if (side >= 0) {
      // The paddle: up for a swing, down between shots.
      const px = side ? x - 7 : x + 5, py = swing ? y - 14 : y - 6;
      R(px, py, 2, 3, "#d43a3a"); R(px, py + 3, 1, 1, "#8a6238");
    }
    if (atCooler) { R(x + 5, y - 7, 2, 2, "#e9f7ff"); R(x + 5, y - 6, 2, 1, F.cooler.level > 0.01 ? "#4fb0ea" : "#e9f7ff"); }
    if (d.role === "foreman" && d.mood !== "asleep" && side < 0 && fside < 0 && !(d.mood === "needs" && d.urgency >= 3)) {
      // The clipboard.
      R(x - 9, y - 9, 4, 5, "#8a6238"); R(x - 8, y - 8, 2, 3, "#ffffff"); R(x - 8, y - 10, 2, 1, "#8a8f98");
    }
    if (atCoffee || cup || (d.role === "foreman" && d.mood === "wandering" && !a.moving && side < 0 && fside < 0)) {
      const cy = sip ? y - 13 : y - 7;
      R(x + 5, cy, 2, 2, "#f4f4f4");
      if (Math.floor(t * 2) % 2) R(x + 5, cy - 2, 1, 1, "rgba(230,230,235,0.8)");
    }
    if (d.mood === "packed" && a.where === "camp" && !a.path.length) {
      // The bag, packed, and a marshmallow held out to the fire.
      const side = a.x < S.fire.x ? -1 : 1;
      R(x + side * 7 - 2, y - 6, 5, 6, "#b5452c"); R(x + side * 7 - 2, y - 6, 5, 1, "#d9654a"); R(x + side * 7, y - 4, 1, 2, "#ffd21f");
      for (let i = 1; i <= 5; i++) R(x - side * (4 + i), y - 6 - Math.round(i / 3), 1, 1, "#7a5633");
      R(x - side * 10, y - 9, 2, 2, "#fff8ee");
    }
    if (eating) {
      // A sandwich (a battery for a robot), and the laptop for a working lunch.
      const up = o.pose === "hold", fx = x + 3, fy = up ? y - 13 : y - 5;
      if (d.tool === "codex") { R(fx, fy, 3, 2, "#3ba37a"); R(fx + 3, fy, 1, 2, "#22252b"); }
      else { R(fx, fy, 3, 1, "#e8c98f"); R(fx, fy + 1, 3, 1, "#6aa84f"); R(fx, fy + 2, 3, 1, "#e8c98f"); }
      if (d.mood === "working") { R(x - 6, y - 6, 6, 4, "#2a2f3a"); R(x - 4, y - 5, 2, 2, a.color); }
    }
    if (d.helpers > 0 && seated && d.mood === "working") {
      for (let i = 0; i < d.helpers; i++) {
        const ph = t * 1.3 + i * 2.1;
        helper(a.x + Math.cos(ph) * 15, a.y + 11 + Math.sin(ph * 2) * 2, a.color, t + i);
      }
    }
  };

  const drawBoss = () => {
    const B = F.boss, swamped = (F.needs || []).filter((a) => a.d.urgency >= 3).length >= 2;
    person(B.x, B.y, {
      phase: 0, skin: SKIN[1], hair: HAIR[0], style: 0, shirt: "#f4f4f4", pants: "#2b3140", tie: true, crown: true,
      walking: B.moving, look: B.moving ? B.face : 0, blush: swamped, mouth: swamped ? 1 : 0,
    });
    const x = Math.round(B.x), y = Math.round(B.y);
    R(x + 5, y - 6, 2, 2, "#f4f4f4"); R(x + 7, y - 5, 1, 1, "#f4f4f4");
    if (swamped && Math.floor(F.t * 3) % 2) { R(x - 7, y - 14, 1, 2, "#6cc5ff"); R(x + 6, y - 15, 1, 2, "#6cc5ff"); }
  };

  const draw = () => {
    const S = F.S, sx = F.shake > 0 ? Math.round(Math.sin(F.t * 70)) : 0;
    g = F.canvas.getContext("2d");
    g.imageSmoothingEnabled = false;
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.clearRect(0, 0, F.canvas.width, F.canvas.height);
    g.drawImage(F.bg, sx * F.U, 0);
    art(sx);

    // The wall: the beacon, the clock hands.
    const mid = Math.round(S.officeW / 2), needs = F.needs || [];
    const lit = needs.length > 0, on = Math.floor(F.t * 4) % 2 === 0;
    R(mid - 49, 5, 4, 5, lit ? (on ? "#ff3b30" : "#7a1410") : "#3ba37a");
    if (lit && on) { g.fillStyle = "rgba(255,59,48,0.2)"; g.beginPath(); g.arc(mid - 47, 7.5, 5.5, 0, TAU); g.fill(); }
    const { h, m } = wallTime(), cx = mid + 44, cy = 14;
    g.fillStyle = "#f4f4f4"; g.beginPath(); g.arc(cx, cy, 6.5, 0, TAU); g.fill();
    g.strokeStyle = "#22252b"; g.lineWidth = 1; g.beginPath(); g.arc(cx, cy, 6.5, 0, TAU); g.stroke();
    const hand = (turn, len) => { g.beginPath(); g.moveTo(cx, cy); g.lineTo(cx + Math.sin(turn * TAU) * len, cy - Math.cos(turn * TAU) * len); g.stroke(); };
    hand(((h % 12) + m / 60) / 12, 3.2); hand(m / 60, 5);
    coolerWater();

    // Everything standing on the floor, back to front.
    const things = [];
    things.push({ z: S.pong.y + 6, f: pongTable });
    // The ball is drawn over the two playing, or where it lies on the floor.
    if (F.pong.on && F.pong.ball) things.push({ z: F.pong.ball.floor ? F.pong.ball.y : S.pong.y + 12.5, f: pongBall });
    if (S.foos) things.push({ z: S.foos.y + 11, f: foosTable });
    if (F.cooler.runner) {
      const r = F.cooler.runner;
      things.push({ z: r.y, f: () => helper(r.x, r.y, "#2a78d6", F.t, r.full ? "#4fb0ea" : "#e3f1fa") });
    }
    S.zones.forEach((z) => z.seats.forEach((s) => things.push({ z: s.y + 5, f: () => desk(s, F.actors.get(s.key)) })));
    for (const a of F.actors.values()) things.push({ z: a.y, f: () => drawActor(a) });
    things.push({ z: F.boss.y, f: drawBoss });
    // On the ping pong table, or in the air on the way, the cat is drawn over it.
    const catUp = F.cat.on === "pong" || (F.cat.jump && F.cat.jump.name === "pong");
    things.push({ z: catUp ? S.pong.y + 7 : F.cat.y, f: drawCat });
    things.push({ z: S.fire.y, f: () => fire(F.campers > 0) });
    things.push({ z: S.table.y + 1, f: table });
    if (F.bug) {
      things.push({ z: F.bug.y, f: () => {
        const b = F.bug, x = Math.round(b.x), y = Math.round(b.y);
        if (b.squashed) { R(x - 2, y, 5, 1, "#3a2a1a"); return; }
        R(x - 1, y - 2, 3, 2, "#3a2a1a"); R(x - 2 + (Math.floor(F.t * 12) % 2), y, 1, 1, "#3a2a1a"); R(x + 1, y, 1, 1, "#3a2a1a");
        R(x + (b.vx > 0 ? 2 : -2), y - 2, 1, 1, "#e0352b");
      } });
    }
    if (F.tumble) {
      things.push({ z: S.H - 20, f: () => {
        // Along the way in from the door, which the furniture leaves clear.
        const x = Math.round(F.tumble.x), y = S.door.y + 3 - Math.round(Math.abs(Math.sin(F.t * 4)) * 4), r = Math.floor(F.t * 6) % 2;
        R(x - 3, y - 6, 6, 6, "#b89a62"); R(x - 4, y - 5, 8, 4, "#b89a62"); R(x - 2 + r, y - 5, 1, 4, "#8a7040"); R(x + 1 - r, y - 4, 1, 3, "#8a7040");
      } });
    }
    things.sort((p, q) => p.z - q.z).forEach((p) => p.f());

    if (F.plane) {
      const p = F.plane, k = p.t / p.dur, x = Math.round(p.x0 + (p.to.x - p.x0) * k);
      const y = Math.round(p.y0 + (p.to.y - 14 - p.y0) * k - Math.sin(k * Math.PI) * 16);
      R(x - 2, y, 5, 1, "#ffffff"); R(x - 1, y - 1, 3, 1, "#e6ebf0"); R(x, y + 1, 1, 1, "#b8c0cc");
    }
    F.parts.forEach((p) => { if (!p.text) { g.globalAlpha = clamp(p.life / p.max * 1.4, 0, 1); R(Math.round(p.x), Math.round(p.y), p.s, p.s, p.color); } });
    g.globalAlpha = 1;
    // The "!" sits over the head, the hard hat or the picket sign.
    for (const a of F.actors.values()) {
      if (a.d.mood === "needs" && !a.leaving && a.flop <= 0) mark(a, Math.round(a.y) - (a.sign ? 38 : a.d.role === "foreman" ? 23 : 18));
    }

    // Words: the sign on the wall, name tags, flying words, bubbles.
    ui(sx);
    const PX = F.PX;
    g.textAlign = "center"; g.textBaseline = "middle"; g.font = font(13 * PX / 3, 800);
    g.fillStyle = lit ? (on ? "#ff5a4d" : "#b3261e") : "#4cd08a";
    const count = needs.length;
    g.fillText(lit ? (count === 1 ? "1 NEEDS YOU" : count + " NEED YOU") : F.actors.size ? "ALL QUIET" : "NOBODY HOME", mid * PX, 14.6 * PX);

    for (const a of F.actors.values()) {
      if (a.flop > 0) continue;
      // At the picnic table they sit close, so the tags are kept short.
      tag(a.d.tag, a.x, a.y, a.d.mood === "needs" && !a.leaving ? "needs" : a.d.role === "foreman" ? "foreman" : "", a.where === "lunch" ? 56 : 88);
      if (a.sign) {
        g.font = font(9.5 * PX / 3, 800); g.fillStyle = "#b3261e"; g.textAlign = "center"; g.textBaseline = "middle";
        g.fillText(SIGNS[a.signI % SIGNS.length], a.sign.x * PX, a.sign.y * PX);
      }
    }
    tag("YOU", F.boss.x, F.boss.y, "you");
    // The score over each table (higher up while two argue behind it),
    // and the bad news over the cooler.
    const P = F.pong, K = F.foos;
    const score = (G, at, up, crowd) => {
      g.font = font(12, 800); g.fillStyle = css("--text", "#222"); g.textAlign = "center"; g.textBaseline = "middle";
      g.fillText(G.score[0] + " : " + G.score[1], (at.x + 0.5) * PX, (at.y - (crowd ? up + 17 : up)) * PX);
    };
    if (P.on && P.players.length === 2 && P.players.every((a) => a.where === "pong")) score(P, S.pong, 14, P.st === "argue");
    if (K.on && S.foos && K.players.length === 2 && K.players.every((a) => a.where === "foos" && !a.path.length)) score(K, S.foos, 17, false);
    if (F.cooler.level <= 0.01) {
      g.font = font(9, 800); g.fillStyle = css("--alert", "#d43a3a"); g.textAlign = "center"; g.textBaseline = "middle";
      g.fillText("EMPTY", (S.pois[1].x - 12.5) * PX, (S.pois[1].y - 20) * PX);
    }
    F.parts.forEach((p) => {
      if (!p.text) return;
      g.globalAlpha = clamp(p.life / p.max * 1.6, 0, 1);
      g.font = p.mono ? `700 ${p.size}px ui-monospace, Menlo, monospace` : font(p.size, 800);
      g.fillStyle = p.color; g.textAlign = "center"; g.textBaseline = "middle";
      g.fillText(p.text, p.x * PX, p.y * PX);
    });
    g.globalAlpha = 1;
    if (!F.actors.size) {
      g.font = font(18, 700); g.fillStyle = css("--text-muted", "#888"); g.textAlign = "center";
      g.fillText("Nobody is working. Suspicious.", (S.officeW / 2) * PX, (S.corridorY + 12) * PX);
    }
    const placed = [];
    for (const a of F.needs || []) {
      if (!a.asking || !a.d.says || a.flop > 0) continue;
      const below = a.where === "boss" && a.y > F.boss.y + 10;
      bubble({ text: a.d.says, kind: "ask", below }, a.x, below ? a.y : a.y - (a.sign ? 50 : 30), placed);
    }
    for (const a of F.actors.values()) if (a.bub && (a.d.mood !== "needs" || a.leaving)) bubble(a.bub, a.x, a.y - (a.d.role === "foreman" ? 21 : 18), placed);
    if (F.boss.bub) bubble(F.boss.bub, F.boss.x, F.boss.y - 21, placed);
    g.setTransform(1, 0, 0, 1, 0, 0);
  };

  // ---- The cast from the server ----------------------------------------------------------
  const place = (a) => {
    const S = F.S, d = a.d;
    let p;
    if (d.mood === "packed") p = campSpot(a);
    else if (d.mood === "needs") p = bossSlot(a);
    else if (d.mood === "wandering" || !a.seat) p = spotFrom(a, loungePt);
    else p = a.seat;
    a.x = p.x; a.y = p.y; a.path = []; a.trail = null;
    a.where = d.mood === "packed" ? "camp" : d.mood === "needs" ? "boss" : p === a.seat ? "seat" : "";
    a.wait = rnd(0, 4);
  };

  const setCast = (cast) => {
    F.cast = Array.isArray(cast) ? cast : [];
    const had = F.S;
    if (!layout()) return;
    const S = F.S, keys = new Set(F.cast.map((m) => m.key));
    if (!had) {
      const b = freePt(S.home.x, S.home.y), c = freePt(S.home.x + 40, S.H - 5);
      F.boss.x = b.x; F.boss.y = b.y; F.boss.path = [];
      Object.assign(F.cat, { x: c.x, y: c.y, path: [], on: null, jump: null, goal: null, lift: 0, state: "sit" });
    }
    // Whoever is no longer in the cast says goodbye and leaves: one after
    // another, when several go at once.
    let going = 0;
    for (const a of F.actors.values()) {
      if (keys.has(a.key) || a.leaving) continue;
      a.leaving = true; a.bye = 0; a.wait = going++ * 0.9; a.seat = null; a.bub = null; a.chat = null;
      // One that lay down waiting on you gets up to say goodbye.
      a.flop = 0;
      if (!solidAt(a.x, a.y)) a.path = [];
    }
    let camp = 0, need = 0;
    F.cast.forEach((m) => {
      let a = F.actors.get(m.key);
      const fresh = !a;
      if (fresh) { a = newActor(m); F.actors.set(m.key, a); }
      else if (a.d.mood !== m.mood) {
        a.wait = 0; a.bub = null;
        if (m.mood === "needs") { word("!", a.x, a.y - 24, css("--alert", "#d43a3a"), 18, 1.2); a.shoutT = 0.4; }
      }
      a.d = m; a.leaving = false; a.bye = 0;
      a.seat = S.seats.get(m.key) || null;
      a.color = a.seat ? a.seat.zone.color : (S.zones.find((z) => z.name === m.crew) || { color: CREW[0] }).color;
      if (m.mood === "packed") a.campIdx = camp++;
      if (m.mood === "needs") a.needIdx = need++;
      if (fresh) {
        // On the first cast everyone is already where they belong; later a
        // new session walks in through the door.
        if (F.firstCast) place(a);
        else { a.x = -9; a.y = S.door.y; a.where = "spawn"; }
      }
    });
    F.firstCast = false;
    // More or fewer sessions can change the size of the people, and so of
    // the room, or push the open floor down a row.
    if (had && (had.W !== S.W || had.H !== S.H)) settle(true);
    else if (had && had.sig !== S.sig) settle(false);
    else if (had && had.desks !== S.desks) stepClear();
  };

  // The desks moved and nothing else did: a crew gained or lost one, and
  // its row was centred again. Whoever a desk landed on steps clear of it,
  // and whoever was walking where one now stands finds a new way. The
  // games and the small talk carry on.
  const stepClear = () => {
    const clearOf = (o) => { if (solidAt(o.x, o.y)) { const f = freePt(o.x, o.y); o.x = f.x; o.y = f.y; } };
    // Does a walk now cut through something? Its first step may be out of
    // a seat and its last into one, and those two are meant to.
    const blocked = (o) => {
      let x = o.x, y = o.y;
      return o.path.some(([px, py], i) => {
        const cut = !clear(x, y, px, py) && !(i === 0 && solidAt(o.x, o.y)) && !(i === o.path.length - 1 && solidAt(px, py));
        x = px; y = py;
        return cut;
      });
    };
    // The same walk again, round the desks as they now stand.
    const reroute = (o) => { const end = o.path[o.path.length - 1]; o.path = pathTo(o.x, o.y, end[0], end[1]); };
    for (const a of F.actors.values()) {
      a.trail = null;
      // Just walking in at the door, or already out of it.
      if (a.where === "spawn" || a.x < 7) continue;
      if (a.path.length) {
        if (!blocked(a)) continue;
        // To wherever it was going, by a new way: think() sends it again.
        a.path = [];
        if (a.leaving) a.bye = Math.min(a.bye, 1); else a.where = "";
      } else if (a.where === "seat" || a.where === "lunch" || a.where === "poi:couch" || a.spat) continue;
      clearOf(a);
    }
    const B = F.boss, c = F.cat, r = F.cooler.runner;
    clearOf(B);
    if (B.path.length && blocked(B)) reroute(B);
    if (!c.on && !c.jump) {
      clearOf(c); c.trail = null;
      if (c.path.length && blocked(c)) reroute(c);
    }
    if (r && r.path.length && blocked(r)) reroute(r);
  };

  // After the room is laid out afresh. `full`: it changed size, so everyone
  // is put back where they belong in it. Otherwise the furniture has only
  // shifted: whoever it landed on steps clear and finds a new way. Either
  // way the games, the small talk and lunch start over.
  const settle = (full) => {
    const S = F.S;
    F.lunch = null; F.chats = []; F.cooler.runner = null;
    endSpat(F.pong); endSpat(F.foos);
    Object.assign(F.pong, pongReset, { on: false, players: [], queue: [], score: [0, 0], want: [null, null] });
    Object.assign(F.foos, { on: false, players: [], watch: [], score: [0, 0], st: "walk", ball: null });
    const clearOf = (o) => { const q = clampPt(o.x, o.y), f = freePt(q.x, q.y); o.x = f.x; o.y = f.y; };
    for (const a of F.actors.values()) {
      a.seat = a.leaving ? null : S.seats.get(a.key) || null;
      a.lunch = null; a.chat = null; a.pong = null; a.foos = null; a.spat = null; a.trail = null;
      // Just walking in at the door, or already out of it.
      if (a.where === "spawn" || a.x < 7) continue;
      if (full && !a.leaving) { place(a); continue; }
      a.path = [];
      if (a.leaving) a.bye = Math.min(a.bye, 1);
      else if (a.seat && a.where === "seat" && !far(a, a.seat.x, a.seat.y)) continue;
      else a.where = "";
      clearOf(a);
    }
    clearOf(F.boss); F.boss.path = [];
    clearOf(F.cat);
    Object.assign(F.cat, { path: [], on: null, jump: null, goal: null, lift: 0, state: "sit", trail: null, wait: 1 });
  };

  // The room changed size.
  const resettle = () => { if (layout()) settle(true); };

  // ---- Running -------------------------------------------------------------------------
  // Only while the Floor tab is the one showing, so the other tabs and a
  // hidden browser tab cost nothing.
  const showing = () => {
    if (document.visibilityState === "hidden") return false;
    const tab = document.querySelector('.board-tab[data-tab="floor"]');
    return !tab || tab.classList.contains("on");
  };
  const calm = () => !!(window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches);

  const frame = (ts) => {
    F.raf = requestAnimationFrame(frame);
    if (!F.S || !showing()) { F.last = 0; return; }
    // 30 frames a second is plenty; 4 for someone who asked for less motion.
    if (F.last && ts - F.last < (calm() ? 250 : 30)) return;
    const dt = F.last ? Math.min((ts - F.last) / 1000, 0.1) : 0.016;
    F.last = ts; F.t += dt;
    paint(dt);
  };

  // One picture: the room again if the theme or the minute changed, then
  // everyone in it, moved on by `dt` seconds.
  const paint = (dt) => {
    if (!F.S) return;
    const dark = darkNow(), minute = wallTime().m;
    if (dark !== F.dark || minute !== F.minute || !F.pal) { F.dark = dark; F.minute = minute; F.pal = ROOM[dark ? "dark" : "light"]; F.bgDirty = true; }
    if (F.bgDirty) drawBackground();
    update(dt);
    draw();
  };

  const toArt = (e) => {
    const box = F.canvas.getBoundingClientRect();
    return { x: ((e.clientX - box.left) / box.width) * F.W, y: ((e.clientY - box.top) / box.height) * F.H };
  };
  const actorAt = (p) => {
    let best = null, bestD = 1e9;
    for (const a of F.actors.values()) {
      if (a.leaving) continue;
      const dx = Math.abs(p.x - a.x), dy = p.y - (a.y - 8);
      if (dx <= 9 && dy >= -14 && dy <= 15) { const dd = dx + Math.abs(dy); if (dd < bestD) { bestD = dd; best = a; } }
    }
    return best;
  };

  const onTap = (e) => {
    if (!F.S) return;
    const p = toArt(e), a = actorAt(p), B = F.boss;
    if (a) {
      // You pop up beside whoever was tapped, and their talk box opens.
      poof(B.x, B.y);
      const q = clampPt(a.x + (a.x > F.S.W - 30 ? -13 : 13), a.y + 2), to = freePt(q.x, q.y);
      B.x = to.x; B.y = to.y; B.path = [];
      poof(B.x, B.y);
      F.hook.pushEvent("floor_talk", { key: a.key });
      return;
    }
    if (Math.abs(p.x - F.cat.x) < 7 && Math.abs(p.y - 3 - F.cat.y) < 7) {
      word("meow", F.cat.x, F.cat.y - 12, "#b86e1f", 11, 1.2); word("♥", F.cat.x + 6, F.cat.y - 16, "#e0352b", 12, 1.4);
      if (F.cat.state === "sleep") { F.cat.state = "sit"; F.cat.wait = 2; }
      return;
    }
    // A tap on a table sends you to the nearest floor beside it.
    const q = clampPt(p.x, p.y + 4), to = freePt(q.x, q.y);
    B.path = pathTo(B.x, B.y, to.x, to.y);
  };

  const onKey = (down) => (e) => {
    const k = (e.key || "").toLowerCase();
    if ("wasd".indexOf(k) < 0 || k.length !== 1 || e.metaKey || e.ctrlKey || e.altKey) return;
    if (down && !showing()) return;
    F.keys[k] = down;
  };

  let keyDown = null, keyUp = null, sizer = null;

  window.WallboardHooks = window.WallboardHooks || {};
  window.WallboardHooks.Floor = {
    mounted() {
      F.hook = this;
      F.stage = this.el.querySelector("#floor-stage");
      F.tz = this.el.dataset.tz || "America/New_York";
      F.fontFamily = getComputedStyle(document.body).fontFamily;
      F.canvas = document.createElement("canvas");
      F.canvas.setAttribute("role", "img");
      F.canvas.setAttribute("aria-label", "The floor: your sessions as people in an office. The list below says the same.");
      F.bg = document.createElement("canvas");
      if (!F.canvas.getContext || !F.canvas.getContext("2d")) return;
      F.stage.appendChild(F.canvas);
      this.el.classList.add("drawn");
      F.actors.clear(); F.S = null; F.firstCast = true; F.parts = []; F.last = 0;
      F.canvas.addEventListener("click", onTap);
      F.canvas.addEventListener("mousemove", (e) => { if (F.S) F.canvas.style.cursor = actorAt(toArt(e)) ? "pointer" : "default"; });
      keyDown = onKey(true); keyUp = onKey(false);
      document.addEventListener("keydown", keyDown); document.addEventListener("keyup", keyUp);
      if (window.ResizeObserver) {
        // It reports once as soon as it starts watching; only a real change
        // of size puts everyone back in their places.
        let w = F.stage.clientWidth, h = F.stage.clientHeight;
        sizer = new ResizeObserver(() => {
          const nw = F.stage.clientWidth, nh = F.stage.clientHeight;
          if (nw === w && nh === h) return;
          w = nw; h = nh;
          if (F.S) { resettle(); paint(0); } else this.updated();
        });
        sizer.observe(F.stage);
      }
      this.updated();
      cancelAnimationFrame(F.raf);
      F.raf = requestAnimationFrame(frame);
    },
    updated() {
      let cast = [];
      try { cast = JSON.parse(this.el.dataset.cast || "[]"); } catch (_) {}
      setCast(cast);
      // Drawn at once, so the room is never blank while it waits its turn
      // (a browser holds back the moving picture of a tab it is not showing).
      paint(0);
    },
    // Moves the floor on by `secs` seconds without waiting for the browser's
    // frames, for a screenshot or a test of a tab the browser is not painting.
    advance(secs) {
      for (let i = 0; i < secs * 30; i++) { F.t += 1 / 30; paint(1 / 30); }
    },
    destroyed() {
      cancelAnimationFrame(F.raf);
      if (sizer) sizer.disconnect();
      if (keyDown) { document.removeEventListener("keydown", keyDown); document.removeEventListener("keyup", keyUp); }
    },
  };
})();
