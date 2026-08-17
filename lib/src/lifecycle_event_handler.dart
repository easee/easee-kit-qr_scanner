import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

class LifecycleEventHandler extends WidgetsBindingObserver {
  LifecycleEventHandler({required this.resumeCallBack});

  late final AsyncCallback resumeCallBack;

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    switch (state) {
      case .resumed:
        await resumeCallBack();
        break;
      case .inactive:
      case .paused:
      case .detached:
      case .hidden:
    }
  }
}
