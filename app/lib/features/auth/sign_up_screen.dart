import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/hp_palette.dart';
import '../../core/theme/hp_spacing.dart';
import '../../core/theme/hp_typography.dart';
import '../../core/widgets/widgets.dart';
import '../../data/models/models.dart';
import '../../data/providers.dart';

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});

  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    await ref.read(sessionControllerProvider.notifier).signUp(
          email: _email.text.trim(),
          password: _password.text,
          displayName: _name.text.trim(),
        );
    if (!mounted) {
      return;
    }
    if (ref.read(sessionControllerProvider).value != null) {
      context.go('/consent');
    }
  }

  @override
  Widget build(BuildContext context) {
    final HpPalette p = context.hp;
    final AsyncValue<AuthSession?> session =
        ref.watch(sessionControllerProvider);
    final Object? error = session.hasError ? session.error : null;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Back to sign in',
          onPressed: () => context.go('/welcome'),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            HpSpacing.gutter,
            HpSpacing.lg,
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
                  Text(
                    'Create your account',
                    style: HpType.display.copyWith(color: p.ink),
                  ),
                  const SizedBox(height: HpSpacing.md),
                  Text(
                    'Next you will read what HealthPulse is and is not, then set '
                    'up your profile. It takes about three minutes.',
                    style: HpType.reading.copyWith(color: p.inkMuted),
                  ),
                  const SizedBox(height: HpSpacing.section),
                  HpField(
                    label: 'What should we call you?',
                    helper: 'Used in your daily greeting, nothing else.',
                    child: TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(hintText: 'Sai'),
                      validator: (String? value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Add a name so the app can greet you.';
                        }
                        return null;
                      },
                    ),
                  ),
                  HpField(
                    label: 'Email',
                    child: TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        hintText: 'you@example.com',
                      ),
                      validator: (String? value) {
                        if (value == null || !value.contains('@')) {
                          return 'Enter an email you can receive post at.';
                        }
                        return null;
                      },
                    ),
                  ),
                  HpField(
                    label: 'Password',
                    helper: 'At least 8 characters.',
                    child: TextFormField(
                      controller: _password,
                      obscureText: true,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (String _) => _submit(),
                      decoration: const InputDecoration(
                        hintText: 'At least 8 characters',
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
                    label: 'Create account',
                    busy: session.isLoading,
                    onPressed: _submit,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
