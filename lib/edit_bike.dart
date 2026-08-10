import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:form_builder_validators/form_builder_validators.dart';
import 'package:superduper/bike.dart';
import 'package:superduper/colors.dart';

/// Applies the Edit sheet's fields to [live] — the bike as the app has it *at
/// Save time*, not the snapshot the sheet was opened on. The sheet can sit open
/// for minutes while the poll brings in light, assist or a guessed region from
/// the bike; copying the form onto the snapshot would write all of that back.
///
/// The selection is the sheet's own responsibility only in as far as its
/// edits can invalidate it: a region change moves the mode banks, and a
/// deleted custom mode leaves the id dangling. Both go through the engine —
/// [remapModeForRegion] and [BikeState.fallbackMode] via
/// [BikeState.withSelectedMode], so the legacy projection stays in sync — and
/// never through a raw `copyWith(modeId:)`.
BikeState applySheetEdits(
  BikeState live, {
  required String name,
  required int color,
  required BikeRegion? region,
  required List<CustomMode> customModes,
  required bool autoReconnect,
}) {
  var next = live.copyWith(
      name: name,
      color: color,
      // A copy: the caller's list is the sheet's draft, which it goes on
      // mutating after Save if the user reopens the editor.
      customModes: List<CustomMode>.of(customModes),
      autoReconnect: autoReconnect);
  if (region != live.region) {
    // Applies the region itself and makes the selection valid for it: a custom
    // mode is kept, a native one moves to the same place in the new bank. Only
    // on a change — entering CH re-seeds the seeded mode, which a CH rider who
    // deleted it in favour of their own modes has not asked for.
    next = remapModeForRegion(next, region);
  }
  if (next.region == BikeRegion.ch && next.customModes.isEmpty) {
    // CH has no limited native mode, so its fallback is a custom one, and an
    // empty list would resolve to a mode that is in no selectable list at all.
    // The same guard the notifier's deleteCustomMode applies.
    next = next.copyWith(customModes: const [seededChMode]);
  }
  if (!next.selectableModes.any((m) => m.id == next.modeId)) {
    // The mode the bike was riding was deleted in the sheet (or remapped out of
    // its bank): land on the region's fallback rather than leave a dangling id
    // that only resolves in memory.
    next = next.withSelectedMode(next.fallbackMode.id);
  }
  return next;
}

void show(BuildContext context, BikeState bike) {
  showModalBottomSheet<void>(
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      context: context,
      builder: (BuildContext context) {
        return BikeSettingsWidget(bike: bike);
      });
}

class BikeSettingsWidget extends ConsumerStatefulWidget {
  const BikeSettingsWidget({super.key, required this.bike});
  final BikeState bike;

  @override
  BikeSettingsWidgetState createState() => BikeSettingsWidgetState();
}

