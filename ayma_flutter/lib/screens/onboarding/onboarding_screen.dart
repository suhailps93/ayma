import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:geolocator/geolocator.dart';

import '../../services/backend_service.dart';
import '../../theme.dart';
import '../../widgets/ayma_button.dart';
import '../../widgets/ayma_text_field.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  bool _saving = false;

  // Step 0 – basics
  final _nameCtrl = TextEditingController();
  final _ageCtrl  = TextEditingController();

  // Step 1 – gender
  String? _gender;

  // Step 2 – preferences
  String? _interestedIn;
  int _minAge = 22;
  int _maxAge = 40;

  // Step 3 – location
  String _locationText = '';
  final _locationCtrl = TextEditingController();
  bool _locationLoading = false;
  List<String> _suggestions = [];
  Timer? _debounce;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ageCtrl.dispose();
    _locationCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _next() {
    if (_step < 3) {
      setState(() => _step++);
      // Auto-detect location when the user reaches the location step
      if (_step == 3) _detectLocation();
    } else {
      _save();
    }
  }

  Future<void> _detectLocation() async {
    setState(() => _locationLoading = true);
    try {
      final pos = await Geolocator.getCurrentPosition();
      final result = await BackendService.get('/api/location/reverse', {
        'lat': pos.latitude,
        'lon': pos.longitude,
      }) as Map<String, dynamic>;
      final location = (result['location'] as String?) ?? '';
      setState(() {
        _locationText = location;
        _locationCtrl.text = location;
      });
    } catch (_) {}
    setState(() => _locationLoading = false);
  }

  void _onLocationChanged(String val) {
    _debounce?.cancel();
    if (val.length < 3) { setState(() => _suggestions = []); return; }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final response =
            await BackendService.get('/api/location/search', {'q': val}) as List<dynamic>;
        final results = response
            .map((item) => (item as Map<String, dynamic>)['short_name'] as String)
            .where((item) => item.isNotEmpty)
            .toSet()
            .toList();
        if (mounted) setState(() => _suggestions = results);
      } catch (_) {}
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await BackendService.post('/api/onboarding', {
        'display_name': _nameCtrl.text.trim(),
        'age': int.tryParse(_ageCtrl.text.trim()) ?? 0,
        'gender': _gender,
        'matching_prefs': {
          'interested_in': _interestedIn,
          'age_min': _minAge,
          'age_max': _maxAge,
        },
        'location_region': _locationText,
      });
      if (mounted) context.go('/chat');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: $e')),
        );
      }
    }
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            // Progress dots
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
              child: Row(
                children: List.generate(4, (i) => Expanded(
                  child: Container(
                    height: 2,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: i <= _step
                          ? AymaColors.accent
                          : AymaColors.border,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                )),
              ),
            ),

            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween<Offset>(
                          begin: const Offset(0.05, 0), end: Offset.zero)
                          .animate(anim),
                      child: child,
                    ),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(_step),
                    child: _buildStep(),
                  ),
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 32),
              child: AymaButton(
                label: _step < 3 ? 'Continue' : 'Get started',
                loading: _saving,
                onPressed: _canProceed ? _next : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get _canProceed {
    switch (_step) {
      case 0: return _nameCtrl.text.trim().isNotEmpty && _ageCtrl.text.trim().isNotEmpty;
      case 1: return _gender != null;
      case 2: return _interestedIn != null;
      case 3: return true;
      default: return false;
    }
  }

  Widget _buildStep() {
    switch (_step) {
      case 0: return _StepBasics(nameCtrl: _nameCtrl, ageCtrl: _ageCtrl, onChanged: () => setState(() {}));
      case 1: return _StepGender(selected: _gender, onSelect: (v) => setState(() => _gender = v));
      case 2: return _StepPreferences(
          interestedIn: _interestedIn,
          minAge: _minAge, maxAge: _maxAge,
          onInterestSelect: (v) => setState(() => _interestedIn = v),
          onRangeChange: (min, max) => setState(() { _minAge = min; _maxAge = max; }),
        );
      case 3: return _StepLocation(
          ctrl: _locationCtrl,
          locationLoading: _locationLoading,
          suggestions: _suggestions,
          onDetect: _detectLocation,
          onChanged: (v) { _locationText = v; _onLocationChanged(v); },
          onSuggestionTap: (s) => setState(() {
            _locationText = s;
            _locationCtrl.text = s;
            _suggestions = [];
          }),
        );
      default: return const SizedBox();
    }
  }
}

// ── Step widgets ─────────────────────────────────────────────────────────────

