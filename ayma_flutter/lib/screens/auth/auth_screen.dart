import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/providers.dart';
import '../../theme.dart';
import '../../widgets/ayma_button.dart';
import '../../widgets/ayma_text_field.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});

  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _emailCtrl  = TextEditingController();
  final _passCtrl   = TextEditingController();
  bool _isLogin     = true;
  bool _loading     = false;
  String? _error;
  bool _emailSent   = false;

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
        final signedIn = await ref.read(authControllerProvider).signIn(
              _emailCtrl.text.trim(),
              _passCtrl.text,
            );
        if (!signedIn) {
          throw Exception('Login did not return a session.');
        }
        if (mounted) context.go('/chat');
      } else {
        final signedIn = await ref.read(authControllerProvider).signUp(
              _emailCtrl.text.trim(),
              _passCtrl.text,
            );
        if (mounted) {
          if (signedIn) {
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
    if (mounted) setState(() { _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AymaColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(flex: 2),

              // Logo / wordmark
              Text(
                'ayma',
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  color: AymaColors.accent,
                  letterSpacing: -2,
                  fontWeight: FontWeight.w700,
                ),
              ).animate().fadeIn(duration: 600.ms).slideY(begin: -0.2, end: 0),

              const SizedBox(height: 8),
              Text(
                _isLogin ? 'Welcome back.' : 'Create your account.',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AymaColors.textSecondary,
                ),
              ).animate(delay: 100.ms).fadeIn(duration: 400.ms),

              const Spacer(flex: 1),

              if (_emailSent) ...[
                _EmailSentState(email: _emailCtrl.text.trim()),
              ] else ...[
                AymaTextField(
                  controller: _emailCtrl,
                  label: 'Email',
                  keyboardType: TextInputType.emailAddress,
                ).animate(delay: 200.ms).fadeIn(duration: 400.ms).slideY(begin: 0.1, end: 0),

                const SizedBox(height: 14),

                AymaTextField(
                  controller: _passCtrl,
                  label: 'Password',
                  obscureText: true,
                  onSubmitted: (_) => _submit(),
                ).animate(delay: 280.ms).fadeIn(duration: 400.ms).slideY(begin: 0.1, end: 0),

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(color: Colors.redAccent.shade100, fontSize: 13),
                  ).animate().fadeIn(),
                ],

                const SizedBox(height: 24),

                AymaButton(
                  label: _isLogin ? 'Sign in' : 'Create account',
                  loading: _loading,
                  onPressed: _submit,
                ).animate(delay: 360.ms).fadeIn(duration: 400.ms).slideY(begin: 0.1, end: 0),

                const SizedBox(height: 16),

                Center(
                  child: TextButton(
                    onPressed: () => setState(() {
                      _isLogin = !_isLogin;
                      _error = null;
                    }),
                    child: Text(
                      _isLogin
                          ? "Don't have an account? Sign up"
                          : 'Already have an account? Sign in',
                      style: TextStyle(
                        color: AymaColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ).animate(delay: 440.ms).fadeIn(duration: 400.ms),
              ],

              const Spacer(flex: 3),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmailSentState extends StatelessWidget {
  final String email;
  const _EmailSentState({required this.email});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AymaColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AymaColors.accent.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              Icon(Icons.mark_email_unread_outlined,
                  color: AymaColors.accent, size: 28),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Check your inbox',
                        style: TextStyle(
                            color: AymaColors.textPrimary,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text('We sent a confirmation link to $email',
                        style: TextStyle(
                            color: AymaColors.textSecondary, fontSize: 13)),
                  ],
                ),
              ),
            ],
          ),
        ).animate().fadeIn(duration: 500.ms).slideY(begin: 0.1, end: 0),
      ],
    );
  }
}