class BikeSettingsWidgetState extends ConsumerState<BikeSettingsWidget> {
  @override
  Widget build(BuildContext context) {
    // Get the keyboard inset to adjust for keyboard appearance
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
        ),
      ),
      // Use the height constraint to make the modal fill only part of the screen
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: SafeArea(
        child: Padding(
          // Add bottom padding equal to keyboard height when keyboard is visible
          padding: EdgeInsets.only(bottom: bottomInset > 0 ? bottomInset : 0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // Modal draggable indicator
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 16),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20.0),
                child: Row(
                  children: [
                    Text(
                      'Edit Bike',
                      style: Theme.of(context).textTheme.titleLarge!.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () {
                        Navigator.pop(context);
                      },
                      icon: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.grey[800],
                          borderRadius: BorderRadius.circular(50),
                        ),
                        child: const Icon(
                          Icons.close,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    )
                  ],
                ),
              ),
              // Make the form scrollable when keyboard appears
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20.0),
                    child: Column(
                      children: [
                        CompleteForm(bike: widget.bike),
                        // Add bottom spacing for better scrolling
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CompleteForm extends ConsumerStatefulWidget {
  const CompleteForm({super.key, required this.bike});
  final BikeState bike;

  @override
  ConsumerState<CompleteForm> createState() {
    return _CompleteFormState();
  }
}

class _CompleteFormState extends ConsumerState<CompleteForm> {
  final _formKey = GlobalKey<FormBuilderState>();
  late int _selectedColorIndex;

  /// Mirrors the checkbox so the note below it can react without reaching into
  /// the form's state.
  late bool _autoReconnect;

  /// The custom modes as the sheet has them. Adding, editing and deleting a
  /// mode only ever touch this list; it reaches the bike when Save does. The
  /// sheet is also the *create* form (debug.dart opens it on a bike that was
  /// never persisted), so nothing here may write through on its own.
  late List<CustomMode> _draftModes;

  var genderOptions = ['Male', 'Female', 'Other'];

  @override
  void initState() {
    super.initState();
    _selectedColorIndex = widget.bike.color;
    _autoReconnect = widget.bike.autoReconnect;
    _draftModes = List<CustomMode>.of(widget.bike.customModes);
  }

  /// The bike as the sheet would save it, for the questions the notes and the
  /// delete dialog ask: which mode is selected, and does it switch by speed.
  /// The region comes from the dropdown rather than from the snapshot — the
  /// rider may have changed it a moment ago, and it decides both answers.
  BikeState get _draftBike {
    final region = _formKey.currentState?.value['region'] as BikeRegion? ??
        widget.bike.region;
    return widget.bike.copyWith(region: region, customModes: _draftModes);
  }

  Future<void> _addCustomMode() async {
    final mode = CustomMode(
        id: newCustomModeId(),
        name: customModeNameFor(customLimitMin),
        limitKmh: customLimitMin,
        throttle: false);
    setState(() {
      _draftModes = [..._draftModes, mode];
    });
    // Only the add path names the mode by itself. The flag is passed, never
    // guessed from the name: a mode the rider deliberately called '30 km/h'
    // would otherwise get renamed under their hands.
    final edited = await _showCustomModeEditor(context, mode, _draftBike.region,
        autoName: true);
    if (!mounted) {
      return;
    }
    setState(() {
      // A cancelled editor leaves no half-made mode behind.
      _draftModes = edited == null
          ? _draftModes.where((m) => m.id != mode.id).toList()
          : [for (final m in _draftModes) m.id == edited.id ? edited : m];
    });
  }

  Future<void> _editCustomMode(CustomMode mode) async {
    final edited = await _showCustomModeEditor(context, mode, _draftBike.region,
        autoName: false);
    if (edited == null || !mounted) {
      return;
    }
    setState(() {
      _draftModes = [
        for (final m in _draftModes) m.id == edited.id ? edited : m
      ];
    });
  }

  /// The bike as Save would leave it, with [customModes] standing in for the
  /// draft list. Run through [applySheetEdits] — the very function the Save
  /// button calls — rather than assembled here: Save resolves a selection the
  /// region dropdown invalidated in the OLD region first and remaps the result,
  /// and a second, parallel computation of "what happens next" disagreed with
  /// it every time the dropdown had been touched.
  ///
  /// [widget.bike], not `ref.read(bikeProvider(...))`: reading the provider
  /// creates it, and the create sheet is opened on a bike nothing has persisted
  /// — merely looking at a delete dialog would leave that bike behind. Only
  /// the poll's own fields (light, assist, a guessed region) can differ, and
  /// none of them names a mode.
  BikeState _savedBike(List<CustomMode> customModes) {
    final values = _formKey.currentState?.value ?? const <String, Object?>{};
    return applySheetEdits(
      widget.bike,
      name: values['name'] as String? ?? widget.bike.name,
      color: _selectedColorIndex,
      region: values['region'] as BikeRegion? ?? widget.bike.region,
      customModes: customModes,
      autoReconnect:
          values['autoReconnect'] as bool? ?? widget.bike.autoReconnect,
    );
  }

  /// Deletes a mode from the draft, after saying what that costs.
  ///
  /// Two things need explaining: the bike moves to another mode when the
  /// selected one goes, and a CH bike always keeps one custom mode — its
  /// fallback is a custom mode, so deleting the last one re-seeds the built-in
  /// 25 km/h one instead of leaving the list empty. Both questions are put to
  /// [_savedBike], so the dialog can only ever name what Save will do.
  Future<void> _deleteCustomMode(CustomMode mode) async {
    final remaining = _draftModes.where((m) => m.id != mode.id).toList();
    final before = _savedBike(_draftModes);
    final reseeds = before.region == BikeRegion.ch && remaining.isEmpty;
    if (reseeds && mode.id == seededChModeId) {
      // Deleting it would put the very same mode back: say so and keep it.
      await _showSeededModeDialog(mode);
      return;
    }
    // Which mode the bike is on is Save's answer too: a region change can move
    // the selection off this mode before the delete is even considered.
    final selected = before.selectedMode.id == mode.id;
    if (selected || reseeds) {
      final after = _savedBike(remaining);
      // Selected: the mode the bike ends up on. Otherwise this is the last CH
      // custom, and what takes its place is the mode the re-seed put in the
      // list — the selection has not moved.
      final landing =
          selected ? after.selectedMode.name : after.customModes.first.name;
      final confirmed =
          await _showDeleteModeDialog(mode, landing, selected: selected);
      if (!(confirmed ?? false) || !mounted) {
        return;
      }
    }
    setState(() {
      _draftModes = remaining;
    });
  }

  Future<void> _showSeededModeDialog(CustomMode mode) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text('Built-in Mode'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(
                  'This is the built-in ${mode.name} mode — deleting it just '
                  'recreates it.',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  'Switzerland has no limited firmware mode, so the bike '
                  'always keeps one custom mode to fall back on. Add another '
                  'mode first if you want this one gone.',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () {
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  Future<bool?> _showDeleteModeDialog(CustomMode mode, String fallbackName,
      {required bool selected}) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text('Delete Mode'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(
                  selected
                      ? '${mode.name} is the selected mode. After saving, the '
                          'bike will switch to $fallbackName.'
                      : '${mode.name} is the last custom mode. Switzerland has '
                          'no limited firmware mode, so after saving the '
                          'built-in $fallbackName mode takes its place.',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text('Continue?',
                    style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
              onPressed: () {
                Navigator.of(context).pop(true);
              },
            ),
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop(false);
              },
            ),
          ],
        );
      },
    );
  }

  Future<bool?> _showMyDialog() async {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false, // user must tap button!
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: Colors.grey[900],
          title: const Text('Delete Bike'),
          content: SingleChildScrollView(
            child: ListBody(
              children: <Widget>[
                Text(
                  'This will delete ${widget.bike.name} from your list.',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text('Continue?',
                    style: Theme.of(context).textTheme.titleSmall),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
              onPressed: () {
                Navigator.of(context).pop(true);
              },
            ),
            TextButton(
              child: const Text('Cancel'),
              onPressed: () {
                Navigator.of(context).pop(false);
              },
            ),
          ],
        );
      },
    );
  }

  /// The notifier, taken at the moment a button is pressed rather than in
  /// [build]. Watching it there would *create* the provider for a bike the
  /// sheet has only been opened on: the notifier connects, polls, and saves
  /// what it reads — so opening the create sheet and walking away used to
  /// leave a bike behind that was never saved.
  Bike get _bikeNotifier => ref.read(bikeProvider(widget.bike.id).notifier);

  @override
  Widget build(BuildContext context) {
    final colors = getColorList();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FormBuilder(
            key: _formKey,
            onChanged: () {
              _formKey.currentState!.save();
            },
            autovalidateMode: AutovalidateMode.onUserInteraction,
            initialValue: {
              'name': widget.bike.name,
              'region': widget.bike.region,
              'color': widget.bike.color,
              'autoReconnect': widget.bike.autoReconnect,
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                // Name field
                FormBuilderTextField(
                  name: 'name',
                  style: Theme.of(context).textTheme.bodyMedium,
                  decoration: InputDecoration(
                    labelText: 'Name',
                    labelStyle: TextStyle(color: Colors.grey[400]),
                    filled: true,
                    fillColor: Colors.grey[800]!.withAlpha(100),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 16),
                  ),
                  validator: FormBuilderValidators.compose([
                    FormBuilderValidators.required(),
                  ]),
                  textInputAction: TextInputAction.next,
                ),

                const SizedBox(height: 24),

                // Region dropdown
                FormBuilderDropdown<BikeRegion>(
                  name: 'region',
                  decoration: InputDecoration(
                    labelText: 'Region',
                    labelStyle: TextStyle(color: Colors.grey[400]),
                    filled: true,
                    fillColor: Colors.grey[800]!.withAlpha(100),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 16),
                  ),
                  validator: FormBuilderValidators.compose(
                      [FormBuilderValidators.required()]),
                  items: BikeRegion.values
                      .map((region) => DropdownMenuItem(
                            value: region,
                            child: Text(region.value),
                          ))
                      .toList(),
                  dropdownColor: Colors.grey[900],
                  borderRadius: BorderRadius.circular(12),
                  iconSize: 24,
                  icon: const Icon(Icons.arrow_drop_down, color: Colors.grey),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),

                const SizedBox(height: 16),

                // Auto-reconnect. The Material is not decoration: the checkbox
                // renders a ListTile, and the sheet's own coloured container
                // would otherwise swallow its ink splashes (and trip an
                // assertion in debug builds).
                Material(
                  type: MaterialType.transparency,
                  child: FormBuilderCheckbox(
                    name: 'autoReconnect',
                    key: const ValueKey('autoReconnectCheckbox'),
                    title: Text(
                      'Auto-reconnect',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    contentPadding: EdgeInsets.zero,
                    onChanged: (value) {
                      setState(() {
                        _autoReconnect = value ?? true;
                      });
                    },
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.only(left: 4, right: 4),
                  child: Text(
                    'Reconnect automatically whenever the bike is in range. '
                    'Turn this off to power-cycle the bike back to its own '
                    'defaults without this app re-applying its settings. The '
                    'Connect button always works. While a dynamic custom mode '
                    'is selected, reconnect stays active regardless — the '
                    'speed limiter must be able to recover.',
                    style: Theme.of(context).textTheme.bodySmall!.copyWith(
                          color: Colors.grey,
                          fontSize: 12,
                        ),
                  ),
                ),

                if (!_autoReconnect && _draftBike.needsSpeedSwitching)
                  Padding(
                    key: const ValueKey('autoReconnectWarning'),
                    padding: const EdgeInsets.only(left: 4, right: 4, top: 8),
                    child: Text(
                      'A dynamic mode is selected, so auto-reconnect remains '
                      'active for it. Select OFFROAD or an exact-match mode '
                      'for this setting to take full effect.',
                      style: Theme.of(context).textTheme.bodySmall!.copyWith(
                            color: Colors.orange,
                            fontSize: 12,
                          ),
                    ),
                  ),

                const SizedBox(height: 32),

                // Color section
                Text(
                  'Bike Color',
                  style: Theme.of(context).textTheme.titleSmall!.copyWith(
                        color: Colors.grey[400],
                      ),
                ),

                const SizedBox(height: 12),

                // Color picker button
                InkWell(
                  onTap: () async {
                    var colorIndex =
                        await _showColorPicker(context, _selectedColorIndex);
                    setState(() {
                      _selectedColorIndex = colorIndex;
                    });
                  },
                  child: Container(
                    height: 60,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: LinearGradient(
                        colors: [
                          colors[_selectedColorIndex].start,
                          colors[_selectedColorIndex].end,
                        ],
                        begin: Alignment.bottomLeft,
                        end: Alignment.topRight,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        'Select Color',
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colors[_selectedColorIndex].fontColor(),
                            ),
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                // Custom modes section
                Text(
                  'Custom Modes',
                  style: Theme.of(context).textTheme.titleSmall!.copyWith(
                        color: Colors.grey[400],
                      ),
                ),

                // The tiles render ListTiles, whose ink needs a Material the
                // sheet's own coloured container does not provide.
                Material(
                  type: MaterialType.transparency,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      for (final mode in _draftModes)
                        _CustomModeTile(
                          key: ValueKey('customModeTile:${mode.id}'),
                          mode: mode,
                          onTap: () => _editCustomMode(mode),
                          onDelete: () => _deleteCustomMode(mode),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 8),

                OutlinedButton.icon(
                  key: const ValueKey('addCustomModeButton'),
                  onPressed: _addCustomMode,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add custom mode'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: Colors.grey[700]!),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 40),

          // Action buttons
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Delete button
              ElevatedButton.icon(
                onPressed: () async {
                  if (await _showMyDialog() ?? false) {
                    _bikeNotifier.deleteStateData(widget.bike);
                    if (context.mounted) {
                      Navigator.pop(context);
                    }
                  }
                },
                icon: const Icon(Icons.delete, size: 18),
                label: const Text('Delete'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.withAlpha(51), // 0.2 opacity
                  foregroundColor: Colors.red,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),

              // Save button
              ElevatedButton.icon(
                onPressed: () {
                  if (_formKey.currentState?.saveAndValidate() ?? false) {
                    final values = _formKey.currentState!.value;
                    // The bike as it is now, not as the sheet found it: the
                    // poll may have brought in a handlebar light or assist
                    // change while the sheet was open. In the create flow the
                    // provider builds a default state for the id, which is
                    // what this sheet was handed anyway.
                    final live = ref.read(bikeProvider(widget.bike.id));
                    _bikeNotifier.writeStateData(
                        applySheetEdits(live,
                            name: values['name'] as String,
                            color: _selectedColorIndex,
                            region: values['region'] as BikeRegion?,
                            customModes: _draftModes,
                            autoReconnect:
                                values['autoReconnect'] as bool? ?? true),
                        saveToBike: false);
                    Navigator.pop(context);
                  }
                },
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Save'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xff441DFC).withAlpha(51),
                  foregroundColor: const Color(0xff441DFC),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One custom mode in the sheet's list. The subtitle shows the limit the engine
/// actually enforces, not the stored number: a hand-edited json (or a file from
/// a build with a wider range) can hold a limit the mode cannot ride, and the
/// list must show what the bike does.
class _CustomModeTile extends StatelessWidget {
  const _CustomModeTile(
      {super.key,
      required this.mode,
      required this.onTap,
      required this.onDelete});
  final CustomMode mode;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final limit = mode.effectiveLimitKmh;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        mode.name,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      subtitle: Text(
        mode.throttle ? '$limit km/h · throttle' : '$limit km/h',
        style: Theme.of(context).textTheme.bodySmall!.copyWith(
              color: Colors.grey,
              fontSize: 12,
            ),
      ),
      trailing: IconButton(
        tooltip: 'Delete ${mode.name}',
        icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
        onPressed: onDelete,
      ),
      onTap: onTap,
    );
  }
}

/// The name a new custom mode carries while the rider has not named it: the
/// speed it holds. One function for both the seed and the live update in the
/// editor, so the two cannot drift apart.
String customModeNameFor(int limitKmh) => '$limitKmh km/h';

/// Edits one custom mode in a sheet of its own (the colour picker's precedent).
/// Returns the edited mode, or null when the rider backs out — the caller's
/// draft list is what decides, so nothing here reaches the bike.
Future<CustomMode?> _showCustomModeEditor(
    BuildContext context, CustomMode mode, BikeRegion? region,
    {required bool autoName}) {
  return showModalBottomSheet<CustomMode>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.black,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (BuildContext context) {
      return _CustomModeEditor(mode: mode, region: region, autoName: autoName);
    },
  );
}

class _CustomModeEditor extends StatefulWidget {
  const _CustomModeEditor(
      {required this.mode, required this.region, required this.autoName});
  final CustomMode mode;

  /// The region as the sheet would SAVE it, not as the bike has it: the region
  /// decides which bank a mode's profiles come from, so a caption taken from
  /// the stale region would name a profile the bike will not ride.
  final BikeRegion? region;

  /// True for a mode the rider has just added. Its name then follows the limit
  /// until the rider types one of their own. False for every existing mode: a
  /// name already given is never overwritten.
  final bool autoName;

  @override
  State<_CustomModeEditor> createState() => _CustomModeEditorState();
}

class _CustomModeEditorState extends State<_CustomModeEditor> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late int _limitKmh;
  late bool _throttle;

  /// True while the name field holds text the rider typed. An empty field
  /// counts as not edited, so clearing the name gives the mode back to the
  /// automatic name instead of leaving it blank for the validator to refuse.
  bool _nameEdited = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.mode.name);
    _throttle = widget.mode.throttle;
    // Opens on the limit the engine enforces, never on a stored number above
    // it: the slider bounds keep every edit inside the range from here on.
    _limitKmh = widget.mode.effectiveLimitKmh;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _setLimit(int kmh) {
    setState(() {
      _limitKmh = kmh.clamp(customLimitMin, customLimitMax).toInt();
    });
    _syncAutoName();
  }

  /// Writes the automatic name after the limit moved. Only [_setLimit] calls
  /// it: the throttle switch no longer changes the limit.
  ///
  /// The decision is the flag and the flag only. Reading the field to guess
  /// whether the name looks automatic would rename a mode the rider called
  /// '30 km/h' on purpose.
  void _syncAutoName() {
    if (!widget.autoName || _nameEdited) {
      return;
    }
    final name = customModeNameFor(_limitKmh);
    // Not the plain `text` setter: it leaves the selection invalid, and the
    // field can hold the cursor while the rider drags the slider.
    _nameController.value = TextEditingValue(
      text: name,
      selection: TextSelection.collapsed(offset: name.length),
    );
  }

  void _setThrottle(bool value) {
    setState(() {
      _throttle = value;
    });
  }

  /// What happens when the app is not there to switch profiles. Straight from
  /// the engine, so the sheet cannot promise something the controller does not
  /// do.
  String get _dropoutCaption {
    final base =
        baseProfileFor(_limitKmh, _throttle, region: widget.region);
    if (isStaticCustomMode(
        widget.mode.copyWith(limitKmh: _limitKmh, throttle: _throttle),
        region: widget.region)) {
      return 'Exactly matches the ${base.name} firmware profile — the bike '
          'enforces this limit itself, no app needed.';
    }
    if (base.unlimited) {
      // The one mode the firmware does not hold. Said plainly: the rider is
      // trading the dropout fail-safe for a throttle above 32 km/h.
      return 'Above 32 km/h no firmware profile has both a throttle and a '
          'limit, so the bike rides ${base.name} below $_limitKmh km/h. This '
          'app holds the limit, not the bike: if Bluetooth drops while you '
          'ride below $_limitKmh km/h, the bike stays unlimited until the app '
          'reconnects. The app also needs live speed for the throttle. The '
          'bike sends no speed when it stands still, so the throttle does not '
          'work at a stop until you pedal away.';
    }
    return 'If Bluetooth drops while riding below $_limitKmh km/h, the bike '
        'stays capped at ${base.capKmh} km/h until the app reconnects.';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final captionStyle = Theme.of(context).textTheme.bodySmall!.copyWith(
          color: Colors.grey,
          fontSize: 12,
        );
    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.85,
      ),
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomInset > 0 ? bottomInset : 0),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Modal draggable indicator
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 8, bottom: 16),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey[600],
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: Text(
                    'Custom Mode',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextFormField(
                          key: const ValueKey('customModeNameField'),
                          controller: _nameController,
                          maxLength: 12,
                          style: Theme.of(context).textTheme.bodyMedium,
                          decoration: InputDecoration(
                            labelText: 'Name',
                            labelStyle: TextStyle(color: Colors.grey[400]),
                            filled: true,
                            fillColor: Colors.grey[800]!.withAlpha(100),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 16),
                          ),
                          // The field's own onChanged, not a listener on the
                          // controller: a listener also fires when
                          // _syncAutoName writes, which would mark the name
                          // edited on the first slider move.
                          onChanged: (value) {
                            _nameEdited = value.trim().isNotEmpty;
                          },
                          validator: (value) =>
                              (value ?? '').trim().isEmpty ? 'Required' : null,
                        ),

                        SwitchListTile(
                          key: const ValueKey('customModeThrottleSwitch'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            'Throttle',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          value: _throttle,
                          onChanged: _setThrottle,
                        ),

                        Row(
                          children: [
                            IconButton(
                              key: const ValueKey('customModeLimitMinus'),
                              tooltip: 'Decrease limit',
                              icon: const Icon(Icons.remove),
                              onPressed: () => _setLimit(_limitKmh - 1),
                            ),
                            Expanded(
                              child: Slider(
                                key: const ValueKey('customModeLimitSlider'),
                                value: _limitKmh.toDouble(),
                                min: customLimitMin.toDouble(),
                                max: customLimitMax.toDouble(),
                                divisions: customLimitMax - customLimitMin,
                                label: '$_limitKmh km/h',
                                onChanged: (value) => _setLimit(value.round()),
                              ),
                            ),
                            IconButton(
                              key: const ValueKey('customModeLimitPlus'),
                              tooltip: 'Increase limit',
                              icon: const Icon(Icons.add),
                              onPressed: () => _setLimit(_limitKmh + 1),
                            ),
                            SizedBox(
                              width: 68,
                              child: Text(
                                '$_limitKmh km/h',
                                textAlign: TextAlign.end,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),

                        Padding(
                          padding: const EdgeInsets.only(top: 4, bottom: 16),
                          child: Text(
                            _dropoutCaption,
                            key: const ValueKey('customModeDropoutCaption'),
                            style: captionStyle,
                          ),
                        ),

                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            TextButton(
                              onPressed: () {
                                Navigator.pop(context);
                              },
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton.icon(
                              key: const ValueKey('customModeEditorDone'),
                              onPressed: () {
                                if (!(_formKey.currentState?.validate() ??
                                    false)) {
                                  return;
                                }
                                Navigator.pop(
                                    context,
                                    widget.mode.copyWith(
                                        name: _nameController.text.trim(),
                                        limitKmh: _limitKmh,
                                        throttle: _throttle));
                              },
                              icon: const Icon(Icons.check, size: 18),
                              label: const Text('Done'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor:
                                    const Color(0xff441DFC).withAlpha(51),
                                foregroundColor: const Color(0xff441DFC),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 12),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<int> _showColorPicker(BuildContext context, int currentIndex) async {
  final colors = getColorList();
  final answer = await showModalBottomSheet<int>(
    context: context,
    backgroundColor: Colors.black,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (BuildContext context) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Modal draggable indicator
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 8, bottom: 16),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[600],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              'Select Bike Color',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),

          // Color grid
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: GridView.builder(
                padding: const EdgeInsets.only(bottom: 16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 1.5,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemCount: colors.length,
                itemBuilder: (BuildContext context, int index) {
                  final color = colors[index];
                  final textColor = color.fontColor();
                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        Navigator.pop(context, index);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          gradient: LinearGradient(
                            colors: [
                              color.start,
                              color.end,
                            ],
                            begin: Alignment.bottomLeft,
                            end: Alignment.topRight,
                          ),
                          boxShadow: [
                            if (index == currentIndex)
                              BoxShadow(
                                color: Colors.white.withAlpha(60),
                                blurRadius: 4,
                                spreadRadius: 2,
                              ),
                          ],
                        ),
                        child: Stack(
                          children: [
                            if (index == currentIndex)
                              Center(
                                child: Icon(
                                  Icons.check_circle,
                                  color: textColor,
                                  size: 28,
                                ),
                              ),
                            Positioned(
                              bottom: 8,
                              left: 8,
                              right: 8,
                              child: Text(
                                colors[index].name,
                                style: TextStyle(
                                    color: textColor,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      );
    },
  );
  if (answer != null) {
    return answer;
  }
  return currentIndex;
}