class _StepBasics extends StatelessWidget {
  final TextEditingController nameCtrl, ageCtrl;
  final VoidCallback onChanged;
  const _StepBasics({required this.nameCtrl, required this.ageCtrl, required this.onChanged});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 20),
      _Heading('Tell us about yourself'),
      const SizedBox(height: 8),
      _Sub('This helps Ayma find the right matches for you.'),
      const SizedBox(height: 40),
      AymaTextField(controller: nameCtrl, label: 'Your name', onSubmitted: (_) => onChanged()),
      const SizedBox(height: 14),
      AymaTextField(
        controller: ageCtrl,
        label: 'Age',
        keyboardType: TextInputType.number,
        onSubmitted: (_) => onChanged(),
      ),
      const Spacer(),
    ],
  );
}

class _StepGender extends StatelessWidget {
  final String? selected;
  final ValueChanged<String> onSelect;
  const _StepGender({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 20),
      _Heading('How do you identify?'),
      const SizedBox(height: 8),
      _Sub('Your identity helps us personalise your experience.'),
      const SizedBox(height: 40),
      ...['Man', 'Woman', 'Non-binary', 'Other'].map((g) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _ChoiceTile(
          label: g,
          selected: selected == g.toLowerCase(),
          onTap: () => onSelect(g.toLowerCase()),
        ),
      )),
      const Spacer(),
    ],
  );
}

class _StepPreferences extends StatelessWidget {
  final String? interestedIn;
  final int minAge, maxAge;
  final ValueChanged<String> onInterestSelect;
  final void Function(int, int) onRangeChange;
  const _StepPreferences({
    required this.interestedIn, required this.minAge, required this.maxAge,
    required this.onInterestSelect, required this.onRangeChange,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 20),
      _Heading('Who are you interested in?'),
      const SizedBox(height: 8),
      _Sub('Ayma will use this to find compatible matches.'),
      const SizedBox(height: 40),
      ...['Men', 'Women', 'Everyone'].map((g) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _ChoiceTile(
          label: g,
          selected: interestedIn == g.toLowerCase(),
          onTap: () => onInterestSelect(g.toLowerCase()),
        ),
      )),
      const SizedBox(height: 28),
      Text('Age range  $minAge – $maxAge',
          style: TextStyle(color: AymaColors.textSecondary, fontSize: 14)),
      const SizedBox(height: 8),
      RangeSlider(
        values: RangeValues(minAge.toDouble(), maxAge.toDouble()),
        min: 18, max: 70,
        divisions: 52,
        activeColor: AymaColors.accent,
        inactiveColor: AymaColors.border,
        onChanged: (v) => onRangeChange(v.start.round(), v.end.round()),
      ),
      const Spacer(),
    ],
  );
}

class _StepLocation extends StatelessWidget {
  final TextEditingController ctrl;
  final bool locationLoading;
  final List<String> suggestions;
  final VoidCallback onDetect;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSuggestionTap;

  const _StepLocation({
    required this.ctrl, required this.locationLoading,
    required this.suggestions, required this.onDetect,
    required this.onChanged, required this.onSuggestionTap,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 20),
      _Heading('Where are you based?'),
      const SizedBox(height: 8),
      _Sub('Used to find matches and local recommendations.'),
      const SizedBox(height: 40),
      AymaTextField(
        controller: ctrl,
        label: 'City, region',
        onSubmitted: (_) {},
        suffix: locationLoading
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)))
            : IconButton(
                icon: Icon(Icons.my_location_rounded,
                    color: AymaColors.accent, size: 20),
                onPressed: onDetect,
              ),
      ),
      if (suggestions.isNotEmpty) ...[
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: AymaColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AymaColors.border),
          ),
          child: Column(
            children: suggestions.map((s) => ListTile(
              dense: true,
              title: Text(s, style: TextStyle(color: AymaColors.textPrimary, fontSize: 14)),
              onTap: () => onSuggestionTap(s),
            )).toList(),
          ),
        ),
      ],
      const Spacer(),
    ],
  );
}

// ── Shared micro-widgets ──────────────────────────────────────────────────────

class _Heading extends StatelessWidget {
  final String text;
  const _Heading(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
      color: AymaColors.textPrimary, fontWeight: FontWeight.w600));
}

class _Sub extends StatelessWidget {
  final String text;
  const _Sub(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
    style: TextStyle(color: AymaColors.textSecondary, fontSize: 14));
}

class _ChoiceTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ChoiceTile({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      height: 56,
      decoration: BoxDecoration(
        color: selected ? AymaColors.accent.withValues(alpha: 0.12) : AymaColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? AymaColors.accent : AymaColors.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: [
            Text(label, style: TextStyle(
              color: selected ? AymaColors.accent : AymaColors.textPrimary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              fontSize: 15,
            )),
            const Spacer(),
            if (selected)
              Icon(Icons.check_rounded, color: AymaColors.accent, size: 18),
          ],
        ),
      ),
    ),
  );
}
