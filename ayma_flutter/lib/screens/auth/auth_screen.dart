import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/providers.dart';
import '../../theme.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();

  bool _showEmail  = false;
  bool _isLogin    = true;
  bool _loading    = false;
  String? _error;
  bool _emailSent  = false;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() { _loading = true; _error = null; });
    try {
      if (_isLogin) {
        final ok = await ref.read(authControllerProvider).signIn(
          _emailCtrl.text.trim(), _passCtrl.text,
        );
        if (!ok) throw Exception('Login did not return a session.');
        if (mounted) context.go('/chat');
      } else {
        final ok = await ref.read(authControllerProvider).signUp(
          _emailCtrl.text.trim(), _passCtrl.text,
        );
        if (mounted) {
          if (ok) {
            context.go('/chat');
          } else {
            setState(() { _emailSent = true; _loading = false; });
          }
        }
        return;
      }
    } catch (e) {
      setState(() { _error = e.toString().replaceFirst('Exception: ', ''); });
    }
    if (mounted) setState(() => _loading = false);
  }

  void _comingSoon(String label) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label sign-in coming soon'),
        backgroundColor: AymaColors.bgElev,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;

    return Scaffold(
      backgroundColor: AymaColors.bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: h - MediaQuery.paddingOf(context).vertical),
            child: IntrinsicHeight(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Orb ────────────────────────────────────────────
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 48, bottom: 32),
                      child: _StaticOrb(),
                    ),
                  ).animate().fadeIn(duration: 800.ms),

                  // ── Headline ───────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'AYMA  ·  EST. 2026',
                          style: AymaFonts.mono(size: 10, color: AymaColors.fgMute),
                        ).animate(delay: 100.ms).fadeIn(duration: 500.ms),
                        const SizedBox(height: 10),
                        Text(
                          'Slow down.',
                          style: AymaFonts.serif(size: 48, color: AymaColors.fg),
                        ).animate(delay: 160.ms).fadeIn(duration: 500.ms).slideY(begin: 0.06, end: 0),
                        Text(
                          'Be found.',
                          style: AymaFonts.serif(size: 48, italic: true, color: AymaColors.accent),
                        ).animate(delay: 220.ms).fadeIn(duration: 500.ms).slideY(begin: 0.06, end: 0),
                        const SizedBox(height: 16),
                        Text(
                          'A matchmaker who actually listens. No swiping, no feed. Just conversations, and the people they lead to.',
                          style: TextStyle(
                            color: AymaColors.fgDim,
                            fontSize: 14,
                            height: 1.55,
                          ),
                        ).animate(delay: 300.ms).fadeIn(duration: 500.ms),
                      ],
                    ),
                  ),

                  const Spacer(),

                  // ── Actions ────────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.08),
                            end: Offset.zero,
                          ).animate(anim),
                          child: child,
                        ),
                      ),
                      child: _emailSent
                          ? _EmailSentCard(email: _emailCtrl.text.trim())
                          : _showEmail
                              ? _EmailForm(
                                  key: const ValueKey('email-form'),
                                  emailCtrl: _emailCtrl,
                                  passCtrl: _passCtrl,
                                  isLogin: _isLogin,
                                  loading: _loading,
                                  error: _error,
                                  onSubmit: _submit,
                                  onToggle: () => setState(() {
                                    _isLogin = !_isLogin;
                                    _error = null;
                                  }),
                                  onBack: () => setState(() {
                                    _showEmail = false;
                                    _error = null;
                                  }),
                                )
                              : _LandingButtons(
                                  key: const ValueKey('landing'),
                                  onApple: () => _comingSoon('Apple'),
                                  onGoogle: () => _comingSoon('Google'),
                                  onEmail: () => setState(() => _showEmail = true),
                                  onPhone: () => _comingSoon('Phone'),
                                ),
                    ),
                  ),

                  // ── Legal footer ───────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                    child: Center(
                      child: Text(
                        'BY CONTINUING YOU AGREE TO OUR\nTERMS  ·  PRIVACY  ·  CONVERSATION ETHICS',
                        textAlign: TextAlign.center,
                        style: AymaFonts.mono(size: 8, color: AymaColors.fgMute),
                      ),
                    ),
                  ).animate(delay: 500.ms).fadeIn(duration: 500.ms),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Landing buttons (Apple + Google/Email/Phone) ──────────────────────────────

