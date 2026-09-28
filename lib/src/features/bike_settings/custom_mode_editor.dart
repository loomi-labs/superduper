import 'package:flutter/material.dart';
import 'package:superduper/src/domain/ride_modes.dart';

/// Edits one custom mode in a bottom sheet. Returns the edited mode, or null
/// when the rider backs out. Nothing here writes to the bike.
Future<CustomMode?> showCustomModeEditor(
  BuildContext context, {
  required CustomMode mode,
  required BikeRegion? region,
  required bool autoName,
}) {
  return showModalBottomSheet<CustomMode>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) =>
        _CustomModeEditor(mode: mode, region: region, autoName: autoName),
  );
}

final class _CustomModeEditor extends StatefulWidget {
  const new({required this.mode, required this.region, required this.autoName});

  final CustomMode mode;

  /// The region decides the bank of the profiles and the unit.
  final BikeRegion? region;

  /// True for a new mode: its name follows the limit until the rider types
  /// a name. False for an existing mode: its name never changes by itself.
  final bool autoName;

  @override
  State<_CustomModeEditor> createState() => _CustomModeEditorState();
}

final class _CustomModeEditorState extends State<_CustomModeEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late int _limitKmh;
  late bool _throttle;

  /// True while the name field holds text the rider typed. An empty field
  /// gives the name back to the automatic name.
  var _nameEdited = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.mode.name);
    _throttle = widget.mode.throttle;
    _limitKmh = widget.mode.effectiveLimitKmh;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _useMph => widget.region == BikeRegion.us;

  int get _displayLimit => _useMph ? mphFromKmh(_limitKmh) : _limitKmh;

  String get _displayUnit => _useMph ? 'mph' : 'km/h';

  int get _displayMin => _useMph ? mphFromKmh(customLimitMin) : customLimitMin;

  int get _displayMax => _useMph ? mphFromKmh(customLimitMax) : customLimitMax;

  void _setDisplayLimit(int displayed) {
    final kmh = _useMph ? kmhFromMph(displayed) : displayed;
    setState(() => _limitKmh = kmh.clamp(customLimitMin, customLimitMax));
    _syncAutoName();
  }

  void _syncAutoName() {
    if (!widget.autoName || _nameEdited) {
      return;
    }
    final name = customModeNameFor(_limitKmh, widget.region);
    _nameController.value = TextEditingValue(
      text: name,
      selection: TextSelection.collapsed(offset: name.length),
    );
  }

  String get _dropoutCaption {
    final draft = widget.mode.copyWith(
      limitKmh: _limitKmh,
      throttle: _throttle,
    );
    final base = baseProfileFor(
      _limitKmh,
      throttle: _throttle,
      region: widget.region,
    );
    if (isStaticCustomMode(draft, widget.region)) {
      return 'Exactly matches the ${base.name} firmware profile. The bike '
          'holds this limit itself.';
    }
    if (base.unlimited) {
      return 'Above 32 km/h no firmware profile has both a throttle and a '
          'limit. The bike rides ${base.name} below $_limitKmh km/h and the '
          'app holds the limit. If Bluetooth drops, the bike stays unlimited '
          'until the app reconnects.';
    }
    final cap = capProfileFor(
      _limitKmh,
      throttle: _throttle,
      region: widget.region,
    );
    return 'Rides ${base.name} below $_limitKmh km/h and ${cap.name} above '
        'it. If Bluetooth drops, the bike keeps the profile it is on.';
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    Navigator.pop(
      context,
      widget.mode.copyWith(
        name: _nameController.text.trim(),
        limitKmh: _limitKmh,
        throttle: _throttle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final readout = '$_displayLimit $_displayUnit';
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Custom mode', style: textTheme.titleLarge),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('custom-mode-name'),
                  controller: _nameController,
                  maxLength: customModeNameMaxLength,
                  decoration: const InputDecoration(labelText: 'Name'),
                  // The field's own callback, not a controller listener: the
                  // automatic name also writes the controller.
                  onChanged: (value) => _nameEdited = value.trim().isNotEmpty,
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'Enter a name.' : null,
                ),
                SwitchListTile(
                  key: const Key('custom-mode-throttle'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Throttle'),
                  value: _throttle,
                  onChanged: (value) => setState(() => _throttle = value),
                ),
                Row(
                  children: [
                    IconButton(
                      key: const Key('custom-mode-minus'),
                      tooltip: 'Lower limit',
                      icon: const Icon(Icons.remove_rounded),
                      onPressed: () => _setDisplayLimit(_displayLimit - 1),
                    ),
                    Expanded(
                      child: Slider(
                        key: const Key('custom-mode-slider'),
                        value: _displayLimit.toDouble(),
                        min: _displayMin.toDouble(),
                        max: _displayMax.toDouble(),
                        divisions: _displayMax - _displayMin,
                        label: readout,
                        onChanged: (value) => _setDisplayLimit(value.round()),
                      ),
                    ),
                    IconButton(
                      key: const Key('custom-mode-plus'),
                      tooltip: 'Raise limit',
                      icon: const Icon(Icons.add_rounded),
                      onPressed: () => _setDisplayLimit(_displayLimit + 1),
                    ),
                    SizedBox(
                      width: 72,
                      child: Text(
                        readout,
                        textAlign: TextAlign.end,
                        style: textTheme.labelLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(_dropoutCaption, style: textTheme.bodySmall),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('custom-mode-save'),
                      onPressed: _save,
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
