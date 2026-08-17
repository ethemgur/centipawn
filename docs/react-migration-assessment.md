# Should Centipawn move to React?

Written as a decision aid, not a plan. **Recommendation: no — stay on Flutter.**
The reasoning, and the conditions that would change it, are below.

This was prompted by a real pain point: the web build had no chess engine. That
is now fixed (`docs/architecture.md`, Engine layer), which removes the strongest
practical argument for a rewrite.

## The honest case *for* React/TypeScript

These are real, not strawmen.

**1. The chess ecosystem is natively TypeScript, and this app uses ports.**
`packages/dartchess` is a Dart port of [chessops]; `chessground` is a Dart port
of Lichess's TypeScript board. In React you would use the upstream libraries
instead of ports that lag them. The repo already carries the cost of that
distance: `packages/dartchess` is a **vendored, patched copy** because
`_popcnt64()` used 64-bit literals dart2js/dart2wasm cannot represent, and that
override has to survive every dependency bump.

**2. Web bundle and first paint.** The deployed build is heavy. `main.dart.wasm`
is 3.1 MB and the renderer pulls ~3.5 MB of `skwasm.wasm` before any app code
runs; `build/web` is ~67 MB on disk, of which the service worker precaches a
great deal. A React SPA doing the same job would plausibly ship a few hundred KB
of JS. Flutter web also renders to canvas, which costs real accessibility and
SEO — screen readers get a synthesised semantics tree, and there is no
server-rendered HTML.

**3. Engine integration is first-class in JS.** What took a `UciTransport`, a
`dart:js_interop` bridge and a magic-byte guard here is `new Worker(...)` there.

**4. Web is where you actually test.** Every push to `main` deploys the web
build, and the bugs you have reported have all been web bugs.

## The case *against*, which I find decisive

**1. It is a web-only answer to a multi-platform app.** The app targets Android,
iOS, web, Windows, macOS and Linux. `widgets/responsive_layout.dart` reads
`MediaQuery.displayFeatures` and handles Z Fold book/flex postures — that is not
incidental, someone cared about foldables. React means React-DOM, which is web
only. React Native shares *concepts* with React-DOM, not components: you would
write the UI twice. Capacitor/Tauri wrap the web app, but then mobile loses
native Stockfish and inherits WASM speed.

**2. It would make analysis slower where it currently works best.** Android/iOS
run Stockfish via FFI with 3 threads and a 256 MB hash. The web build runs a
single-threaded WASM engine with 32 MB — roughly an order of magnitude slower,
which is exactly why web searches at depth 12/16 instead of 15/28. Going
web-tech everywhere means taking that penalty on the platforms that don't
currently pay it.

**3. The differentiator is done, tested, and would have to be rewritten.**
`lib/services/critical_moments/` is ~2,000 lines with 144 passing tests, and the
subtle parts — static exchange evaluation with x-ray rescan, the zero-out/damp
gate ordering, horizon-shift redistribution, an OLS time regression — are
precisely the code where a reimplementation reintroduces bugs. It is also
*unvalidated against hand labels yet*. Rewriting it before it has been tuned
means throwing away the thing you would tune, for no user-visible gain.

**4. Everything else re-plumbs too.** Riverpod → some React state library;
`sqflite` + the schema-v5 migration path → IndexedDB/SQLite-wasm; the PGN
parser; Firebase auth wiring; the whole screen layer. Realistically this is
weeks of work whose best possible outcome is *the app you already have*.

**5. The engine gap — the concrete thing that hurt — is now closed.** Web has a
real Stockfish. The remaining gap is desktop (Windows/macOS/Linux have no engine
because the `stockfish` pub package ships plugin code for Android/iOS only), and
the `UciTransport` seam makes that one new transport of ~70 lines, not a
rewrite.

## What I would do instead

Cheaper moves that address the same complaints:

- **Trim the web payload.** (`web/sqflite_sw.js`, 800 KB and never loaded, is
  already gone.) The four `canvaskit/*.js.symbols` files are ~5.8 MB of debug
  symbol maps. The service
  worker precaches ~27 MB of CanvasKit variants a given client never fetches;
  `--pwa-strategy=none` or `--no-web-resources-cdn` are levers worth measuring.
- **Add a desktop transport** so the engine works on all six targets.
- **Finish the critical-moments validation loop** (30 labelled games, tune the
  weights). That is the work that makes this app worth using, and it is
  framework-independent.

## What would change my mind

Not "React is nicer" — these, specifically:

1. **You decide web is the only target that matters.** If Android/iOS/desktop
   are dropped, argument 1 evaporates and the bundle-size case gets much
   stronger.
2. **First paint or bundle size becomes a real user complaint** and the trimming
   above doesn't move it enough.
3. **You need SEO or shareable server-rendered pages** — public game analysis
   links, say. Flutter web is genuinely poor at this and no amount of tuning
   fixes it.
4. **The vendored-dartchess tax keeps growing** — more patches, more divergence
   from chessops.

If two or more of those become true, revisit. The migration would be a
deliberate rewrite with a working reference implementation to test against,
which is the good version of that project — not a refactor to be snuck in
alongside a feature.
