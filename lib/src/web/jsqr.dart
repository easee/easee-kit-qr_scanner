@JS()
library;

import 'dart:js_interop';

@JS('jsQR')
external Code? jsQR(JSUint8ClampedArray data, int width, int height);

extension type Code._(JSObject _) implements JSObject {
  external String get data;
}