class _LandingButtons extends StatelessWidget {
  final VoidCallback onApple, onGoogle, onEmail, onPhone;

  const _LandingButtons({
    super.key,
    required this.onApple,
    required this.onGoogle,
    required this.onEmail,
    required this.onPhone,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Continue with Apple — large cream pill
        GestureDetector(
          onTap: onApple,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 17),
            decoration: BoxDecoration(
              color: const Color(0xFFF0EDE6),
              borderRadius: BorderRadius.circular(50),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.apple, color: Colors.black, size: 20),
                const SizedBox(width: 10),
                const Text(
                  'Continue with Apple',
                  style: TextStyle(
                    color: Colors.black,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
              ],
            ),
          ),
        ).animate(delay: 380.ms).fadeIn(duration: 400.ms).slideY(begin: 0.06, end: 0),

        const SizedBox(height: 12),

        // Google | Email | Phone — three equal dark pills
        Row(
          children: [
            Expanded(
              child: _SmallPill(
                icon: _GoogleIcon(),
                label: 'Google',
                onTap: onGoogle,
                delay: 420,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SmallPill(
                icon: const Icon(Icons.mail_outline_rounded, size: 16, color: Color(0xFFD4C9B5)),
                label: 'Email',
                onTap: onEmail,
                delay: 460,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SmallPill(
                icon: const Icon(Icons.smartphone_rounded, size: 16, color: Color(0xFFD4C9B5)),
                label: 'Phone',
                onTap: onPhone,
                delay: 500,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SmallPill extends StatelessWidget {
  final Widget icon;
  final String label;
  final VoidCallback onTap;
  final int delay;

  const _SmallPill({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.delay,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: AymaColors.bgElev,
          borderRadius: BorderRadius.circular(50),
          border: Border.all(color: AymaColors.lineSoft, width: 0.5),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            icon,
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Color(0xFFD4C9B5),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    ).animate(delay: Duration(milliseconds: delay)).fadeIn(duration: 400.ms).slideY(begin: 0.06, end: 0);
  }
}

// ── Email form (shown after tapping Email) ────────────────────────────────────

class _EmailForm extends StatelessWidget {
  final TextEditingController emailCtrl, passCtrl;
  final bool isLogin, loading;
  final String? error;
  final VoidCallback onSubmit, onToggle, onBack;

  const _EmailForm({
    super.key,
    required this.emailCtrl,
    required this.passCtrl,
    required this.isLogin,
    required this.loading,
    required this.error,
    required this.onSubmit,
    required this.onToggle,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Back row
        GestureDetector(
          onTap: onBack,
          child: Row(
            children: [
              Icon(Icons.arrow_back_rounded, size: 18, color: AymaColors.fgMute),
              const SizedBox(width: 6),
              Text(
                isLogin ? 'Sign in with email' : 'Create account',
                style: AymaFonts.mono(size: 10, color: AymaColors.fgMute),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // Email field
        _AuthField(controller: emailCtrl, label: 'Email', keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 10),

        // Password field
        _AuthField(controller: passCtrl, label: 'Password', obscure: true, onSubmitted: (_) => onSubmit()),

        if (error != null) ...[
          const SizedBox(height: 10),
          Text(
            error!,
            style: TextStyle(color: Colors.redAccent.shade100, fontSize: 13),
          ).animate().fadeIn(),
        ],

        const SizedBox(height: 16),

        // Submit
        GestureDetector(
          onTap: loading ? null : onSubmit,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 17),
            decoration: BoxDecoration(
              color: AymaColors.fg,
              borderRadius: BorderRadius.circular(50),
            ),
            child: Center(
              child: loading
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : Text(
                      isLogin ? 'Sign in' : 'Create account',
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
            ),
          ),
        ),

        const SizedBox(height: 14),

        Center(
          child: GestureDetector(
            onTap: onToggle,
            child: Text(
              isLogin ? "Don't have an account? Sign up" : 'Already have an account? Sign in',
              style: TextStyle(color: AymaColors.fgMute, fontSize: 13),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Email sent ────────────────────────────────────────────────────────────────

class _EmailSentCard extends StatelessWidget {
  final String email;
  const _EmailSentCard({required this.email});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AymaColors.bgElev,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AymaColors.accent.withValues(alpha: 0.25), width: 0.5),
      ),
      child: Row(
        children: [
          Icon(Icons.mark_email_unread_outlined, color: AymaColors.accent, size: 24),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Check your inbox',
                    style: TextStyle(color: AymaColors.fg, fontSize: 14, fontWeight: FontWeight.w500)),
                const SizedBox(height: 3),
                Text('Confirmation link sent to $email',
                    style: TextStyle(color: AymaColors.fgDim, fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.06, end: 0);
  }
}

// ── Auth text field ───────────────────────────────────────────────────────────

class _AuthField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool obscure;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onSubmitted;

  const _AuthField({
    required this.controller,
    required this.label,
    this.obscure = false,
    this.keyboardType,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AymaColors.bgElev,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AymaColors.lineSoft, width: 0.5),
      ),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        onSubmitted: onSubmitted,
        style: TextStyle(color: AymaColors.fg, fontSize: 15),
        decoration: InputDecoration(
          hintText: label,
          hintStyle: TextStyle(color: AymaColors.fgMute, fontSize: 15),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
    );
  }
}

// ── Static orb (auth screen splash) ──────────────────────────────────────────

class _StaticOrb extends StatefulWidget {
  @override
  State<_StaticOrb> createState() => _StaticOrbState();
}

class _StaticOrbState extends State<_StaticOrb> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _breathe;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200))
      ..repeat(reverse: true);
    _breathe = Tween<double>(begin: 0.93, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _breathe,
      builder: (_, __) {
        return SizedBox(
          width: 180,
          height: 180,
          child: CustomPaint(
            painter: _OrbPainter(breathe: _breathe.value),
          ),
        );
      },
    );
  }
}

class _OrbPainter extends CustomPainter {
  final double breathe;
  _OrbPainter({required this.breathe});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 * breathe;

    // Outer glow ring
    final ringPaint = Paint()
      ..color = const Color(0xFFC48312).withValues(alpha: 0.06)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18);
    canvas.drawCircle(center, r * 1.18, ringPaint);

    // Subtle border ring
    final borderPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = const Color(0xFFC48312).withValues(alpha: 0.15);
    canvas.drawCircle(center, r * 1.08, borderPaint);

    // Orb body
    final gradient = RadialGradient(
      center: const Alignment(-0.25, -0.35),
      radius: 0.8,
      colors: const [
        Color(0xFFEDD5A8), // warm highlight
        Color(0xFFC48312), // amber mid
        Color(0xFF6B3A0C), // deep amber
        Color(0xFF2A1505), // near-black edge
      ],
      stops: const [0.0, 0.35, 0.70, 1.0],
    );
    final orbPaint = Paint()
      ..shader = gradient.createShader(Rect.fromCircle(center: center, radius: r));
    canvas.drawCircle(center, r, orbPaint);
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.breathe != breathe;
}

// ── Google icon (coloured G) ──────────────────────────────────────────────────

class _GoogleIcon extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16, height: 16,
      child: CustomPaint(painter: _GooglePainter()),
    );
  }
}

class _GooglePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // Simple coloured G approximation
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    final colors = [
      const Color(0xFF4285F4),
      const Color(0xFF34A853),
      const Color(0xFFFBBC05),
      const Color(0xFFEA4335),
    ];
    final sweeps = [90.0, 90.0, 90.0, 90.0];
    double start = -30;
    for (int i = 0; i < 4; i++) {
      final paint = Paint()
        ..color = colors[i]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r - 1),
        start * (3.14159 / 180),
        sweeps[i] * (3.14159 / 180),
        false,
        paint,
      );
      start += sweeps[i];
    }
  }

  @override
  bool shouldRepaint(_GooglePainter _) => false;
}
