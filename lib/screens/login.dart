import 'dart:async';
import 'package:flutter/material.dart';
import '../core/app_state.dart';
import '../core/friendly_errors.dart';
import '../core/api/driver_api.dart';
import '../core/widgets.dart';
import '../core/push_service.dart';
import 'main_shell.dart';
import 'registration.dart';

/// Driver sign-in with a one-time code, by SMS (phone) or email:
/// POST /auth/driver/send-otp { phone | email, purpose: "login" }
/// POST /auth/driver/login    { phone | email, code }
class DriverLoginScreen extends StatefulWidget {
  const DriverLoginScreen({super.key});
  @override
  State<DriverLoginScreen> createState() => _DriverLoginScreenState();
}

class _DriverLoginScreenState extends State<DriverLoginScreen> {
  final email = TextEditingController();
  final phone = TextEditingController();
  final otp = TextEditingController();
  bool usePhone = true;
  String dial = '+255';
  String currentEmail = '';
  String currentPhone = '';
  bool sent = false;
  bool loading = false;
  int seconds = 0;
  Timer? timer;


  @override
  void dispose() {
    email.dispose();
    phone.dispose();
    otp.dispose();
    timer?.cancel();
    super.dispose();
  }

  String? _validatedEmail() {
    final value = email.text.trim().toLowerCase();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)) {
      toast(context, 'Enter a valid email address.');
      return null;
    }
    return value;
  }

  /// +255 + local digits (a leading 0 is dropped). A number typed with its own + is kept.
  String? _validatedPhone() {
    final raw = phone.text.trim();
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 7) {
      toast(context, AppScope.of(context).t('Enter a valid phone number.', 'Ingiza namba sahihi ya simu.'));
      return null;
    }
    if (raw.startsWith('+')) return '+$digits';
    return '$dial${digits.replaceFirst(RegExp(r'^0+'), '')}';
  }

  Future<void> send() async {
    if (loading) return;
    setState(() => loading = true);
    try {
      if (usePhone) {
        final number = _validatedPhone();
        if (number == null) return;
        await DriverApi.sendOtp(phone: number, purpose: 'login');
        currentPhone = number;
        if (!mounted) return;
        setState(() => sent = true);
        start();
        toast(context, AppScope.of(context).t('Code sent by SMS to $number.', 'Nambari imetumwa kwa SMS kwenda $number.'));
      } else {
        final validEmail = _validatedEmail();
        if (validEmail == null) return;
        final response = await DriverApi.sendOtp(email: validEmail, purpose: 'login');
        currentEmail = (response['target'] ?? validEmail).toString();
        if (!mounted) return;
        setState(() => sent = true);
        start();
        toast(context, 'OTP sent to $currentEmail.');
      }
    } catch (e) {
      if (mounted) toast(context, FriendlyErrors.message(e, swahili: AppScope.of(context).isSwahili));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void start() {
    timer?.cancel();
    setState(() => seconds = 60);
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || seconds <= 1) {
        t.cancel();
        if (mounted) setState(() => seconds = 0);
        return;
      }
      setState(() => seconds--);
    });
  }

  Future<void> verify() async {
    if (loading) return;
    final code = otp.text.trim();
    if (code.length < 4) {
      toast(context, 'Enter the OTP.');
      return;
    }
    setState(() => loading = true);
    try {
      final data = usePhone
          ? await DriverApi.login(phone: currentPhone, code: code)
          : await DriverApi.login(email: currentEmail, code: code);
      if (!mounted) return;
      await AppScope.of(context).login(data);
      await PushService.instance.registerTokenNow();
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const MainShell()),
        );
      }
    } catch (e) {
      if (mounted) toast(context, FriendlyErrors.message(e, swahili: AppScope.of(context).isSwahili));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void backToDetails() {
    timer?.cancel();
    setState(() {
      sent = false;
      seconds = 0;
      otp.clear();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(AppScope.of(context).t('Driver sign in', 'Ingia kama dereva'))),
        body: ResponsivePage(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              Text(AppScope.of(context).t('Welcome back', 'Karibu tena'), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900)),
              const SizedBox(height: 8),
              Text(AppScope.of(context).t('Sign in with a one-time code sent by SMS or email.', 'Ingia kwa nambari ya mara moja inayotumwa kwa SMS au barua pepe.')),
              const SizedBox(height: 24),
              if (!sent) ...[
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(value: true, icon: const Icon(Icons.sms_outlined), label: Text(AppScope.of(context).t('Phone (SMS)', 'Simu (SMS)'))),
                    ButtonSegment(value: false, icon: const Icon(Icons.email_outlined), label: Text(AppScope.of(context).t('Email', 'Barua pepe'))),
                  ],
                  selected: {usePhone},
                  onSelectionChanged: (v) => setState(() => usePhone = v.first),
                ),
                const SizedBox(height: 16),
                if (usePhone)
                  TextField(
                    controller: phone,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.telephoneNumber],
                    decoration: InputDecoration(labelText: AppScope.of(context).t('Phone number', 'Namba ya simu'), prefixIcon: const Icon(Icons.phone_outlined), prefixText: '$dial ', hintText: '7XX XXX XXX'),
                  )
                else
                TextField(
                  controller: email,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'Email address', prefixIcon: Icon(Icons.email_outlined), hintText: 'you@example.com'),
                ),
                const SizedBox(height: 16),
                LoadingButton(label: usePhone ? AppScope.of(context).t('Send code by SMS', 'Tuma nambari kwa SMS') : AppScope.of(context).t('Send email OTP', 'Tuma OTP kwa barua pepe'), onPressed: send),
              ] else ...[
                Text(AppScope.of(context).t(usePhone ? 'SMS code sent to' : 'Email code sent to', 'Nambari imetumwa kwa') + ' ${usePhone ? currentPhone : _maskedEmail(currentEmail)}'),
                const SizedBox(height: 12),
                TextField(
                  controller: otp,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  maxLength: 8,
                  decoration: const InputDecoration(labelText: 'OTP code', counterText: ''),
                  onSubmitted: (_) => verify(),
                ),
                const SizedBox(height: 8),
                Text(seconds > 0 ? 'Resend in $seconds s' : 'You can resend the OTP.'),
                const SizedBox(height: 12),
                LoadingButton(label: 'Verify & sign in', onPressed: verify),
                TextButton(onPressed: loading || seconds > 0 ? null : send, child: Text(AppScope.of(context).t('Resend OTP', 'Tuma OTP tena'))),
                TextButton(onPressed: loading ? null : backToDetails, child: Text(usePhone ? AppScope.of(context).t('Change number', 'Badilisha namba') : AppScope.of(context).t('Change email', 'Badilisha barua pepe'))),
              ],
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RegistrationScreen())),
                child: Text(AppScope.of(context).t('Register as a driver', 'Jisajili kama dereva')),
              ),
            ],
          ),
        ),
      );

  String _maskedEmail(String value) {
    final parts = value.split('@');
    if (parts.length != 2 || parts[0].length < 2) return value;
    return '${parts[0][0]}***${parts[0][parts[0].length - 1]}@${parts[1]}';
  }
}
