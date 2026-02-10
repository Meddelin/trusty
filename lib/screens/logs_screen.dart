import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/vpn_service.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;
  VpnService? _vpnService;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final vpn = context.read<VpnService>();
    if (_vpnService != vpn) {
      _vpnService?.removeLogObserver(_onNewLog);
      _vpnService = vpn;
      _vpnService!.addLogObserver(_onNewLog);
    }
  }

  void _onNewLog(String _) {
    _scrollToBottom();
  }

  @override
  void dispose() {
    _vpnService?.removeLogObserver(_onNewLog);
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_autoScroll && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(
            _scrollController.position.maxScrollExtent,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<VpnService>(
      builder: (context, vpnService, child) {
        return Column(
          children: [
            // Header with controls
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: Border(
                  bottom: BorderSide(
                    color: Theme.of(context).dividerColor,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.terminal,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Connection Logs',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const Spacer(),
                  // Auto-scroll toggle
                  IconButton(
                    icon: Icon(
                      _autoScroll ? Icons.arrow_downward : Icons.arrow_downward_outlined,
                      color: _autoScroll ? Theme.of(context).colorScheme.primary : null,
                    ),
                    tooltip: _autoScroll
                        ? 'Auto-scroll enabled'
                        : 'Auto-scroll disabled',
                    onPressed: () {
                      setState(() {
                        _autoScroll = !_autoScroll;
                      });
                    },
                  ),
                  // Copy logs
                  IconButton(
                    icon: const Icon(Icons.copy),
                    tooltip: 'Copy logs',
                    onPressed: vpnService.logs.isEmpty
                        ? null
                        : () => _copyLogs(vpnService.logs),
                  ),
                  // Clear logs
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Clear logs',
                    onPressed: vpnService.logs.isEmpty
                        ? null
                        : () => _confirmClearLogs(vpnService),
                  ),
                ],
              ),
            ),

            // Logs content
            Expanded(
              child: vpnService.logs.isEmpty
                  ? _buildEmptyState()
                  : _buildLogsList(vpnService.logs),
            ),

            // Footer with info
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context).dividerColor,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Total entries: ${vpnService.logs.length}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.article_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'Logs are empty',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Connect to VPN to see logs',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogsList(List<String> logs) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(16),
        itemCount: logs.length,
        itemBuilder: (context, index) {
          final log = logs[index];
          return _buildLogEntry(log, index);
        },
      ),
    );
  }

  Widget _buildLogEntry(String log, int index) {
    // Determine log type by emoji/icon
    Color? textColor;
    IconData? icon;

    if (log.contains('✅')) {
      textColor = Colors.green;
      icon = Icons.check_circle_outline;
    } else if (log.contains('❌')) {
      textColor = Colors.red;
      icon = Icons.error_outline;
    } else if (log.contains('⚠️')) {
      textColor = Colors.orange;
      icon = Icons.warning_amber;
    } else if (log.contains('🔄')) {
      textColor = Colors.blue;
      icon = Icons.sync;
    } else if (log.contains('🚀')) {
      textColor = Colors.purple;
      icon = Icons.rocket_launch;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: textColor),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: SelectableText(
              log,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _copyLogs(List<String> logs) {
    final text = logs.join('\n');
    Clipboard.setData(ClipboardData(text: text));

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Logs copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _confirmClearLogs(VpnService vpnService) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear logs?'),
        content: const Text(
          'All log entries will be deleted. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              vpnService.clearLogs();
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Logs cleared'),
                ),
              );
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}
