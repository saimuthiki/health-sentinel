import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';
import '../common/api_waking_notice.dart';
import '../common/consent_routing.dart';
import '../common/failure_copy.dart';

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

  /// Sign in, then send the person to the first thing they have not finished.
  ///
  /// The controller wraps the call in `AsyncValue.guard`, so this never throws
  /// and the busy state is the provider's own - there is no flag here that can
  /// be left stuck. What it does own is where a *refused* sign-in goes.
  ///
  /// Supabase can accept the password and the backend can still refuse the
  /// account, and until now that refusal ended here, on a screen with nowhere
  /// to go. When the refusal is about consent it is not an error at all: it is
  /// an unfinished step, and the answer is the consent screen. See
  /// `features/common/consent_routing.dart` for the bare-403 case.
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

    final AsyncValue<AuthSession?> result = ref.read(sessionControllerProvider);
    final Object? failure = result.hasError ? result.error : null;
    if (failure != null) {
      // The session never loaded, so the app has no evidence either way about
      // whether consent was recorded for this account.
      final String? route =
          consentRouteFor(failure, consentAlreadyRecorded: false);
      if (route != null) {
        context.go(route);
      }
      // Anything else stays here with the sentence already on screen: the
      // password really may be wrong, and moving somebody off the screen that
      // can fix it would be worse than showing it.
      return;
    }

    final AuthSession? session = result.value;
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
                    // Signing in is a backend call too, so it can be the
                    // request that pays for the cold start.
                    const ApiWakingNotice(),
                    if (error != null) ...<Widget>[
                      Padding(
                        padding: const EdgeInsets.only(bottom: HpSpacing.lg),
                        child: Semantics(
                          liveRegion: true,
                          container: true,
                          child: Text(
                            // Never `error.toString()`: that prints whatever
                            // the exception felt like printing, which for
                            // anything but our own failures is a message
                            // written for a developer.
                            explainFailure(
                              error,
                              fallback: 'We could not sign you in just now. '
                                  'Check the email and password, or try again '
                                  'in a moment.',
                            ),
                            style: HpType.label.copyWith(color: p.urgentInk),
                          ),
                        ),
                      ),
                    ],
                    HpButton(
                      label: 'Sign in',
                      busy: session.isLoading,
                      onPressed: session.isLoading ? null : _submit,
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
