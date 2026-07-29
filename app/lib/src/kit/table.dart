/// `MeshTable` — hairline-separated rows that can expand in place.
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../icons/mesh_icons.dart';
import '../theme/theme.dart';
import 'button.dart';
import 'motion.dart';

/// One column. Give it either a fixed [width] or a [flex] share of what is
/// left over.
class MeshColumn {
  const MeshColumn(
    this.label, {
    this.width,
    this.flex = 1,
    this.align = Alignment.centerLeft,
  });

  /// 11px `textDim`, sentence case.
  final String label;

  final double? width;
  final int flex;
  final Alignment align;
}

/// One row, and optionally what it reveals when expanded.
class MeshTableRow {
  const MeshTableRow({
    required this.cells,
    this.expanded,
    this.onTap,
    this.key,
    this.tone,
  });

  /// Same length as the table's columns.
  final List<Widget> cells;

  /// Built only while the row is open. Null means the row does not expand.
  final WidgetBuilder? expanded;

  /// Runs in addition to toggling expansion.
  final VoidCallback? onTap;

  /// Identity across rebuilds, so an open row stays open when data ticks.
  final Object? key;

  /// A 2px left edge marking a row that is reporting state.
  final MeshTone? tone;
}

/// A dense data table.
///
/// Headers are 11px `textDim`, cells are whatever you pass (mono, by
/// convention), rows hover to `surfaceHigh`, and an expandable row shows a
/// chevron and opens in place on click or Enter.
class MeshTable extends StatefulWidget {
  const MeshTable({
    required this.columns,
    required this.rows,
    this.empty,
    this.rowHeight = 36,
    super.key,
  });

  /// Cells start where a panel's body would: a table drops the panel's padding
  /// so its rows can span the full width, and then puts it back per cell so the
  /// columns line up with everything else on the screen.
  static const double inset = FilamentSpace.panel;

  final List<MeshColumn> columns;
  final List<MeshTableRow> rows;

  /// Shown instead of the rows when there are none. Say what the CLI says.
  final Widget? empty;

  final double rowHeight;

  @override
  State<MeshTable> createState() => _MeshTableState();
}

class _MeshTableState extends State<MeshTable> {
  final Set<Object> _open = <Object>{};

  Object _idOf(int index) => widget.rows[index].key ?? index;

  @override
  Widget build(BuildContext context) {
    final theme = FilamentTheme.of(context);
    final tokens = theme.tokens;
    final anyExpandable = widget.rows.any((r) => r.expanded != null);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(theme, anyExpandable),
        if (widget.rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MeshTable.inset,
              vertical: FilamentSpace.x5,
            ),
            child:
                widget.empty ??
                Text('Nothing here yet', style: theme.type.bodyDim),
          )
        else
          for (var i = 0; i < widget.rows.length; i++)
            _Row(
              row: widget.rows[i],
              columns: widget.columns,
              height: widget.rowHeight,
              showChevron: anyExpandable,
              open: _open.contains(_idOf(i)),
              last: i == widget.rows.length - 1,
              tokens: tokens,
              onToggle: () {
                final id = _idOf(i);
                setState(() {
                  if (!_open.remove(id)) _open.add(id);
                });
              },
            ),
      ],
    );
  }

  Widget _header(FilamentTheme theme, bool anyExpandable) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.tokens.hairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          MeshTable.inset,
          FilamentSpace.x2 + 2,
          MeshTable.inset,
          FilamentSpace.x2 + 2,
        ),
        child: Row(
          children: [
            if (anyExpandable) const SizedBox(width: 20),
            for (final column in widget.columns)
              _cell(
                column,
                Text(
                  column.label,
                  style: theme.type.label,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  }

  static Widget _cell(MeshColumn column, Widget child) {
    final aligned = Align(alignment: column.align, child: child);
    return column.width != null
        ? SizedBox(width: column.width, child: aligned)
        : Expanded(flex: column.flex, child: aligned);
  }
}

class _Row extends StatefulWidget {
  const _Row({
    required this.row,
    required this.columns,
    required this.height,
    required this.showChevron,
    required this.open,
    required this.last,
    required this.tokens,
    required this.onToggle,
  });

  final MeshTableRow row;
  final List<MeshColumn> columns;
  final double height;
  final bool showChevron;
  final bool open;
  final bool last;
  final FilamentTokens tokens;
  final VoidCallback onToggle;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hovered = false;
  bool _focused = false;

  bool get _interactive =>
      widget.row.expanded != null || widget.row.onTap != null;

  void _activate() {
    widget.row.onTap?.call();
    if (widget.row.expanded != null) widget.onToggle();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = widget.tokens;
    final highlighted = _hovered || _focused || widget.open;
    final touch = FilamentMotion.touch(context);

    Widget body = AnimatedContainer(
      duration: touch.duration,
      curve: touch.curve,
      height: widget.height,
      color: highlighted ? tokens.surfaceHigh : null,
      padding: const EdgeInsets.symmetric(horizontal: MeshTable.inset),
      child: Row(
        children: [
          if (widget.showChevron)
            SizedBox(
              width: 20,
              child: widget.row.expanded == null
                  ? null
                  // The chevron rides the same spring as the reveal, so it
                  // lands with the row rather than ahead of it.
                  : MeshSpringBuilder(
                      value: widget.open ? 0 : -0.25,
                      builder: (context, turns, child) => Transform.rotate(
                        angle: turns * 2 * math.pi,
                        child: child,
                      ),
                      child: MeshIcon(
                        MeshGlyph.chevron,
                        size: 15,
                        color: highlighted ? tokens.text : tokens.textFaint,
                      ),
                    ),
            ),
          for (var i = 0; i < widget.columns.length; i++)
            _MeshTableCell(
              column: widget.columns[i],
              child: i < widget.row.cells.length
                  ? widget.row.cells[i]
                  : const SizedBox.shrink(),
            ),
        ],
      ),
    );

    if (widget.row.tone != null) {
      body = Row(
        children: [
          SizedBox(
            width: 2,
            height: widget.height,
            child: ColoredBox(color: widget.row.tone!.color(tokens)),
          ),
          Expanded(child: body),
        ],
      );
    }

    if (_interactive) {
      body = FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
        },
        child: MeshFocusRing(
          focused: _focused,
          radius: 0,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _activate,
            child: body,
          ),
        ),
      );
    }

    final expanded = widget.row.expanded;

    return DecoratedBox(
      decoration: BoxDecoration(
        border: widget.last && !widget.open
            ? null
            : Border(bottom: BorderSide(color: tokens.hairline)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          body,
          if (expanded != null)
            MeshSpringReveal(
              open: widget.open,
              reveal: (context) => DecoratedBox(
                decoration: BoxDecoration(
                  color: tokens.bg,
                  border: Border(top: BorderSide(color: tokens.hairline)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MeshTable.inset,
                    FilamentSpace.x4,
                    MeshTable.inset,
                    FilamentSpace.x4,
                  ),
                  child: Builder(builder: expanded),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MeshTableCell extends StatelessWidget {
  const _MeshTableCell({required this.column, required this.child});

  final MeshColumn column;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final aligned = Align(alignment: column.align, child: child);
    return column.width != null
        ? SizedBox(width: column.width, child: aligned)
        : Expanded(flex: column.flex, child: aligned);
  }
}
