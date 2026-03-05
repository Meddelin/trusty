import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/vpn_status.dart';
import '../services/vpn_service.dart';
import '../services/config_service.dart';
import '../l10n/app_localizations.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Selector<VpnService, (VpnStatus, String?)>(
      selector: (_, vpn) => (vpn.status, vpn.errorMessage),
      builder: (context, record, child) {
        final vpnService = context.read<VpnService>();
        final status = record.$1;

        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Status Icon
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 160,
                  height: 160,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: status.color.withOpacity(0.1),
                    border: Border.all(
                      color: status.color,
                      width: 4,
                    ),
                  ),
                  child: Icon(
                    status.icon,
                    size: 80,
                    color: status.color,
                  ),
                ),

                const SizedBox(height: 32),

                // Status Text
                Text(
                  status.displayText,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        color: status.color,
                        fontWeight: FontWeight.bold,
                      ),
                ),

                const SizedBox(height: 48),

                // Connect/Disconnect Button
                _buildMainButton(context, vpnService, status),

                const SizedBox(height: 24),

                // Error Message
                if (status == VpnStatus.error && vpnService.errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.red),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error_outline, color: Colors.red),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            vpnService.errorMessage!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Info Card
                if (status == VpnStatus.disconnected) ...[
                  const SizedBox(height: 24),
                  _buildInfoCard(context),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMainButton(
    BuildContext context,
    VpnService vpnService,
    VpnStatus status,
  ) {
    final isLoading = status == VpnStatus.connecting ||
        status == VpnStatus.disconnecting;

    return SizedBox(
      width: 280,
      height: 64,
      child: ElevatedButton(
        onPressed: isLoading
            ? null
            : () => _handleButtonPress(context, vpnService, status),
        style: ElevatedButton.styleFrom(
          backgroundColor:
              status == VpnStatus.connected ? Colors.red : Colors.green,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(32),
          ),
          elevation: 4,
        ),
        child: isLoading
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                  SizedBox(width: 12),
                  Text(
                    AppLocalizations.of(context)!.homePleaseWait,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    status == VpnStatus.connected
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                    size: 28,
                  ),
                  SizedBox(width: 12),
                  Text(
                    status == VpnStatus.connected
                        ? AppLocalizations.of(context)!.homeDisconnect
                        : AppLocalizations.of(context)!.homeConnect,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
              SizedBox(width: 12),
              Text(
                AppLocalizations.of(context)!.homeInfoTitle,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
          SizedBox(height: 12),
          Text(
            '• ${AppLocalizations.of(context)!.homeInfoLine1}\n'
            '• ${Platform.isWindows ? AppLocalizations.of(context)!.homeInfoLineClientWindows : AppLocalizations.of(context)!.homeInfoLineClientOther}\n'
            '• ${AppLocalizations.of(context)!.homeInfoLine3}',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleButtonPress(
    BuildContext context,
    VpnService vpnService,
    VpnStatus status,
  ) async {
    try {
      if (status == VpnStatus.connected) {
        await vpnService.disconnect();
      } else {
        // Load config and connect
        final configService = context.read<ConfigService>();
        final config = await configService.loadConfig();

        // Debug: verify config was loaded
        print('HomeScreen - loaded config: hostname=${config.hostname}, address=${config.address}');

        await vpnService.connect(config);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.homeError(e.toString())),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }
}
