/// Interprets native diagnostic metadata, not arbitrary runtime HTTP config.
/// A successful metadata check never proves physical locked-device encryption.
enum StoragePolicyEvidence { verified, simulatorProtectionUnverified, rejected }

StoragePolicyEvidence evaluateStoragePolicy(Map<String, dynamic>? policy) {
  if (policy == null ||
      policy['backupExcluded'] != true ||
      policy['directoryPrivate'] != true)
    return StoragePolicyEvidence.rejected;
  if (policy['platform'] == 'android') {
    // Android's bridge checks noBackupFilesDir and 0700/0600, not iOS protection.
    return policy['fileProtected'] == true
        ? StoragePolicyEvidence.verified
        : StoragePolicyEvidence.rejected;
  }
  if (policy['platform'] != 'ios' || policy['filePrivate'] != true) {
    return StoragePolicyEvidence.rejected;
  }
  const expected = 'NSFileProtectionCompleteUntilFirstUserAuthentication';
  if (policy['fileProtected'] == true &&
      policy['protectionClass'] == expected &&
      policy['directoryProtectionClass'] == expected) {
    return StoragePolicyEvidence.verified;
  }
  // The simulator can omit Data Protection metadata entirely. This is explicitly
  // UNVERIFIED, and is never a physical-device success or a wrong-class bypass.
  if (policy['isSimulator'] == true &&
      policy['fileProtected'] == false &&
      policy['protectionClass'] == 'unreported' &&
      policy['directoryProtectionClass'] == 'unreported') {
    return StoragePolicyEvidence.simulatorProtectionUnverified;
  }
  return StoragePolicyEvidence.rejected;
}
