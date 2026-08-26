import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
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

  /// Status color from the theme's [StatusColors] tokens — correct in both
  /// light and dark mode (never raw Material-500 constants).
  Color colorOf(BuildContext context) {
    final tokens = Theme.of(context).extension<StatusColors>() ??
        StatusColors.light;
    switch (this) {
      case VpnStatus.disconnected:
        return tokens.idle;
      case VpnStatus.connecting:
      case VpnStatus.disconnecting:
        return tokens.connecting;
      case VpnStatus.connected:
        return tokens.connected;
      case VpnStatus.error:
        return tokens.error;
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
