import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/api/driver_api.dart';
import '../core/app_state.dart';
import '../core/format.dart';
import '../core/friendly_errors.dart';
import '../core/theme.dart';
import '../core/widgets.dart';

const double _kGap = 14; // vertical space between big blocks
const double _kPagePad = 16;

Color _muted(BuildContext c) => Theme.of(c).colorScheme.onSurface.withValues(alpha: .62);

/// A consistently padded surface used by every block on this screen.
class _Block extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const _Block({required this.child, this.padding = const EdgeInsets.all(18)});
  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: padding, child: child));
}

Widget _iconBubble(BuildContext context, IconData icon, {Color? color}) {
  final c = color ?? Theme.of(context).colorScheme.primary;
  return Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(color: c.withValues(alpha: .14), shape: BoxShape.circle),
    child: Icon(icon, color: c, size: 22),
  );
}

List<Widget> _spaced(List<Widget> items, {double gap = 12}) {
  final out = <Widget>[];
  for (var i = 0; i < items.length; i++) {
    if (i > 0) out.add(SizedBox(height: gap));
    out.add(items[i]);
  }
  return out;
}

(String, Color) _payoutStatus(AppState s, String status) {
  switch (status) {
    case 'paid':
      return (s.t('Paid', 'Imelipwa'), ZenjiColors.green);
    case 'approved':
      return (s.t('Approved', 'Imeidhinishwa'), ZenjiColors.skyBlue);
    case 'rejected':
      return (s.t('Rejected', 'Imekataliwa'), ZenjiColors.error);
    default:
      return (s.t('Pending', 'Inasubiri'), ZenjiColors.darkHighlight);
  }
}

Widget _payoutTile(BuildContext context, AppState s, Map<String, dynamic> p) {
  final status = (p['status'] ?? 'pending').toString();
  final (label, tone) = _payoutStatus(s, status);
  final isBank = (p['method'] ?? '').toString() == 'bank';
  final method = isBank ? s.t('Bank transfer', 'Benki') : s.t('Mobile money', 'Pesa ya simu');
  final account = (p['account'] ?? '').toString();
  final note = (p['adminNote'] ?? '').toString();
  return _Block(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        _iconBubble(context, isBank ? Icons.account_balance_outlined : Icons.phone_android_rounded, color: tone),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(Fmt.tzs(Fmt.parse(p['amount'])), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
            const SizedBox(height: 2),
            Text(
              [method, if (account.isNotEmpty) account, Fmt.date(p['createdAt'])].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: _muted(context), fontSize: 12),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        Pill(label, color: tone),
      ]),
      if (status == 'rejected' && note.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text('${s.t('Reason', 'Sababu')}: $note', style: TextStyle(color: _muted(context), fontSize: 12.5)),
      ],
    ]),
  );
}

