import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';

/// Signing in, and the app's one-line pitch above it.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    await ref.read(sessionControllerProvider.notifier).signIn(
          email: _email.text.trim(),
          password: _password.text,
        );
    if (!mounted) {
      return;
    }
    final AuthSession? session = ref.read(sessionControllerProvider).value;
    if (session == null) {
      return;
    }
    if (!session.hasAcceptedConsent) {
      context.go('/consent');
    } else if (!session.hasCompletedProfile) {
      context.go('/profile');
    } else {
      context.go('/today');
    }
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final AsyncValue<AuthSession?> session =
        ref.watch(sessionControllerProvider);
    final Object? error = session.hasError ? session.error : null;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(
              HpSpacing.gutter,
              HpSpacing.section,
              HpSpacing.gutter,
              HpSpacing.section,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const HpMark(size: 52),
                    const SizedBox(height: HpSpacing.xl),
                    Text(
                      'Your reports, turned into what to do today',
                      style: HpType.display.copyWith(color: p.ink),
                    ),
                    const SizedBox(height: HpSpacing.md),
                    Text(
                      'HealthPulse reads your lab reports and your habits, and '
                      'builds a day of food, water, movement and sleep around '
                      'them. It tells you plainly when something needs a doctor.',
                      style: HpType.reading.copyWith(color: p.inkMuted),
                    ),
                    const SizedBox(height: HpSpacing.section),
                    HpField(
                      label: 'Email',
                      child: TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const <String>[AutofillHints.email],
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          hintText: 'you@example.com',
                        ),
                        validator: (String? value) {
                          if (value == null || !value.contains('@')) {
                            return 'Enter the email you signed up with.';
                          }
                          return null;
                        },
                      ),
                    ),
                    HpField(
                      label: 'Password',
                      child: TextFormField(
                        controller: _password,
                        obscureText: _obscure,
                        autofillHints: const <String>[AutofillHints.password],
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (String _) => _submit(),
                        decoration: InputDecoration(
                          hintText: 'At least 8 characters',
                          suffixIcon: IconButton(
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                            tooltip: _obscure ? 'Show password' : 'Hide password',
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),
                        validator: (String? value) {
                          if (value == null || value.length < 8) {
                            return 'Passwords are at least 8 characters.';
                          }
                          return null;
                        },
                      ),
                    ),
                    if (error != null) ...<Widget>[
                      Padding(
                        padding: const EdgeInsets.only(bottom: HpSpacing.lg),
                        child: Text(
                          error.toString(),
                          style: HpType.label.copyWith(color: p.urgentInk),
                        ),
                      ),
                    ],
                    HpButton(
                      label: 'Sign in',
                      busy: session.isLoading,
                      onPressed: _submit,
                    ),
                    const SizedBox(height: HpSpacing.md),
                    HpButton(
                      label: 'Create an account',
                      tone: HpButtonTone.secondary,
                      onPressed: () => context.go('/sign-up'),
                    ),
                    const SizedBox(height: HpSpacing.xl),
                    Row(
                      children: <Widget>[
                        Icon(Icons.shield_outlined, size: 16, color: p.inkFaint),
                        const SizedBox(width: HpSpacing.sm),
                        Expanded(
                          child: Text(
                            'A coach, not a doctor. Your health data stays yours, '
                            'and you can delete all of it at any time.',
                            style: HpType.micro.copyWith(color: p.inkFaint),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
