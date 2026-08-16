import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

/// `sqflite` has no browser implementation of its own; on web it needs an
/// sqlite3-wasm-backed factory. Uses the no-web-worker variant (sqlite3 runs
/// directly on the main thread instead of round-tripping through a
/// SharedWorker) — simpler and more reliable for this app's modest data
/// size, and avoids the SharedWorker messaging path.
void setUpDatabaseFactory() {
  databaseFactory = databaseFactoryFfiWebNoWebWorker;
}
