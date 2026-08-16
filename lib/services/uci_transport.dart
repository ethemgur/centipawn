// Picks the platform's engine transport at compile time.
//
// This is the *only* conditional import in the engine layer now. The UCI
// protocol itself lives in `uci_engine.dart` and is shared, so a new platform
// costs one transport and no protocol code.
export 'uci_transport_native.dart'
    if (dart.library.js_interop) 'uci_transport_web.dart';