class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key});
  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  bool loading = true;
  bool _loadedOnce = false;
  int _lastNav = -1;
  String? error;
  Map<String, dynamic> finance = {};
  Map<String, dynamic> earnings = {};
  Map<String, dynamic>? payoutInfo;
  List<dynamic> rides = [];
  List<dynamic> settlements = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Tabs live in an IndexedStack, so refresh whenever the driver opens this tab.
    final nav = AppScope.of(context).navIndex;
    if (nav == 1 && _lastNav != 1 && _loadedOnce) _load(silent: true);
    _lastNav = nav;
  }

  num _n(Map m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v != null) return Fmt.parse(v);
    }
    return 0;
  }

  Future<void> _load({bool silent = false}) async {
    if (mounted && !silent) setState(() { loading = true; error = null; });
    try {
      final results = await Future.wait<dynamic>([
        DriverApi.finance(),
        DriverApi.earnings(),
        DriverApi.history(limit: 30),
        DriverApi.settlements(),
        DriverApi.payouts(),
      ]);
      if (!mounted) return;
      setState(() {
        finance = Map<String, dynamic>.from(results[0] as Map);
        earnings = Map<String, dynamic>.from(results[1] as Map);
        rides = List<dynamic>.from(results[2] as List);
        settlements = List<dynamic>.from(results[3] as List);
        payoutInfo = results[4] == null ? null : Map<String, dynamic>.from(results[4] as Map);
        loading = false;
        error = null;
        _loadedOnce = true;
      });
      final app = AppScope.of(context);
      app.refreshFinance();
      app.refreshProfile();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (!silent || !_loadedOnce) error = FriendlyErrors.message(e, swahili: AppScope.of(context).isSwahili);
        loading = false;
      });
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    final f = finance.isNotEmpty ? finance : (s.finance ?? <String, dynamic>{});
    final profile = s.profile ?? <String, dynamic>{};

    final profileBalance = _n(profile, ['total_earnings', 'totalEarnings', 'available_balance', 'availableBalance']);
    final num available = payoutInfo != null ? Fmt.parse(payoutInfo!['available']) : profileBalance;
    final num lifetime = payoutInfo != null ? Fmt.parse(payoutInfo!['totalEarnings']) : profileBalance;
    final num pendingPayout = payoutInfo != null ? Fmt.parse(payoutInfo!['pending']) : 0;
    final last30 = _n(earnings, ['total', 'totalEarnings']);

    final owed = _n(f, ['commission_owed', 'commissionOwed']);
    final gross = _n(f, ['gross_since_settlement', 'grossSinceSettlement']);
    final threshold = _n(f, ['threshold']);
    final rate = _n(f, ['commissionRate', 'commission_rate']);
    final blocked = f['blocked'] == true || f['blocked'] == 1;
    final autopay = f['autopay_enabled'] == true || f['autopay_enabled'] == 1 || f['autopayEnabled'] == true;
    final active = f['activeSettlement'] is Map ? Map<String, dynamic>.from(f['activeSettlement'] as Map) : null;
    final days = (earnings['days'] is List) ? List<dynamic>.from(earnings['days'] as List) : <dynamic>[];
    final payoutRows = (payoutInfo?['requests'] is List) ? List<dynamic>.from(payoutInfo!['requests'] as List) : <dynamic>[];

    final children = <Widget>[
      Row(children: [
        Expanded(
          child: Text(
            s.t('Earnings & Wallet', 'Mapato na Pochi'),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        IconButton.filledTonal(
          tooltip: s.t('History', 'Historia'),
          onPressed: () => _showHistory(context, payoutRows),
          icon: const Icon(Icons.history_rounded),
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: s.t('Refresh', 'Onyesha upya'),
          onPressed: loading ? null : _load,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ]),
      if (loading) const Padding(padding: EdgeInsets.only(top: 6), child: LinearProgressIndicator(minHeight: 3)),
      if (error != null) ...[
        const SizedBox(height: _kGap),
        _Block(
          child: Row(children: [
            const Icon(Icons.cloud_off_outlined, color: ZenjiColors.error),
            const SizedBox(width: 12),
            Expanded(child: Text(error!, style: const TextStyle(fontWeight: FontWeight.w600))),
            TextButton(onPressed: _load, child: Text(s.t('Retry', 'Jaribu tena'))),
          ]),
        ),
      ],
      const SizedBox(height: _kGap),
      _buildBalanceCard(context, s, cs, available: available, lifetime: lifetime, pending: pendingPayout, last30: last30),
      const SizedBox(height: _kGap),
      _buildSettlementCard(context, s, cs,
          owed: owed, gross: gross, threshold: threshold, rate: rate, blocked: blocked, autopay: autopay, active: active),
      const SizedBox(height: 24),
      if (payoutRows.isNotEmpty) ...[
        SectionTitle(
          s.t('Payout requests', 'Maombi ya malipo'),
          action: payoutRows.length > 3 ? s.t('See all', 'Ona yote') : null,
          onAction: () => _showHistory(context, payoutRows),
        ),
        ..._spaced(payoutRows.take(3).map((row) => _payoutTile(context, s, Map<String, dynamic>.from(row as Map))).toList()),
        const SizedBox(height: 24),
      ],
      SectionTitle(s.t('Earnings by day', 'Mapato kwa siku')),
      if (days.isEmpty && !loading)
        _Block(
          child: EmptyState(
            icon: Icons.payments_outlined,
            title: s.t('No earnings yet', 'Bado hakuna mapato'),
            subtitle: s.t('Complete a ride and your daily earnings will show up here.', 'Kamilisha safari na mapato yako ya kila siku yataonekana hapa.'),
          ),
        ),
      ..._spaced(days.map((row) => _dayTile(context, s, Map<String, dynamic>.from(row as Map))).toList()),
      const SizedBox(height: 24),
      SectionTitle(s.t('Recent rides', 'Safari za hivi karibuni')),
      if (rides.isEmpty && !loading)
        _Block(
          child: EmptyState(
            icon: Icons.route_outlined,
            title: s.t('No rides yet', 'Bado hakuna safari'),
            subtitle: s.t('Your completed and cancelled rides will be listed here.', 'Safari ulizokamilisha au kughairi zitaorodheshwa hapa.'),
          ),
        ),
      ..._spaced(rides.take(10).map((row) => _rideTile(context, s, Map<String, dynamic>.from(row as Map))).toList()),
      const SizedBox(height: 24),
    ];

    return SafeArea(
      bottom: false,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(_kPagePad, 12, _kPagePad, 12),
              children: children,
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------- balance card

  Widget _buildBalanceCard(
    BuildContext context,
    AppState s,
    ColorScheme cs, {
    required num available,
    required num lifetime,
    required num pending,
    required num last30,
  }) {
    final canWithdraw = available > 0;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [cs.primary.withValues(alpha: .24), cs.surface],
        ),
        border: Border.all(color: cs.primary.withValues(alpha: .28)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          s.t('Available to withdraw', 'Salio linaloweza kutolewa'),
          style: TextStyle(color: _muted(context), fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text('TZS ', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _muted(context))),
            Text(
              Fmt.money(available),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 38),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _miniStat(context, s.t('Last 30 days', 'Siku 30 zilizopita'), Fmt.tzs(last30))),
          _vDivider(context),
          Expanded(child: _miniStat(context, s.t('Pending payout', 'Inasubiri malipo'), Fmt.tzs(pending))),
          _vDivider(context),
          Expanded(child: _miniStat(context, s.t('Lifetime earned', 'Jumla ya mapato'), Fmt.tzs(lifetime))),
        ]),
        const SizedBox(height: 18),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
            onPressed: canWithdraw
                ? () async {
                    final done = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(builder: (_) => WithdrawScreen(available: available, pending: pending)),
                    );
                    if (done == true) _load();
                  }
                : null,
            icon: const Icon(Icons.account_balance_wallet_outlined),
            label: Text(s.t('Request payout', 'Omba malipo'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
          ),
        ),
        if (!canWithdraw) ...[
          const SizedBox(height: 10),
          Text(
            pending > 0
                ? s.t('Your earnings are already covered by pending payout requests.', 'Mapato yako yote tayari yako kwenye maombi ya malipo yanayosubiri.')
                : s.t('Complete rides to build a balance you can withdraw.', 'Kamilisha safari ili upate salio la kutoa.'),
            style: TextStyle(color: _muted(context), fontSize: 12.5),
          ),
        ],
      ]),
    );
  }

  Widget _miniStat(BuildContext context, String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _muted(context), fontSize: 11.5)),
        const SizedBox(height: 3),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
        ),
      ]);

  Widget _vDivider(BuildContext context) => Container(
        width: 1,
        height: 30,
        margin: const EdgeInsets.symmetric(horizontal: 10),
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .12),
      );

  // ------------------------------------------------------ settlement card

  Widget _buildSettlementCard(
    BuildContext context,
    AppState s,
    ColorScheme cs, {
    required num owed,
    required num gross,
    required num threshold,
    required num rate,
    required bool blocked,
    required bool autopay,
    required Map<String, dynamic>? active,
  }) {
    final due = owed > 0;
    final Color tone = blocked ? ZenjiColors.error : (due ? ZenjiColors.darkHighlight : ZenjiColors.green);
    final statusText = blocked
        ? s.t('Restricted', 'Imezuiwa')
        : (due ? s.t('Payment due', 'Malipo yanadaiwa') : s.t('Up to date', 'Imekamilika'));
    final progress = threshold > 0 ? (gross / threshold).clamp(0.0, 1.0).toDouble() : 0.0;

    return _Block(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(color: cs.primary.withValues(alpha: .14), borderRadius: BorderRadius.circular(12)),
            child: Icon(Icons.account_balance_outlined, size: 20, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(s.t('ZenjiGO commission', 'Kamisheni ya ZenjiGO'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          ),
          Pill(statusText, color: tone),
        ]),
        const SizedBox(height: 16),
        if (due) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: tone.withValues(alpha: .12), borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.t('Commission to pay', 'Kamisheni ya kulipa'), style: TextStyle(color: _muted(context), fontSize: 12.5)),
              const SizedBox(height: 2),
              Text(Fmt.tzs(owed), style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22, color: tone)),
              const SizedBox(height: 4),
              Text(
                s.t('Pay it to keep receiving ride requests.', 'Lipa ili uendelee kupokea maombi ya safari.'),
                style: TextStyle(color: _muted(context), fontSize: 12.5),
              ),
            ]),
          ),
          const SizedBox(height: 16),
        ],
        if (threshold > 0) ...[
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Flexible(child: Text(s.t('Fares since last settlement', 'Nauli tangu malipo ya mwisho'), style: TextStyle(color: _muted(context), fontSize: 12.5))),
            const SizedBox(width: 8),
            Text('${Fmt.money(gross)} / ${Fmt.money(threshold)}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5)),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: cs.onSurface.withValues(alpha: .10),
              valueColor: AlwaysStoppedAnimation<Color>(progress >= 1 ? ZenjiColors.error : (progress >= .8 ? ZenjiColors.darkHighlight : cs.primary)),
            ),
          ),
          const SizedBox(height: 16),
        ],
        _kv(context, s.t('Commission rate', 'Kiwango cha kamisheni'), '${Fmt.money(rate)}%'),
        _kv(context, s.t('Settlement threshold', 'Kiwango cha malipo'), threshold > 0 ? Fmt.tzs(threshold) : '—'),
        if (active != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: cs.primary.withValues(alpha: .10), borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: cs.primary)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  s.t('A payment of ${Fmt.tzs(Fmt.parse(active['amount']))} is waiting for your approval on your phone.',
                      'Malipo ya ${Fmt.tzs(Fmt.parse(active['amount']))} yanasubiri idhini yako kwenye simu.'),
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(onPressed: () => _watchSettlement('${active['id']}'), child: Text(s.t('Check', 'Angalia'))),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        Divider(height: 1, color: cs.onSurface.withValues(alpha: .08)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.t('Autopay', 'Malipo ya kiotomatiki'), style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  autopay
                      ? s.t('Commission is paid automatically.', 'Kamisheni hulipwa kiotomatiki.')
                      : s.t('Turn on to pay commission automatically.', 'Washa ili kamisheni ilipwe kiotomatiki.'),
                  style: TextStyle(color: _muted(context), fontSize: 12),
                ),
              ]),
            ),
            Switch(value: autopay, onChanged: loading ? null : (v) => _toggleAutopay(v)),
          ]),
        ),
        if (due) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: tone,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
              onPressed: loading ? null : () => _payCommission(owed),
              icon: const Icon(Icons.payments_outlined),
              label: Text('${s.t('Pay commission', 'Lipa kamisheni')} · ${Fmt.tzs(owed)}', style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _kv(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(child: Text(label, style: TextStyle(color: _muted(context)))),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );

  // ----------------------------------------------------- settlement actions

  Future<String?> _askPhone(AppState s, String title, String message, String confirmLabel) async {
    final phoneCtrl = TextEditingController(text: (s.profile?['phone'] ?? '').toString());
    final phone = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(message),
          const SizedBox(height: 14),
          TextField(
            controller: phoneCtrl,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(labelText: s.t('Mobile money number', 'Namba ya simu ya pesa'), prefixIcon: const Icon(Icons.phone_android)),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: Text(s.t('Cancel', 'Ghairi'))),
          FilledButton(onPressed: () => Navigator.pop(d, phoneCtrl.text.trim()), child: Text(confirmLabel)),
        ],
      ),
    );
    phoneCtrl.dispose();
    if (phone == null || phone.isEmpty) return null;
    if (phone.replaceAll(RegExp(r'\D'), '').length < 9) {
      if (mounted) toast(context, s.t('Enter a valid mobile-money number.', 'Weka namba sahihi ya simu.'));
      return null;
    }
    return phone;
  }

  Future<void> _payCommission(num owed) async {
    final s = AppScope.of(context);
    final phone = await _askPhone(
      s,
      s.t('Pay commission', 'Lipa kamisheni'),
      s.t('${Fmt.tzs(owed)} will be charged to this mobile-money number. You will get a prompt on your phone — enter your PIN to approve.',
          '${Fmt.tzs(owed)} zitakatwa kwenye namba hii ya simu. Utapata ujumbe kwenye simu yako — weka PIN yako kuidhinisha.'),
      s.t('Pay now', 'Lipa sasa'),
    );
    if (phone == null || !mounted) return;
    try {
      final r = await DriverApi.settle(options: {'phone': phone});
      if (!mounted) return;
      if ((r['status'] ?? '').toString() == 'already_settled') {
        await _load();
        if (mounted) toast(context, s.t('Nothing to settle — you are up to date.', 'Hakuna cha kulipa — uko sawa.'));
        return;
      }
      final settlement = r['settlement'];
      final id = settlement is Map ? '${settlement['id']}' : '';
      if (id.isEmpty) {
        await _load();
        if (mounted) toast(context, (r['message'] ?? s.t('Confirm the payment prompt on your phone.', 'Thibitisha ujumbe wa malipo kwenye simu yako.')).toString());
        return;
      }
      await _watchSettlement(id);
    } catch (e) {
      if (mounted) toast(context, FriendlyErrors.message(e, swahili: s.isSwahili));
    }
  }

  Future<void> _watchSettlement(String id) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SettlementProgressDialog(settlementId: id),
    );
    if (mounted) _load();
  }

  Future<void> _toggleAutopay(bool enable) async {
    final s = AppScope.of(context);
    try {
      if (!enable) {
        await DriverApi.autopay(enabled: false);
        await _load();
        if (mounted) toast(context, s.t('Autopay turned off.', 'Malipo ya kiotomatiki yamezimwa.'));
        return;
      }
      final phone = await _askPhone(
        s,
        s.t('Enable autopay', 'Washa malipo ya kiotomatiki'),
        s.t('Enter the mobile-money number that will pay your commission automatically.', 'Weka namba ya simu itakayolipa kamisheni yako kiotomatiki.'),
        s.t('Enable', 'Washa'),
      );
      if (phone == null) return;
      final method = await DriverApi.addPaymentMethod({
        'provider': 'momo',
        'methodType': 'momo',
        'providerToken': 'momo:$phone',
        'phone': phone,
        'accountLabel': 'Autopay $phone',
        'maskedAccount': phone.length > 4 ? '****${phone.substring(phone.length - 4)}' : phone,
        'isAutopayDefault': true,
      });
      final token = (method['provider_token'] ?? method['providerToken'] ?? 'momo:$phone').toString();
      await DriverApi.autopay(enabled: true, provider: 'momo', providerToken: token);
      await _load();
      if (mounted) toast(context, s.t('Autopay enabled for $phone', 'Malipo ya kiotomatiki yamewashwa kwa $phone'));
    } catch (e) {
      if (mounted) toast(context, FriendlyErrors.message(e, swahili: s.isSwahili));
    }
  }

  // ------------------------------------------------------------- list tiles

  Widget _dayTile(BuildContext context, AppState s, Map<String, dynamic> d) {
    final rideCount = Fmt.parse(d['rides']).toInt();
    final share = _n(d, ['driver_share', 'driverShare']);
    final gross = _n(d, ['gross']);
    return _Block(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(children: [
        _iconBubble(context, Icons.calendar_today_rounded),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              Fmt.dayLabel(d['day'], today: s.t('Today', 'Leo'), yesterday: s.t('Yesterday', 'Jana')),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
            const SizedBox(height: 3),
            Text(
              '$rideCount ${rideCount == 1 ? s.t('ride', 'safari') : s.t('rides', 'safari')} · ${s.t('fares', 'nauli')} ${Fmt.tzs(gross)}',
              style: TextStyle(color: _muted(context), fontSize: 12.5),
            ),
          ]),
        ),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(Fmt.tzs(share), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 2),
          Text(s.t('you earned', 'ulipata'), style: TextStyle(color: _muted(context), fontSize: 11.5)),
        ]),
      ]),
    );
  }

  Widget _rideTile(BuildContext context, AppState s, Map<String, dynamic> r) {
    final status = (r['status'] ?? '').toString().toLowerCase();
    final completed = status == 'completed';
    final cancelled = status == 'cancelled' || status == 'canceled';
    final Color tone = completed ? ZenjiColors.green : (cancelled ? ZenjiColors.error : ZenjiColors.darkHighlight);
    final label = completed
        ? s.t('Completed', 'Imekamilika')
        : (cancelled ? s.t('Cancelled', 'Imeghairiwa') : (status.isEmpty ? '—' : '${status[0].toUpperCase()}${status.substring(1)}'));
    final amount = _n(r, ['final_fare', 'finalFare', 'estimated_fare', 'estimatedFare']);
    final code = (r['ride_code'] ?? r['rideCode'] ?? 'Ride ${r['id'] ?? ''}').toString();
    final pickup = (r['pickup_address'] ?? r['pickupAddress'] ?? '—').toString();
    final drop = (r['destination_address'] ?? r['destinationAddress'] ?? '—').toString();
    final when = Fmt.dateTime(r['completed_at'] ?? r['completedAt'] ?? r['created_at'] ?? r['createdAt']);
    final line = Theme.of(context).colorScheme.onSurface.withValues(alpha: .15);

    return _Block(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          _iconBubble(context, completed ? Icons.check_rounded : (cancelled ? Icons.close_rounded : Icons.timelapse_rounded), color: tone),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(code, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
              const SizedBox(height: 2),
              Text(when, style: TextStyle(color: _muted(context), fontSize: 12)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (completed) ...[
              Text(Fmt.tzs(amount), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              const SizedBox(height: 4),
            ],
            Pill(label, color: tone),
          ]),
        ]),
        const SizedBox(height: 14),
        _routeLine(Icons.trip_origin_rounded, Theme.of(context).colorScheme.primary, pickup),
        Padding(padding: const EdgeInsets.only(left: 8), child: Container(width: 2, height: 10, color: line)),
        _routeLine(Icons.location_on_rounded, ZenjiColors.coral, drop),
      ]),
    );
  }

  Widget _routeLine(IconData icon, Color color, String text) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.3))),
      ]);

  // ---------------------------------------------------------------- history

  void _showHistory(BuildContext context, List<dynamic> payoutRows) {
    final s = AppScope.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .75,
        minChildSize: .4,
        maxChildSize: .95,
        builder: (ctx, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 28),
          children: [
            Text(s.t('Payout history', 'Historia ya malipo'), style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            if (payoutRows.isEmpty)
              Text(s.t('You have not requested any payouts yet.', 'Bado hujaomba malipo yoyote.'), style: TextStyle(color: _muted(ctx)))
            else
              ..._spaced(payoutRows.map((row) => _payoutTile(ctx, s, Map<String, dynamic>.from(row as Map))).toList()),
            const SizedBox(height: 26),
            Text(s.t('Commission payments', 'Malipo ya kamisheni'), style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            if (settlements.isEmpty)
              Text(s.t('No commission payments yet.', 'Bado hakuna malipo ya kamisheni.'), style: TextStyle(color: _muted(ctx)))
            else
              ..._spaced(settlements.map((item) {
                final r = Map<String, dynamic>.from(item as Map);
                final st = (r['status'] ?? '').toString();
                final Color tone = st == 'paid' ? ZenjiColors.green : (st == 'failed' ? ZenjiColors.error : ZenjiColors.darkHighlight);
                final label = st == 'paid'
                    ? s.t('Paid', 'Imelipwa')
                    : st == 'failed'
                        ? s.t('Failed', 'Imeshindwa')
                        : st == 'processing'
                            ? s.t('Processing', 'Inashughulikiwa')
                            : s.t('Pending', 'Inasubiri');
                return _Block(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    _iconBubble(ctx, Icons.receipt_long_outlined, color: tone),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(Fmt.tzs(Fmt.parse(r['amount'] ?? r['commission_amount'])), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                        const SizedBox(height: 2),
                        Text(Fmt.date(r['createdAt'] ?? r['created_at']), style: TextStyle(color: _muted(ctx), fontSize: 12)),
                      ]),
                    ),
                    Pill(label, color: tone),
                  ]),
                );
              }).toList()),
          ],
        ),
      ),
    );
  }
}

