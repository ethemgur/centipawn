/// Facts about the Stockfish artifacts committed under `web/`.
///
/// Deliberately free of any import so both the web transport (compiled for the
/// browser) and a VM test can read them — `package:web` does not compile on the
/// Dart VM, so the transport itself cannot be the source of truth here.
///
/// The files are plain assets copied verbatim by `flutter build web`, the same
/// route `web/sqlite3.wasm` already takes. `test/engine/web_assets_test.dart`
/// asserts they exist and match, because nothing else notices if they go
/// missing: the hosting SPA rewrite would answer with `index.html` at HTTP 200
/// and the engine would fail confusingly in production.
library;

/// Emscripten glue, loaded as a **classic** Web Worker.
///
/// Must not be loaded as a module worker — it calls `importScripts`, which
/// does not exist in `type: 'module'` workers.
const String kStockfishScriptName = 'stockfish-18-lite-single.js';

/// The engine itself: Stockfish 18, lite net, single-threaded.
///
/// Single-threaded is the whole reason this integration is simple — the
/// multi-threaded build needs `SharedArrayBuffer`, which needs cross-origin
/// isolation, which would break CanvasKit loading from gstatic and sever
/// popup OAuth via `COOP: same-origin`.
const String kStockfishWasmName = 'stockfish-18-lite-single.wasm';

/// Exact sizes of the v18.0.0 release artifacts, asserted by the asset test.
const int kStockfishScriptBytes = 20670;
const int kStockfishWasmBytes = 7295411;

/// First four bytes of any WebAssembly module: `\0asm`.
///
/// Checked before the worker is spawned, so a missing file reports itself
/// instead of failing as an unhandled rejection inside the worker.
const List<int> kWasmMagic = [0x00, 0x61, 0x73, 0x6d];
