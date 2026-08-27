import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/config_service.dart';
import '../services/vpn_service.dart';
import '../theme/app_theme.dart';
import '../utils/app_snackbar.dart';
import '../utils/log_level.dart';
import '../l10n/app_localizations.dart';

/// One console line, parsed exactly once and then cached: pulling the
/// timestamp off the front is a regex match and `logLevelOf` is half a dozen
/// substring searches, and the buffer holds 500 lines that are re-rendered
/// ten times a second while the client is talking.
@immutable
class _LogLine {
  final String timestamp;
  final String message;
  final LogLevel level;

  const _LogLine(this.timestamp, this.message, this.level);
}

/// What the filter counts, the footer counters and the copy/clear enabled
/// state all read. A record, so `ValueNotifier` dedupes structurally and a
/// notification that leaves the numbers unchanged rebuilds nothing.
typedef _LogStats = ({int total, int errors, int warnings});

/// The Logs screen as two islands: a control island (title, auto-scroll, copy,
/// clear, the level filters and the client's own verbosity) and a console
/// island that takes the rest of the window, with the entry counters pinned
/// inside its bottom edge behind a hairline.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  final ScrollController _scrollController = ScrollController();
  bool _autoScroll = true;
  VpnService? _vpnService;

  /// null = show everything.
  LogLevel? _filter;

  /// App-wide client log verbosity (moved here from the old Settings tab —
  /// it governs the very lines this screen shows). Kept in sync with the
  /// config so a change made elsewhere lands here too.
  late ConfigService _configService;
  String _logLevel = 'info';

  /// The five levels the client understands, in increasing verbosity. Const
  /// items: the dropdown would otherwise build five `DropdownMenuItem`s and
  /// five `Text`s on every rebuild of the filter row.
  static const List<DropdownMenuItem<String>> _logLevelItems = [
    DropdownMenuItem(value: 'error', child: Text('error')),
    DropdownMenuItem(value: 'warn', child: Text('warn')),
    DropdownMenuItem(value: 'info', child: Text('info')),
    DropdownMenuItem(value: 'debug', child: Text('debug')),
    DropdownMenuItem(value: 'trace', child: Text('trace')),
  ];

  /// `VpnService._addLog` stamps every entry as `[HH:MM:SS] message`. The
  /// console shows the stamp in its own dim column, so pull it off the front.
  static final RegExp _timestampPattern = RegExp(
    r'^\[(\d{2}:\d{2}:\d{2})\]\s*',
  );

  /// `kMonoFontStack.sublist(1)` allocated a fresh list on every `_mono` call,
  /// and `_mono` runs three times per console row. Once, here, instead.
  static final List<String> _monoFallback = kMonoFontStack.sublist(1);

  static const List<String> _levelTokens = ['ERROR', 'WARN', 'INFO', 'DEBUG'];

  // ------------------------------------------------------- derived log state
  //
  // Everything below is recomputed when the service's buffer actually changes,
  // never inside `build`. `VpnService` notifies at ~10fps while logging and
  // also on every status change; the old build pass walked the 500-line buffer
  // three times (two `where().length` counts plus the filter) and re-parsed
  // every visible row, all of it repeated for notifications that had nothing
  // to do with the logs.

  /// The exact list instance last folded into `_entries`, for the change test.
  List<String> _sourceLogs = const [];
  List<_LogLine> _entries = const [];

  /// Parse cache keyed by the raw line. The Dart VM memoises `String.hashCode`
  /// on the object, so a re-fold of the buffer is 500 hash lookups instead of
  /// 500 regex matches plus 500 level classifications.
  final Map<String, _LogLine> _parsed = <String, _LogLine>{};

  /// The console list. Only the console subtree listens.
  final ValueNotifier<List<_LogLine>> _visible =
      ValueNotifier<List<_LogLine>>(const []);

  /// The counts. Only the filter chips, the footer counters and the
  /// copy/clear pair listen.
  final ValueNotifier<_LogStats> _stats =
      ValueNotifier<_LogStats>((total: 0, errors: 0, warnings: 0));

  /// One coalesced auto-scroll per frame. `_addLog` calls its observers per
  /// line and does not throttle them, so a burst used to queue a post-frame
  /// `jumpTo` for every single line.
  bool _scrollPending = false;

  /// How many further post-frame jumps the current pin may still take. A lazy
  /// `ListView.builder` only measures the rows it has laid out, so the first
  /// jump lands on an *estimate* of the bottom; landing there reveals the last
  /// row and grows the extent. Bounded so a viewport that never settles cannot
  /// spin the scheduler.
  int _pinBudget = 0;

  // ------------------------------------------------------------ cached style
  //
  // Recomputed in `didChangeDependencies`, i.e. when the theme or the locale
  // actually changes — not per row, per rebuild.

  late ColorScheme _scheme;
  late Color _dimColor;
  late BoxDecoration _islandDecoration;
  late TextStyle _sectionLabelStyle;
  late ButtonStyle _actionStyle;
  late ButtonStyle _actionStyleOn;
  late ButtonStyle _chipStyle;
  late ButtonStyle _chipStyleOn;
  late TextStyle _stampStyle;
  late List<TextStyle> _tokenStyles;
  late List<TextStyle> _messageStyles;
  late TextStyle _counterBodyStyle;
  late TextStyle _counterValueStyle;
  late Color _statusError;
  late TextStyle _counterErrorStyle;
  late TextStyle _counterErrorLabelStyle;
  late TextStyle _dropdownStyle;

  @override
  void initState() {
    super.initState();
    _configService = context.read<ConfigService>();
    _configService.addListener(_reloadLogLevel);
    _reloadLogLevel();
  }

  Future<void> _reloadLogLevel() async {
    final config = await _configService.loadConfig();
    if (!mounted) return;
    setState(() => _logLevel = config.logLevel);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cacheStyles();

    final vpn = context.read<VpnService>();
    if (_vpnService != vpn) {
      _vpnService?.removeLogObserver(_onNewLog);
      _vpnService?.removeListener(_syncFromService);
      _vpnService = vpn;
      _vpnService!.addLogObserver(_onNewLog);
      // The screen listens to the service directly instead of wrapping itself
      // in a `Consumer`: the fold below decides whether anything visible
      // changed, and only the two notifiers rebuild when it did.
      _vpnService!.addListener(_syncFromService);
      _syncFromService();
    }
  }

  void _onNewLog(String _) {
    _scrollToBottom();
  }

  @override
  void dispose() {
    _vpnService?.removeLogObserver(_onNewLog);
    _vpnService?.removeListener(_syncFromService);
    _configService.removeListener(_reloadLogLevel);
    _scrollController.dispose();
    _visible.dispose();
    _stats.dispose();
    super.dispose();
  }

  /// Pins the console to the newest line.
  ///
  /// Deliberately *after* the frame that lays the new row out, and deliberately
  /// a jump: the console is a live tail, so the bottom has to be there when the
  /// frame is painted, not a scroll animation later. Two things this has to get
  /// right, both of which it used to get wrong:
  ///
  ///  * the screen can mount with a full buffer (the user opens Logs mid
  ///    connection), when there is no attached position yet and no incoming
  ///    line to react to — so the pin is scheduled from the fold, and the
  ///    `hasClients` test moved into the callback, where the list exists;
  ///  * `maxScrollExtent` is an estimate while rows are still unmeasured, so
  ///    one jump from far up the buffer stops a row short of the true bottom —
  ///    hence the re-check on the following frame.
  void _scrollToBottom() {
    if (!_autoScroll) return;
    _pinBudget = 4;
    _schedulePin();
  }

  void _schedulePin() {
    if (_scrollPending) return;
    _scrollPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollPending = false;
      if (!mounted || !_autoScroll || !_scrollController.hasClients) return;

      final position = _scrollController.position;
      if (position.pixels == position.maxScrollExtent) return;
      _scrollController.jumpTo(position.maxScrollExtent);

      // The jump itself schedules a frame; check once more at the end of it,
      // in case laying out the rows it brought into view moved the bottom.
      if (_pinBudget-- > 0) _schedulePin();
    });
  }

  // ------------------------------------------------------------------- state

  /// Fold the service's buffer into parsed lines and counts. Cheap enough to
  /// call on every notification: the guard below rejects the ones that did not
  /// touch the logs (status changes, the SOCKS address, the connect timer),
  /// and the fold itself is a map lookup per line.
  void _syncFromService() {
    final logs = _vpnService?.logs ?? const <String>[];

    // `_addLog` only ever appends, drops the head at the 500 cap, or replaces
    // the tail with a new string when it collapses a duplicate — so length
    // plus the identity of the first and last element settles it exactly.
    if (logs.length == _sourceLogs.length &&
        (logs.isEmpty ||
            (identical(logs.first, _sourceLogs.first) &&
                identical(logs.last, _sourceLogs.last)))) {
      return;
    }
    _sourceLogs = logs;

    // The cache follows a 500-line ring buffer; drop it once it has collected
    // a few generations of retired lines.
    if (_parsed.length > 1500) _parsed.clear();

    final entries = List<_LogLine>.filled(logs.length, _emptyLine);
    var errors = 0;
    var warnings = 0;
    for (var i = 0; i < logs.length; i++) {
      final raw = logs[i];
      var line = _parsed[raw];
      if (line == null) {
        line = _parse(raw);
        _parsed[raw] = line;
      }
      if (line.level == LogLevel.error) {
        errors++;
      } else if (line.level == LogLevel.warning) {
        warnings++;
      }
      entries[i] = line;
    }

    _entries = entries;
    _applyFilter();
    _stats.value = (total: logs.length, errors: errors, warnings: warnings);

    // Also pin from here, not only from the per-line observer: the very first
    // fold happens in `didChangeDependencies`, before the console has ever been
    // laid out, and no observer fires for lines that were already in the buffer
    // when the screen mounted.
    _scrollToBottom();
  }

  static const _LogLine _emptyLine = _LogLine('', '', LogLevel.info);

  static _LogLine _parse(String raw) {
    final match = _timestampPattern.firstMatch(raw);

    return _LogLine(
      match?.group(1) ?? '',
      // The level has its own column, so the token that carries it is not
      // repeated at the head of the message. The stored line keeps it.
      withoutLevelToken(match == null ? raw : raw.substring(match.end)),
      logLevelOf(raw),
    );
  }

  void _applyFilter() {
    final filter = _filter;
    _visible.value = filter == null
        ? _entries
        : <_LogLine>[
            for (final entry in _entries)
              if (entry.level == filter) entry,
          ];
  }

  // ---------------------------------------------------------------- styling

  /// Data — timestamps, level tokens, counts, log text — is monospaced.
  static TextStyle _mono({
    required double size,
    Color? color,
    FontWeight? weight,
    double? height,
    double? letterSpacing,
  }) {
    return TextStyle(
      fontFamily: kMonoFontStack.first,
      fontFamilyFallback: _monoFallback,
      fontSize: size,
      color: color,
      fontWeight: weight,
      height: height,
      letterSpacing: letterSpacing,
    );
  }

  void _cacheStyles() {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final status = theme.extension<StatusColors>()!;

    // The kit's `dim` step (section labels, timestamps, placeholders). It is
    // the theme's third text tone, not a faded `onSurfaceVariant`: fading it
    // to 72% put the mono labels and the timestamp column at ~3.5:1 on the
    // island surfaces, under the WCAG AA floor. `dimTextOf` follows the
    // brightness and clears the floor on every surface in the palette.
    final dim = dimTextOf(scheme);

    _scheme = scheme;
    _dimColor = dim;

    _islandDecoration = BoxDecoration(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: scheme.outlineVariant),
    );

    // Sans, sentence case, no tracking: a section heading is prose, not data.
    // Mono is kept for the values below it — stamps, level tokens, counts.
    _sectionLabelStyle = TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: scheme.onSurfaceVariant,
    );

    // 34px outlined action. Height, radius, outline, foreground and text style
    // all come from `outlinedButtonTheme` — the only local intent is the
    // artboard's tighter 14px padding, the shrink-wrapped tap target (the
    // Material default would inflate the row to 48px) and, for auto-scroll,
    // the primary tint that marks its on-state without inventing a second
    // kind of button.
    const actionPadding = EdgeInsets.symmetric(horizontal: 14);
    _actionStyle = OutlinedButton.styleFrom(
      padding: actionPadding,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    _actionStyleOn = OutlinedButton.styleFrom(
      padding: actionPadding,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      side: BorderSide(color: scheme.primary.withValues(alpha: 0.30)),
      backgroundColor: scheme.primary.withValues(alpha: 0.10),
      foregroundColor: scheme.primary,
    );

    // Filter pills: deliberately shorter (28px) and rounder (10px) than the
    // themed action height, which is what the artboard draws — so this
    // styleFrom is local intent, not a restatement of the theme.
    const chipPadding = EdgeInsets.symmetric(horizontal: 14);
    const chipSize = Size(0, 28);
    _chipStyle = OutlinedButton.styleFrom(
      minimumSize: chipSize,
      padding: chipPadding,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
      foregroundColor: scheme.onSurfaceVariant,
      textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w400),
    );
    _chipStyleOn = OutlinedButton.styleFrom(
      minimumSize: chipSize,
      padding: chipPadding,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
      ),
      side: BorderSide(color: scheme.primary.withValues(alpha: 0.30)),
      backgroundColor: scheme.primary.withValues(alpha: 0.14),
      foregroundColor: scheme.primary,
      textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
    );

    // Console line styles, one set for the whole list instead of three
    // `TextStyle`s per row per frame.
    final lineStyle = _mono(size: 11.5, height: 1.75);
    _stampStyle = lineStyle.copyWith(color: dim);

    final errorStyle = lineStyle.copyWith(color: status.error);
    final warnStyle = lineStyle.copyWith(color: status.connecting);
    final dimStyle = lineStyle.copyWith(color: dim);
    final bodyStyle = lineStyle.copyWith(color: scheme.onSurfaceVariant);

    // Indexed by `LogLevel.index`: error, warning, info, debug.
    _tokenStyles = [errorStyle, warnStyle, dimStyle, dimStyle];
    _messageStyles = [errorStyle, warnStyle, bodyStyle, dimStyle];

    _counterBodyStyle = TextStyle(
      fontSize: 12.5,
      color: scheme.onSurfaceVariant,
    );
    _counterValueStyle = _mono(size: 12.5, color: scheme.onSurface);
    _statusError = status.error;
    _counterErrorStyle = _mono(size: 12.5, color: status.error);
    _counterErrorLabelStyle = TextStyle(fontSize: 12.5, color: status.error);

    _dropdownStyle = _mono(size: 12.5, color: scheme.onSurface);
  }

  /// The sentence-case sans heading every island carries.
  Widget _sectionLabel(String text) => Text(text, style: _sectionLabelStyle);

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    // No `Consumer` here any more: a log burst reaches the two notifiers, so
    // the island chrome, the section labels, the title, the auto-scroll button
    // and the verbosity dropdown are built once and left alone. This method
    // only re-runs for the things the user actually changed — the filter, the
    // auto-scroll flag, the client log level, the theme.
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ISLAND 1 — controls.
          Container(
            decoration: _islandDecoration,
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeaderRow(),
                const SizedBox(height: 14),
                const Divider(),
                const SizedBox(height: 14),
                _buildFilterRow(),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // ISLAND 2 — the console.
          Expanded(
            child: Container(
              decoration: _islandDecoration,
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                    child: _sectionLabel('Console'),
                  ),
                  Expanded(
                    child: ValueListenableBuilder<List<_LogLine>>(
                      valueListenable: _visible,
                      builder: (context, visible, _) => _entries.isEmpty
                          ? _buildEmptyState()
                          : _buildLogsList(visible),
                    ),
                  ),
                  ValueListenableBuilder<_LogStats>(
                    valueListenable: _stats,
                    builder: (context, stats, _) =>
                        _buildCounters(stats.total, stats.errors),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Header chrome: the terminal glyph, the title and the three actions. Copy
  // and clear depend on whether there are any lines at all, so they sit behind
  // the stats notifier rather than rebuilding the island.
  Widget _buildHeaderRow() {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return SizedBox(
      height: 34,
      child: Row(
        children: [
          Icon(Icons.terminal, size: 20, color: _scheme.primary),
          const SizedBox(width: 12),
          // Expanded, not Flexible + Spacer: two loose flex children would
          // split the free space and leave the actions floating short of the
          // right edge.
          Expanded(
            child: Text(
              l10n.logsTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // Auto-scroll: the label is the state, pressing it flips it.
          OutlinedButton.icon(
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
            icon: Icon(
              _autoScroll
                  ? Icons.arrow_downward
                  : Icons.arrow_downward_outlined,
              size: 18,
            ),
            label: Text(
              _autoScroll
                  ? l10n.logsAutoScrollEnabled
                  : l10n.logsAutoScrollDisabled,
            ),
            style: _autoScroll ? _actionStyleOn : _actionStyle,
          ),
          const SizedBox(width: 10),
          ValueListenableBuilder<_LogStats>(
            valueListenable: _stats,
            builder: (context, stats, _) {
              final hasLogs = stats.total > 0;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: hasLogs ? _copyLogs : null,
                    icon: const Icon(Icons.copy, size: 18),
                    label: Text(l10n.logsCopy),
                    style: _actionStyle,
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: hasLogs ? _confirmClearLogs : null,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text(l10n.logsClear),
                    style: _actionStyle,
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// Filter · the three level pills · the client's own verbosity.
  Widget _buildFilterRow() {
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          _sectionLabel('Filter'),
          const SizedBox(width: 14),
          // Only the pills carry live counts, so only the pills listen.
          ValueListenableBuilder<_LogStats>(
            valueListenable: _stats,
            builder: (context, stats, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _filterChip('All', null),
                const SizedBox(width: 8),
                _filterChip('Errors (${stats.errors})', LogLevel.error),
                const SizedBox(width: 8),
                _filterChip('Warnings (${stats.warnings})', LogLevel.warning),
              ],
            ),
          ),
          const Spacer(),
          // The verbosity of the client itself sits beside the filters: one
          // reads the lines that exist, the other decides which get written.
          // A 20px rule, not a full-height `VerticalDivider`, per the artboard.
          SizedBox(
            width: 1,
            height: 20,
            child: ColoredBox(color: _scheme.outline),
          ),
          const SizedBox(width: 12),
          _buildLogLevelControl(),
        ],
      ),
    );
  }

  Widget _filterChip(String label, LogLevel? value) {
    final selected = _filter == value;
    return OutlinedButton(
      onPressed: () => setState(() {
        _filter = value;
        _applyFilter();
      }),
      style: selected ? _chipStyleOn : _chipStyle,
      child: Text(label),
    );
  }

  /// App-wide log level. The "applies on your next connect" note lives behind
  /// the info glyph rather than as standing helper prose.
  Widget _buildLogLevelControl() {
    final l10n = AppLocalizations.of(context)!;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.settingsLogLevel,
          style: TextStyle(fontSize: 11, color: _scheme.onSurfaceVariant),
        ),
        const SizedBox(width: 6),
        Tooltip(
          message: l10n.settingsLogLevelHelper,
          child: Icon(Icons.info_outline, size: 15, color: _dimColor),
        ),
        const SizedBox(width: 12),
        Container(
          height: 34,
          // A fixed width, not a minimum: this row is a non-flex child of the
          // filter Row, so it is laid out with an unbounded width constraint,
          // and `isExpanded: true` below would then assert ("non-zero flex but
          // incoming width constraints are unbounded") and fail the screen.
          width: 116,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: _scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _scheme.outlineVariant),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _logLevel,
              isDense: true,
              isExpanded: true,
              borderRadius: BorderRadius.circular(12),
              dropdownColor: _scheme.surfaceContainerHigh,
              icon: Icon(
                Icons.expand_more,
                size: 16,
                color: _scheme.onSurfaceVariant,
              ),
              style: _dropdownStyle,
              items: _logLevelItems,
              onChanged: (value) async {
                final v = value ?? 'info';
                setState(() => _logLevel = v);
                await _configService.setGlobalLogLevel(v);
              },
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- console

  Widget _buildEmptyState() {
    final l10n = AppLocalizations.of(context)!;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.article_outlined, size: 44, color: _scheme.outline),
          const SizedBox(height: 12),
          Text(
            l10n.logsEmpty,
            style: TextStyle(fontSize: 14, color: _scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.logsConnectToSee,
            style: TextStyle(fontSize: 12.5, color: _dimColor),
          ),
        ],
      ),
    );
  }

  Widget _buildLogsList(List<_LogLine> visible) {
    if (visible.isEmpty) {
      return Center(
        child: Text(
          _filter == LogLevel.error ? 'No errors' : 'No warnings',
          style: TextStyle(fontSize: 12.5, color: _dimColor),
        ),
      );
    }

    // One selection across the whole console rather than per-line islands of
    // selectable text: dragging now takes the timestamp and level with it.
    return SelectionArea(
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
        itemCount: visible.length,
        // Rows are plain text with no state worth preserving off-screen.
        addAutomaticKeepAlives: false,
        itemBuilder: (context, index) => _buildLogEntry(visible[index]),
      ),
    );
  }

  /// `[14:02:04] WARN message (×3)` → dim stamp · level token · coloured
  /// text. The message body keeps everything but the level token, the
  /// duplicate-collapse suffix included. Everything that used to be decided
  /// here — the timestamp split, the level, the two text styles — is now
  /// decided once, off the frame.
  Widget _buildLogEntry(_LogLine line) {
    final tokenStyle = _tokenStyles[line.level.index];

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            // Eight glyphs at 0.612em of advance; 60 left barely three pixels
            // of slack, which the fallback face can eat. Never let the stamp
            // wrap — a clipped timestamp is readable, a broken row is not.
            width: 64,
            child: Text(
              line.timestamp,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: _stampStyle,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 44,
            child: Text(_levelTokens[line.level.index], style: tokenStyle),
          ),
          Expanded(
            child: Text(
              line.message,
              style: _messageStyles[line.level.index],
            ),
          ),
        ],
      ),
    );
  }

  /// Pinned inside the console's bottom edge, behind a hairline.
  Widget _buildCounters(int total, int errorCount) {
    final l10n = AppLocalizations.of(context)!;

    return Container(
      height: 37,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: _scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: _countSpans(l10n.logsTotalEntries(total), total),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _counterBodyStyle,
            ),
          ),
          if (errorCount > 0) ...[
            const SizedBox(width: 16),
            Icon(Icons.error_outline, size: 16, color: _statusError),
            const SizedBox(width: 6),
            Text('$errorCount', style: _counterErrorStyle),
            const SizedBox(width: 5),
            Text('errors', style: _counterErrorLabelStyle),
          ],
        ],
      ),
    );
  }

  /// Splits the localized "{count} lines · this session only" around its
  /// number so the count reads as data (mono) and the rest as prose. Falls
  /// back to the plain sentence if the placeholder cannot be located.
  List<TextSpan> _countSpans(String sentence, int count) {
    final token = '$count';
    final at = sentence.indexOf(token);
    if (at < 0) return [TextSpan(text: sentence)];
    return [
      if (at > 0) TextSpan(text: sentence.substring(0, at)),
      TextSpan(text: token, style: _counterValueStyle),
      TextSpan(text: sentence.substring(at + token.length)),
    ];
  }

  // ---------------------------------------------------------------- actions

  void _copyLogs() {
    final text = (_vpnService?.logs ?? const <String>[]).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    showAppSnackBar(
      context,
      AppLocalizations.of(context)!.logsCopied,
      kind: SnackKind.success,
    );
  }

  void _confirmClearLogs() {
    final vpnService = _vpnService;
    if (vpnService == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.logsClearTitle),
        content: Text(AppLocalizations.of(context)!.logsClearMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context)!.commonCancel),
          ),
          FilledButton(
            onPressed: () {
              vpnService.clearLogs();
              Navigator.pop(context);
              showAppSnackBar(
                this.context,
                AppLocalizations.of(this.context)!.logsCleared,
              );
            },
            child: Text(AppLocalizations.of(context)!.commonClear),
          ),
        ],
      ),
    );
  }
}