// ===================================================================
// Commission payment progress (polls until the provider confirms)
// ===================================================================

class _SettlementProgressDialog extends StatefulWidget {
  final String settlementId;
  const _SettlementProgressDialog({required this.settlementId});
  @override
  State<_SettlementProgressDialog> createState() => _SettlementProgressDialogState();
}

class _SettlementProgressDialogState extends State<_SettlementProgressDialog> {
  Timer? _timer;
  String status = 'processing';
  int _ticks = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _check();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    if (_busy || !mounted) return;
    _busy = true;
    try {
      final r = await DriverApi.settlementStatus(widget.settlementId);
      if (!mounted) return;
      final st = (r['status'] ?? 'processing').toString();
      setState(() => status = st);
      if (st == 'paid' || st == 'failed') _timer?.cancel();
    } catch (_) {
      // transient network error: keep polling
    } finally {
      _busy = false;
    }
    _ticks++;
    if (_ticks >= 45) _timer?.cancel(); // ~3 minutes, then the driver can continue in the background
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final paid = status == 'paid';
    final failed = status == 'failed';
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 6),
        if (paid)
          const Icon(Icons.check_circle_rounded, size: 64, color: ZenjiColors.green)
        else if (failed)
          const Icon(Icons.error_rounded, size: 64, color: ZenjiColors.error)
        else
          SizedBox.square(dimension: 56, child: CircularProgressIndicator(strokeWidth: 4, color: cs.primary)),
        const SizedBox(height: 18),
        Text(
          paid
              ? s.t('Payment confirmed', 'Malipo yamethibitishwa')
              : failed
                  ? s.t('Payment failed', 'Malipo yameshindwa')
                  : s.t('Waiting for approval', 'Inasubiri idhini'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
        ),
        const SizedBox(height: 8),
        Text(
          paid
              ? s.t('Thank you. Your account is up to date and you can keep receiving rides.', 'Asante. Akaunti yako iko sawa na unaweza kuendelea kupokea safari.')
              : failed
                  ? s.t('The payment did not go through. You can try again.', 'Malipo hayakukamilika. Unaweza kujaribu tena.')
                  : s.t('Check your phone and enter your mobile-money PIN to approve the payment.', 'Angalia simu yako na uweke PIN ya pesa kuidhinisha malipo.'),
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted(context)),
        ),
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(paid || failed ? s.t('Done', 'Sawa') : s.t('Continue in background', 'Endelea nyuma')),
        ),
      ],
    );
  }
}

