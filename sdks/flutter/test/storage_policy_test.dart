import 'package:flutter_test/flutter_test.dart';
import 'package:proxycept_logging/src/storage_policy.dart';

void main() {
  Map<String, dynamic> ios({bool simulator = false}) => {
    'platform': 'ios',
    'isSimulator': simulator,
    'backupExcluded': true,
    'directoryPrivate': true,
    'filePrivate': true,
    'fileProtected': false,
    'protectionClass': 'unreported',
    'directoryProtectionClass': 'unreported',
  };
  test('only explicit simulator plus both missing classes gets UNVERIFIED exception', () {
    expect(
      evaluateStoragePolicy(ios(simulator: true)),
      StoragePolicyEvidence.simulatorProtectionUnverified,
    );
    expect(evaluateStoragePolicy(ios()), StoragePolicyEvidence.rejected);
    expect(
      evaluateStoragePolicy({...ios(), 'isSimulator': 'true'}),
      StoragePolicyEvidence.rejected,
    );
  });
  for (final flag in ['backupExcluded', 'directoryPrivate', 'filePrivate']) {
    test('simulator exception cannot skip required $flag', () {
      expect(
        evaluateStoragePolicy({...ios(simulator: true), flag: false}),
        StoragePolicyEvidence.rejected,
      );
    });
  }
  for (final key in ['protectionClass', 'directoryProtectionClass']) {
    for (final value in [
      'NSFileProtectionNone',
      'NSFileProtectionComplete',
      'NSFileProtectionCompleteUnlessOpen',
      'NSFileProtectionCompleteUntilFirstUserAuthentication',
    ]) {
      test(
        'one reported $key=$value cannot enter missing-metadata simulator exception',
        () {
          expect(
            evaluateStoragePolicy({...ios(simulator: true), key: value}),
            StoragePolicyEvidence.rejected,
          );
        },
      );
    }
  }
  test('physical devices require both expected classes and explicit private policy', () {
    const protection = 'NSFileProtectionCompleteUntilFirstUserAuthentication';
    final verified = {
      ...ios(),
      'fileProtected': true,
      'protectionClass': protection,
      'directoryProtectionClass': protection,
    };
    expect(evaluateStoragePolicy(verified), StoragePolicyEvidence.verified);
    expect(
      evaluateStoragePolicy({...verified, 'fileProtected': false}),
      StoragePolicyEvidence.rejected,
    );
    expect(
      evaluateStoragePolicy({
        ...verified,
        'protectionClass': 'NSFileProtectionNone',
      }),
      StoragePolicyEvidence.rejected,
    );
    expect(
      evaluateStoragePolicy({
        ...verified,
        'directoryProtectionClass': 'NSFileProtectionNone',
      }),
      StoragePolicyEvidence.rejected,
    );
  });
  test(
    'android validates private no-backup policy without iOS crypto claims',
    () {
      final android = {
        'platform': 'android',
        'backupExcluded': true,
        'directoryPrivate': true,
        'fileProtected': true,
      };
      expect(evaluateStoragePolicy(android), StoragePolicyEvidence.verified);
      expect(
        evaluateStoragePolicy({...android, 'fileProtected': false}),
        StoragePolicyEvidence.rejected,
      );
      expect(evaluateStoragePolicy(null), StoragePolicyEvidence.rejected);
    },
  );
}
