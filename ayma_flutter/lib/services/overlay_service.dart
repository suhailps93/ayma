// Android floating overlay window for voice chat while using other apps.
import 'package:flutter/foundation.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

class OverlayService {
  OverlayService._();

  static Future<bool> isGranted() async {
    try {
      return await FlutterOverlayWindow.isPermissionGranted();
    } catch (e) {
      debugPrint('[OverlayService] isPermissionGranted error: $e');
      return false;
    }
  }

  static Future<bool> requestPermission() async {
    try {
      if (!await isGranted()) {
        await FlutterOverlayWindow.requestPermission();
      }
      return isGranted();
    } catch (e) {
      debugPrint('[OverlayService] requestPermission error: $e');
      return false;
    }
  }

  static Future<bool> showOverlay() async {
    try {
      if (!await isGranted()) {
        debugPrint('[OverlayService] showOverlay skipped — permission not granted');
        return false;
      }
      if (await FlutterOverlayWindow.isActive()) {
        debugPrint('[OverlayService] overlay already active');
        return true;
      }
      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: 'Ayma Agent',
        overlayContent: 'Agent is active',
        flag: OverlayFlag.defaultFlag,
        visibility: NotificationVisibility.visibilityPublic,
        positionGravity: PositionGravity.auto,
        height: 90,
        width: 90,
      );
      debugPrint('[OverlayService] overlay shown');
      return true;
    } catch (e) {
      debugPrint('[OverlayService] showOverlay error: $e');
      return false;
    }
  }

  static Future<void> hideOverlay() async {
    try {
      if (await FlutterOverlayWindow.isActive()) {
        await FlutterOverlayWindow.closeOverlay();
        debugPrint('[OverlayService] overlay hidden');
      }
    } catch (e) {
      debugPrint('[OverlayService] hideOverlay error: $e');
    }
  }
}