// ===================================================================
// Request payout
// ===================================================================

class WithdrawScreen extends StatefulWidget {
  final num available;
  final num pending;
  const WithdrawScreen({super.key, this.available = 0, this.pending = 0});
  @override
  State<WithdrawScreen> createState() => _WithdrawScreenState();
}

class _WithdrawScreenState extends State<WithdrawScreen> {
  final formKey = GlobalKey<FormState>();
  final amount = TextEditingController();
  final phone = TextEditingController();
  final bankName = TextEditingController();
  final account = TextEditingController();
  final accountName = TextEditingController();
  String method = 'momo'; // matches the backend enum: 'momo' | 'bank'
  bool submitting = false;
  late num available;

  @override
  void initState() {
    super.initState();
    available = widget.available;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final s = AppScope.of(context);
      phone.text = (s.profile?['phone'] ?? '').toString();
      accountName.text = (s.profile?['full_name'] ?? s.profile?['fullName'] ?? '').toString();
      // Re-check the server balance so the driver never commits against a stale figure.
      final info = await DriverApi.payouts();
      if (!mounted || info == null) return;
      setState(() => available = Fmt.parse(info['available']));
    });
  }

  @override
  void dispose() {
    amount.dispose();
    phone.dispose();
    bankName.dispose();
    account.dispose();
    accountName.dispose();
    super.dispose();
  }

  num get _amount => Fmt.parse(amount.text);

  void _setFraction(double f) {
    final num v = f >= 1 ? available : (available * f).floorToDouble();
    final text = v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);
    amount.value = ThousandsInputFormatter().formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: text));
    setState(() {});
  }

  Future<void> _submit() async {
    final s = AppScope.of(context);
    if (!(formKey.currentState?.validate() ?? false)) return;
    final destination = method == 'momo' ? phone.text.trim() : '${bankName.text.trim()} · ${account.text.trim()}';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(s.t('Confirm payout', 'Thibitisha malipo')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          _confirmRow(s.t('Amount', 'Kiasi'), Fmt.tzs(_amount)),
          _confirmRow(s.t('Method', 'Njia'), method == 'momo' ? s.t('Mobile money', 'Pesa ya simu') : s.t('Bank transfer', 'Benki')),
          _confirmRow(s.t('Send to', 'Tuma kwa'), destination),
          const SizedBox(height: 10),
          Text(
            s.t('Please check the details carefully. Money sent to a wrong number or account cannot be recovered.',
                'Kagua taarifa kwa makini. Pesa iliyotumwa kwa namba au akaunti isiyo sahihi haiwezi kurejeshwa.'),
            style: TextStyle(color: _muted(context), fontSize: 12.5),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(s.t('Edit', 'Badilisha'))),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(s.t('Confirm', 'Thibitisha'))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => submitting = true);
    try {
      final details = method == 'momo'
          ? <String, dynamic>{'phone': phone.text.trim(), 'account': phone.text.trim()}
          : <String, dynamic>{
              'bankName': bankName.text.trim(),
              'account': account.text.trim(),
              'accountName': accountName.text.trim(),
              'phone': (s.profile?['phone'] ?? '').toString(),
            };
      final paidAmount = _amount;
      final result = await DriverApi.requestPayout(amount: paidAmount.toDouble(), method: method, accountDetails: details);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (d) => AlertDialog(
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 6),
            const Icon(Icons.check_circle_rounded, size: 64, color: ZenjiColors.green),
            const SizedBox(height: 16),
            Text(s.t('Payout requested', 'Ombi la malipo limetumwa'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            const SizedBox(height: 8),
            Text(
              s.t('${Fmt.tzs(paidAmount)} is now pending review. ZenjiGO will send it to $destination and notify you when it is paid.',
                  '${Fmt.tzs(paidAmount)} inasubiri ukaguzi. ZenjiGO itatuma kwa $destination na kukujulisha ikilipwa.'),
              textAlign: TextAlign.center,
              style: TextStyle(color: _muted(context)),
            ),
            if ((result['id'] ?? '').toString().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('${s.t('Reference', 'Kumbukumbu')} #${result['id']}', style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(s.t('Done', 'Sawa')))],
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) toast(context, FriendlyErrors.message(e, swahili: s.isSwahili));
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  Widget _confirmRow(String l, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 74, child: Text(l, style: TextStyle(color: _muted(context)))),
          Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w700))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('Request payout', 'Omba malipo'))),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Form(
              key: formKey,
              child: ListView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 28), children: [
                _Block(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.t('Available to withdraw', 'Salio linaloweza kutolewa'), style: TextStyle(color: _muted(context), fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(Fmt.tzs(available), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 28)),
                    if (widget.pending > 0) ...[
                      const SizedBox(height: 6),
                      Text('${s.t('Already requested', 'Tayari imeombwa')}: ${Fmt.tzs(widget.pending)}', style: TextStyle(color: _muted(context), fontSize: 12.5)),
                    ],
                  ]),
                ),
                const SizedBox(height: 22),
                Text(s.t('Amount', 'Kiasi'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 10),
                TextFormField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [ThousandsInputFormatter()],
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
                  decoration: const InputDecoration(prefixText: 'TZS  ', hintText: '0'),
                  onChanged: (_) => setState(() {}),
                  validator: (v) {
                    final n = Fmt.parse(v);
                    if (n <= 0) return s.t('Enter an amount to withdraw', 'Weka kiasi cha kutoa');
                    if (n > available) return s.t('That is more than your available balance', 'Kiasi hiki kinazidi salio lako');
                    return null;
                  },
                ),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  ActionChip(label: const Text('25%'), onPressed: available > 0 ? () => _setFraction(.25) : null),
                  ActionChip(label: const Text('50%'), onPressed: available > 0 ? () => _setFraction(.5) : null),
                  ActionChip(label: const Text('75%'), onPressed: available > 0 ? () => _setFraction(.75) : null),
                  ActionChip(label: const Text('Max'), onPressed: available > 0 ? () => _setFraction(1) : null),
                ]),
                const SizedBox(height: 24),
                Text(s.t('Send money to', 'Tuma pesa kwa'), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(value: 'momo', icon: const Icon(Icons.phone_android_rounded), label: Text(s.t('Mobile money', 'Pesa ya simu'))),
                      ButtonSegment(value: 'bank', icon: const Icon(Icons.account_balance_outlined), label: Text(s.t('Bank', 'Benki'))),
                    ],
                    selected: {method},
                    onSelectionChanged: (v) => setState(() => method = v.first),
                  ),
                ),
                const SizedBox(height: 16),
                if (method == 'momo')
                  TextFormField(
                    controller: phone,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: s.t('Mobile money number', 'Namba ya simu ya pesa'),
                      helperText: 'M-Pesa, Airtel Money, Mixx by Yas, HaloPesa',
                      prefixIcon: const Icon(Icons.phone_outlined),
                    ),
                    validator: (v) => (v ?? '').replaceAll(RegExp(r'\D'), '').length < 9 ? s.t('Enter a valid phone number', 'Weka namba sahihi ya simu') : null,
                  )
                else ...[
                  TextFormField(
                    controller: bankName,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(labelText: s.t('Bank name', 'Jina la benki'), prefixIcon: const Icon(Icons.account_balance_outlined)),
                    validator: (v) => (v ?? '').trim().isEmpty ? s.t('Enter the bank name', 'Weka jina la benki') : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: account,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(labelText: s.t('Account number', 'Namba ya akaunti'), prefixIcon: const Icon(Icons.numbers_rounded)),
                    validator: (v) => (v ?? '').trim().length < 6 ? s.t('Enter a valid account number', 'Weka namba sahihi ya akaunti') : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: accountName,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(labelText: s.t('Account holder name', 'Jina la mwenye akaunti'), prefixIcon: const Icon(Icons.person_outline)),
                    validator: (v) => (v ?? '').trim().isEmpty ? s.t('Enter the account holder name', 'Weka jina la mwenye akaunti') : null,
                  ),
                ],
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: cs.primary.withValues(alpha: .10), borderRadius: BorderRadius.circular(14)),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.info_outline_rounded, size: 20, color: cs.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        s.t('ZenjiGO reviews every payout request, then sends the money and notifies you. Track the status under Earnings → Payout requests.',
                            'ZenjiGO hukagua kila ombi, kisha hutuma pesa na kukujulisha. Fuatilia hali chini ya Mapato → Maombi ya malipo.'),
                        style: const TextStyle(fontSize: 12.5, height: 1.35),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  height: 54,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    onPressed: submitting || available <= 0 ? null : _submit,
                    icon: submitting
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                        : const Icon(Icons.send_rounded),
                    label: Text(
                      submitting
                          ? s.t('Submitting…', 'Inatuma…')
                          : (_amount > 0 ? '${s.t('Withdraw', 'Toa')} ${Fmt.tzs(_amount)}' : s.t('Submit payout request', 'Tuma ombi la malipo')),
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
