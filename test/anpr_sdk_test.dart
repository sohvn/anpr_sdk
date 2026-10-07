import 'package:anpr_sdk/anpr_sdk.dart';
import 'package:anpr_sdk/src/plate_voter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AnprResult', () {
    test('copyWith keeps values and can clear the plate', () {
      final r = AnprResult(
        plateNumber: 'MH12AB1234',
        ocrConfidence: 0.9,
        timestamp: DateTime(2026),
      );

      final same = r.copyWith(detectionMs: 12);
      expect(same.plateNumber, 'MH12AB1234');
      expect(same.ocrConfidence, 0.9);
      expect(same.detectionMs, 12);

      final cleared = r.copyWith(clearPlate: true);
      expect(cleared.plateNumber, isNull);
      expect(cleared.hasPlate, isFalse);
    });

    test('isConfirmed resets unless explicitly set', () {
      final confirmed = AnprResult(
        plateNumber: 'MH12AB1234',
        isConfirmed: true,
        timestamp: DateTime(2026),
      );
      expect(confirmed.copyWith(detectionMs: 1).isConfirmed, isFalse);
      expect(confirmed.copyWith(isConfirmed: true).isConfirmed, isTrue);
    });
  });

  group('AnprSdkConfig', () {
    test('has sensible defaults', () {
      const c = AnprSdkConfig();
      expect(c.detectionThreshold, 0.35);
      expect(c.confirmReads, 2);
      expect(c.voteMaxReads, 7);
    });

    test('rejects confirmReads larger than voteMaxReads', () {
      expect(
        () => AnprSdkConfig(confirmReads: 10, voteMaxReads: 7),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('PlateVoter', () {
    final t0 = DateTime(2026, 1, 1, 12);

    test('picks the plate with the highest total confidence', () {
      final v = PlateVoter(window: const Duration(seconds: 5), maxReads: 7);
      v.add('AB123', 0.9, t0);
      v.add('AB1Z3', 0.6, t0.add(const Duration(milliseconds: 400)));
      v.add('AB123', 0.5, t0.add(const Duration(milliseconds: 800)));

      expect(v.best, 'AB123');
      expect(v.countOf('AB123'), 2);
      expect(v.countOf('AB1Z3'), 1);
    });

    test('drops reads older than the window', () {
      final v = PlateVoter(window: const Duration(seconds: 1), maxReads: 7);
      v.add('OLD111', 0.9, t0);
      v.add('NEW222', 0.9, t0.add(const Duration(seconds: 2)));

      expect(v.countOf('OLD111'), 0);
      expect(v.best, 'NEW222');
    });

    test('keeps at most maxReads reads', () {
      final v = PlateVoter(window: const Duration(seconds: 10), maxReads: 2);
      v.add('AAA111', 0.9, t0);
      v.add('BBB222', 0.9, t0.add(const Duration(milliseconds: 100)));
      v.add('CCC333', 0.9, t0.add(const Duration(milliseconds: 200)));

      expect(v.countOf('AAA111'), 0);
      expect(v.countOf('CCC333'), 1);
    });

    test('clear empties the voter', () {
      final v = PlateVoter(window: const Duration(seconds: 5), maxReads: 7);
      v.add('AB123', 0.9, t0);
      v.clear();
      expect(v.best, isNull);
    });
  });

  group('AnprSdk', () {
    test('starts uninitialized and refuses to run without initialize()', () {
      final sdk = AnprSdk.instance;
      expect(sdk.status.value, AnprSdkStatus.uninitialized);
      expect(sdk.isReady, isFalse);
      expect(
        () => sdk.requireEngine(),
        throwsA(
          isA<AnprException>().having(
            (e) => e.code,
            'code',
            AnprErrorCode.notInitialized,
          ),
        ),
      );
    });
  });
}
