import 'dart:async';

import 'package:fl_clash/models/profile.dart';

import 'constant.dart';

class ProfileUpdateScheduler {
  ProfileUpdateScheduler({
    required this.readProfiles,
    required this.updateProfile,
    required this.onError,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final List<Profile> Function() readProfiles;
  final Future<void> Function(Profile profile) updateProfile;
  final void Function(Object error, StackTrace stackTrace) onError;
  final DateTime Function() _now;
  final _timers = <int, Timer>{};
  final _running = <int>{};
  final _retryAt = <int, DateTime>{};
  bool _disposed = false;

  void reschedule() {
    if (_disposed) return;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    final profiles = readProfiles().where((profile) => profile.realAutoUpdate);
    final ids = {for (final profile in profiles) profile.id};
    _retryAt.removeWhere((id, _) => !ids.contains(id));
    final now = _now();
    for (final profile in profiles) {
      if (_running.contains(profile.id)) continue;
      final interval = profile.autoUpdateDuration > Duration.zero
          ? profile.autoUpdateDuration
          : defaultUpdateDuration;
      var next = profile.lastUpdateDate?.add(interval) ?? now;
      final retryAt = _retryAt[profile.id];
      if (retryAt != null && retryAt.isAfter(next)) {
        next = retryAt;
      }
      final delay = next.difference(now);
      _timers[profile.id] = Timer(
        delay.isNegative ? Duration.zero : delay,
        () => unawaited(_update(profile.id)),
      );
    }
  }

  Future<void> _update(int id) async {
    if (_disposed || _running.contains(id)) return;
    _timers.remove(id);
    final profile = readProfiles().getProfile(id);
    if (profile == null || !profile.realAutoUpdate) return;
    _running.add(id);
    try {
      await updateProfile(profile);
      _retryAt.remove(id);
    } catch (error, stackTrace) {
      _retryAt[id] = _now().add(const Duration(minutes: 1));
      onError(error, stackTrace);
    } finally {
      _running.remove(id);
      reschedule();
    }
  }

  void dispose() {
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _retryAt.clear();
  }
}
