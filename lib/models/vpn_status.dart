import 'package:flutter/material.dart';
import '../utils/localization_helper.dart';

/// VPN connection status
enum VpnStatus {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

extension VpnStatusExtension on VpnStatus {
  /// Get display text
  String get displayText {
    switch (this) {
      case VpnStatus.disconnected:
        return L10n.tr.vpnStatusDisconnected;
      case VpnStatus.connecting:
        return L10n.tr.vpnStatusConnecting;
      case VpnStatus.connected:
        return L10n.tr.vpnStatusConnected;
      case VpnStatus.disconnecting:
        return L10n.tr.vpnStatusDisconnecting;
      case VpnStatus.error:
        return L10n.tr.vpnStatusError;
    }
  }

  /// Get status color
  Color get color {
    switch (this) {
      case VpnStatus.disconnected:
        return Colors.grey;
      case VpnStatus.connecting:
        return Colors.orange;
      case VpnStatus.connected:
        return Colors.green;
      case VpnStatus.disconnecting:
        return Colors.orange;
      case VpnStatus.error:
        return Colors.red;
    }
  }

  /// Get status icon
  IconData get icon {
    switch (this) {
      case VpnStatus.disconnected:
        return Icons.vpn_lock_outlined;
      case VpnStatus.connecting:
        return Icons.sync;
      case VpnStatus.connected:
        return Icons.vpn_lock;
      case VpnStatus.disconnecting:
        return Icons.sync;
      case VpnStatus.error:
        return Icons.error_outline;
    }
  }

  /// Check if VPN is active (connecting or connected)
  bool get isActive {
    return this == VpnStatus.connecting ||
        this == VpnStatus.connected ||
        this == VpnStatus.disconnecting;
  }
}
