import 'dart:async';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/profile_update_scheduler.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<Profile> profiles;
  late List<int> updates;
  late List<Object> errors;
  late ProfileUpdateScheduler scheduler;
  late DateTime now;
  Future<void> Function(Profile)? onUpdate;

  Profile profile(int id, int minutes, {DateTime? lastUpdate}) {
    return Profile(
      id: id,
      type: ProfileType.url,
      url: 'https://example.com/$id.yaml',
      autoUpdateDuration: Duration(minutes: minutes),
      lastUpdateDate: lastUpdate ?? now,
    );
  }

  void start() {
    scheduler = ProfileUpdateScheduler(
      readProfiles: () => profiles,
      now: () => now,
      updateProfile: (profile) async {
        updates.add(profile.id);
        await onUpdate?.call(profile);
        profiles = [
          for (final latest in profiles)
            if (latest.id == profile.id)
              latest.copyWith(lastUpdateDate: now)
            else
              latest,
        ];
      },
      onError: (error, _) => errors.add(error),
    );
    scheduler.reschedule();
  }

  Future<void> elapse(WidgetTester tester, int minutes) async {
    now = now.add(Duration(minutes: minutes));
    await tester.pump(Duration(minutes: minutes));
  }

  setUp(() {
    now = DateTime.utc(2026);
    profiles = [];
    updates = [];
    errors = [];
    onUpdate = null;
  });

  void testScheduler(
    String description,
    Future<void> Function(WidgetTester tester) body,
  ) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        scheduler.dispose();
      }
    });
  }

  testScheduler('10 and 15 minute subscriptions run on separate deadlines', (
    tester,
  ) async {
    profiles = [profile(1, 10), profile(2, 15)];
    start();
    await elapse(tester, 9);
    expect(updates, isEmpty);
    await elapse(tester, 1);
    expect(updates, [1]);
    await elapse(tester, 5);
    expect(updates, [1, 2]);
    await elapse(tester, 5);
    expect(updates, [1, 2, 1]);
    await elapse(tester, 10);
    expect(updates.take(3), [1, 2, 1]);
    expect(updates.skip(3), unorderedEquals([1, 2]));
  });

  testScheduler('overdue and never updated subscriptions run immediately', (
    tester,
  ) async {
    profiles = [
      profile(1, 10, lastUpdate: now.subtract(const Duration(minutes: 11))),
      profile(2, 15).copyWith(lastUpdateDate: null),
      profile(3, 20),
    ];
    start();
    await tester.pump();
    expect(updates, unorderedEquals([1, 2]));
    expect(errors, isEmpty);
  });

  testScheduler('interval edits and manual updates replace pending deadlines', (
    tester,
  ) async {
    profiles = [profile(1, 10)];
    start();
    await elapse(tester, 3);
    profiles = [
      profiles.single.copyWith(autoUpdateDuration: const Duration(minutes: 5)),
    ];
    scheduler.reschedule();
    await elapse(tester, 2);
    expect(updates, [1]);
    await elapse(tester, 2);
    profiles = [profiles.single.copyWith(lastUpdateDate: now)];
    scheduler.reschedule();
    await elapse(tester, 3);
    expect(updates, [1]);
    await elapse(tester, 2);
    expect(updates, [1, 1]);
  });

  testScheduler('disabled, removed and local profiles have no pending update', (
    tester,
  ) async {
    profiles = [
      profile(1, 10),
      profile(2, 10),
      profile(3, 10).copyWith(type: ProfileType.file),
      profile(4, 10).copyWith(type: ProfileType.custom),
    ];
    start();
    await elapse(tester, 5);
    profiles = [
      profiles[0].copyWith(autoUpdate: false),
      profiles[2],
      profiles[3],
    ];
    scheduler.reschedule();
    await elapse(tester, 10);
    expect(updates, isEmpty);
    profiles = [profiles.first.copyWith(autoUpdate: true)];
    scheduler.reschedule();
    await tester.pump();
    expect(updates, [1]);
  });

  testScheduler(
    'failure retries after a minute without blocking other profiles',
    (tester) async {
      profiles = [profile(1, 10), profile(2, 10)];
      var fail = true;
      onUpdate = (profile) async {
        if (profile.id == 1 && fail) throw StateError('offline');
      };
      start();
      await elapse(tester, 10);
      expect(updates, unorderedEquals([1, 2]));
      expect(errors, hasLength(1));
      scheduler.reschedule();
      await tester.pump();
      expect(updates, hasLength(2));
      fail = false;
      await elapse(tester, 1);
      expect(updates.last, 1);
      expect(updates, hasLength(3));
      await elapse(tester, 9);
      expect(updates.last, 2);
      await elapse(tester, 1);
      expect(updates.last, 1);
      expect(updates, hasLength(5));
    },
  );

  testScheduler(
    'slow updates do not overlap themselves or delay other profiles',
    (tester) async {
      final pending = Completer<void>();
      profiles = [profile(1, 10), profile(2, 15)];
      onUpdate = (profile) async {
        if (profile.id == 1) await pending.future;
      };
      start();
      await elapse(tester, 10);
      scheduler.reschedule();
      await elapse(tester, 5);
      expect(updates, [1, 2]);
      await elapse(tester, 10);
      expect(updates, [1, 2]);
      pending.complete();
      await tester.pump();
      await elapse(tester, 5);
      expect(updates, [1, 2, 2]);
      await elapse(tester, 5);
      expect(updates, [1, 2, 2, 1]);
    },
  );

  testScheduler(
    'resume catches overdue profiles without replaying missed ticks',
    (tester) async {
      profiles = [profile(1, 10), profile(2, 15)];
      start();
      now = now.add(const Duration(hours: 2));
      scheduler.reschedule();
      await tester.pump();
      expect(updates, unorderedEquals([1, 2]));
      await elapse(tester, 9);
      expect(updates, hasLength(2));
      await elapse(tester, 1);
      expect(updates.last, 1);
      expect(updates, hasLength(3));
    },
  );

  testScheduler('invalid intervals fall back without a tight update loop', (
    tester,
  ) async {
    profiles = [profile(1, 0), profile(2, -1)];
    start();
    await tester.pump();
    expect(updates, isEmpty);
    await elapse(tester, defaultUpdateDuration.inMinutes);
    expect(updates, unorderedEquals([1, 2]));
  });

  testScheduler(
    'disposal cancels timers and prevents in-flight work rearming',
    (tester) async {
      final pending = Completer<void>();
      profiles = [profile(1, 10), profile(2, 15)];
      onUpdate = (_) => pending.future;
      start();
      await elapse(tester, 10);
      scheduler.dispose();
      pending.complete();
      await tester.pump();
      await elapse(tester, 30);
      expect(updates, [1]);
      scheduler.reschedule();
      await tester.pump();
      expect(updates, [1]);
    },
  );
}
