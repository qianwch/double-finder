# Double Finder 全量回归测试用例清单

自动从 `Tests/double-finderTests/*.swift` 提取（94 个测试类，619 个用例）。每个用例的说明取自源码中紧邻的 `///` 注释；没有注释的只列名称。
重新生成：`python3 Tests/regression_catalog.py > Tests/REGRESSION.md`。

运行方式：

```bash
swift test                              # 全量（跑在真实 UserDefaults + 钥匙串上，先 defaults export 备份）
swift test --filter SevenZipEngineTests # 单个测试类
```

带 Live 后缀 / 需要外部工具的测试在条件不满足时自动 `XCTSkip`：远端 live 测试要设 `DF_KEYCHAIN_LIVE=1`、`ANDROID_LIVE=1` 等环境变量并有真实设备；`RarVolumeTests` 需要 `brew install rar`。

## 归档 / 压缩包

### `ArchiveLogicTests` — ArchiveLogicTests.swift

Pure-logic unit tests (no AppKit / UI). These cover the archive-related helpers that drive a lot of the panel behavior and are easy to get wrong.

| 用例 | 覆盖点 |
|---|---|
| `testRecognizesCommonArchives` | — |
| `testRecognizesCompoundTarSuffixes` | — |
| `testIsCaseInsensitive` | — |
| `testRejectsNonArchives` | — |
| `testBareCompressorsAreBrowsable` | — |
| `testSplitArchiveFirstVolumeIsEnterable` | — |
| `testNonFirstAndNonArchiveVolumesAreNotEnterable` | — |
| `testRarVolumeNaming` | New-style RAR volumes: only "part1" is the archive; the rest are plain files. |
| `testArchiveFormatExtensionMatchesRawValue` | — |
| `testOnlyZipAnd7zSupportEncryption` | — |
| `testSupportsSplit` | — |
| `testDetectsGBKArchiveAndDecodes` | — |
| `testDetectsShiftJISArchiveAndDecodes` | — |
| `testAllUTF8NamesNeedNoDetection` | — |
| `testNameRightEdgeIsAResizeDivider` | — |
| `testShrinkingFirstOptionalWidensName` | — |
| `testTradingTwoOptionalsKeepsNameWidthAndMovesDivider` | — |
| `testNameStaysAtLeastMinimum` | — |
| `testParentEntryPointsToContainingDirectory` | — |

### `ArchiveReplaceTests` — ArchiveReplaceTests.swift

LibArchive.rewriteReplacing — the F4 edit-inside-archive write-back.

| 用例 | 覆盖点 |
|---|---|
| `testReplaceInZip` | — |
| `testReplaceInTarGz` | — |
| `testReplaceMissingEntryThrows` | — |

### `DeleteExtractProviderTests` — DeleteExtractProviderTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testDeleteSFTP` | — |
| `testDeleteS3` | — |
| `testDeletePermanent` | — |
| `testDeleteTrashUsesDefault` | — |
| `testExtractProviderConfig` | — |

### `EncryptedArchiveTests` — EncryptedArchiveTests.swift

Encrypted-7z handling. libarchive cannot decrypt 7z at all, so these archives go to the in-process 7-Zip engine. The regression these cover: the fallback once reported "corrupt or incomplete" instead of "needs a password", so the panel showed an error alert and backed out instead of prompting.

| 用例 | 覆盖点 |
|---|---|
| `testHeaderEncryptedListingReportsEncryptedNotCorrupt` | With no password yet, the engine's open must report "encrypted", never "corrupt" — the panel keys its password prompt off that. |
| `testHeaderEncryptedEntryDetailsReportsEncryptedNotCorrupt` | `listDirectory` goes through `entryDetails`, not `entryPaths` — the panel's actual path, so it needs its own guard. |
| `testHeaderEncryptedListsWithCorrectPassword` | — |
| `testWrongPasswordStillReportsEncrypted` | A wrong password must stay an `ArchiveEncryptedError` so the panel can re-prompt rather than claim the archive is broken. |
| `testHeaderEncryptedExtractWithoutPasswordReportsEncrypted` | — |
| `testHeaderEncryptedExtractsWithCorrectPassword` | — |
| `testDataEncryptedListsButExtractionNeedsPassword` | Data-only encryption leaves the names readable, so listing succeeds and only the extraction needs the password. |

### `ExtractRoutingTests` — ExtractRoutingTests.swift

Verifies extractAll routing: 7z → the in-process 7-Zip engine, zip → libarchive, tarballs → libarchive (one-step, NOT a leftover .tar).

| 用例 | 覆盖点 |
|---|---|
| `testTarGzExtractsRealFilesNotTar` | — |
| `testLegacyGBKZipExtractsCorrectNames` | Windows-made zips without the UTF-8 flag store names in a legacy codepage (GBK here). extractAll keeps zips on libarchive, which decodes such names through per-archive charset detection. |
| `testSevenZAndZipExtract` | — |

### `FileSplitTests` — FileSplitTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testParseSize` | — |
| `testPartCount` | — |
| `testPartName` | — |
| `testCrcFileRoundTrip` | — |
| `testSplitAndCombineRoundTrip` | — |
| `testExactMultipleLeavesNoEmptyTrailingPart` | — |
| `testCombineMismatchThrows` | — |
| `testSplitCancelThrows` | — |
| `testPartsListRequiresFirstPart` | — |

### `PackProgressTests` — PackProgressTests.swift

7-Zip `-bsp1` progress-line parsing (pure logic).

| 用例 | 覆盖点 |
|---|---|
| `testLibArchiveCreateReportsAllSourceBytes` | — |
| `testLibArchiveCreateCancels` | — |
| `testSevenZipEngineReportsFullTotal` | — |
| `testRemovePackOutputsSplit` | — |
| `testRemovePackOutputsSingle` | — |

### `PackageIconTests` — PackageIconTests.swift

`.app` and friends are directories, but each carries its own icon — the icon cache keys them per path instead of sharing the one folder bitmap, and this predicate is what makes that call.

| 用例 | 覆盖点 |
|---|---|
| `testAppBundleIsAPackage` | — |
| `testCaseInsensitive` | — |
| `testOtherBundleKinds` | — |
| `testPlainDirectoriesAndFilesAreNot` | — |
| `testPackagesDoNotShareTheFolderIconKey` | The whole point: a package must not land on the shared folder key, and a plain directory must. |

### `PackageLaunchTests` — PackageLaunchTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testAppBundleIsLaunchablePackage` | — |
| `testPlainDirectoryIsNotPackage` | — |

### `RarVolumeTests` — RarVolumeTests.swift

Multi-volume RAR ("x.part1.rar" + "x.part2.rar"…): every volume has its own headers, so the set is handed to libarchive as a file list and it switches volumes itself. Fixtures need the `rar` tool (brew install rar); skips otherwise.

| 用例 | 覆盖点 |
|---|---|
| `testSetIsRecognisedFromTheFirstVolumeOnly` | — |
| `testListAndExtractAcrossVolumes` | The panel's entry path: the listing shows the full size of a file that spans three volumes, and extraction gives back every byte. |
| `testMissingVolumeFailsLoudly` | A missing volume must surface as an error, never as a silently truncated file. |
| `testOldStyleNamingIsEnumerated` | Old-style naming ("x.rar" + "x.r00" + "x.r01"…) is the same set for libarchive. |

### `SevenZipEngineTests` — SevenZipEngineTests.swift

The in-process 7-Zip engine (`Sources/CSevenZip` + `SevenZipEngine`): create, list, extract, passwords, volumes, cancellation. No external tool involved — these run on every machine, including the bare `swift test` on a dev box.

| 用例 | 覆盖点 |
|---|---|
| `testVersionIsKnown` | — |
| `testRoundTripPreservesTreeNamesTimesAndLinks` | — |
| `testSingleEntryExtractsFlat` | A single entry pulled from a sub-folder lands flat under its own name — the panel's F5-from-inside-an-archive contract (no parent folders). |
| `testMissingEntryFails` | — |
| `testDataEncryptionListsWithoutPasswordButExtractionNeedsIt` | — |
| `testHeaderEncryptionHidesNamesUntilThePasswordIsGiven` | — |
| `testZipFSRoutesEncryptedSevenZipToTheEngine` | The whole panel flow on an encrypted 7z: libarchive gives up, the engine takes over, and `ZipFS` reports the right error type for the prompt. |
| `testVolumesAreReadBackByBothEngines` | — |
| `testEncryptedVolumesRoundTrip` | Encrypted + split is the combination that used to need 7zz twice over. |
| `testZipVolumesFromLibarchiveOpenAsOneArchive` | — |
| `testProgressAndCancellation` | — |
| `testCorruptArchiveIsAnOpenError` | — |

### `SolidArchiveExtractTests` — SolidArchiveExtractTests.swift

Regression: extracting a single entry that is NOT the first one from a SOLID 7z used to fail with "Truncated 7-Zip file body" — `archive_read_data_skip` can't advance through a solid block, so the preceding entries must be read+discarded to keep the decompressor in sync. The solid fixture comes from the in-process 7-Zip engine (solid by default; libarchive's writer isn't).

| 用例 | 覆盖点 |
|---|---|
| `testIsFinalMatchStopsOnlyOnTheWantedFile` | Early-stop predicate: once the wanted FILE itself has been written there is nothing left to find, so the scan can stop instead of decompressing the rest of the solid block. A wanted DIRECTORY must keep going — its subtree follows. |
| `testExtractLaterEntryFromSolid7z` | — |
| `testExtractingAFolderStillYieldsTheWholeSubtree` | Early-stop must not truncate a FOLDER target: every child still has to land. |
| `testExtractItemHonoursCancellation` | A viewer/copy that is cancelled mid-extract must abort the decompression loop instead of grinding through the rest of the solid block. |

### `VolumeSizeTests` — VolumeSizeTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testNoSplitCases` | — |
| `testPresetLabels` | — |
| `testCustomForms` | — |
| `testInvalid` | — |
| `testLocalizedNoSplitLabelMapsToNone` | — |
| `testLabelOverloadStillParsesRealSizes` | — |

### `ZipSplitTests` — ZipSplitTests.swift

Functional test for split-archive (.001) browsing/extraction: the volumes are written by the in-process 7-Zip engine and read back as one stream.

| 用例 | 覆盖点 |
|---|---|
| `testBrowseAndExtractSplit7z` | — |
| `testIncompleteSplitArchiveReportsOpenErrorNotPassword` | An *incomplete* multi-volume set (the final volume — which holds the 7z end-header — is missing) must report a plain "can't open" error, NOT an encryption error. Regression: a missing volume used to be misread as a password-protected archive, so double-clicking it prompted for a password. |

## 远端：SFTP / S3 / Android(MTP) / 连接

### `AndroidSearchLiveTests` — AndroidSearchLiveTests.swift

Live MTP test for Find Files against a real phone: name search over the tree, non-recursive scoping, and the content pass (which pulls candidates over USB). Needs a phone plugged in, unlocked, USB mode "File transfer". Skipped unless `ANDROID_LIVE=1`. Run with: ANDROID_LIVE=1 swift test --filter AndroidSearchLiveTests  The fixture is written to the device and removed again; the device session is closed in every exit path so the USB claim goes back (libmtp is exclusive).

| 用例 | 覆盖点 |
|---|---|
| `testFindFilesOnDevice` | — |

### `MTPNameConflictTests` — MTPNameConflictTests.swift

MTP is an object tree, not a filesystem: the same folder can legitimately hold several objects with identical names. Uploading without clearing them first leaves duplicates on the phone and makes any later name-based operation ambiguous, so every upload deletes same-named objects up front.

| 用例 | 覆盖点 |
|---|---|
| `testReturnsIDsOfSameNamedObjects` | — |
| `testReturnsAllDuplicates` | A device that already accumulated duplicates (another tool wrote them) gets fully cleaned, not just the first hit. |
| `testNoMatchReturnsEmpty` | — |
| `testCaseSensitive` | Android storage is case-sensitive (ext4/f2fs), so "A.txt" and "a.txt" are two distinct objects and must not clobber each other. |
| `testFoldersAreNeverReplaced` | Uploading a file must not delete a *folder* that happens to share the name — that would silently destroy a whole subtree. |
| `testChineseAndSpacedNamesMatchExactly` | — |

### `MTPPathCacheTests` — MTPPathCacheTests.swift

Pure-logic tests for path→object-id caching and lazy resolution. The listing step (the only part that touches USB) is injected, so the whole walk-down algorithm is testable without a phone.

| 用例 | 覆盖点 |
|---|---|
| `testCachesListedChildren` | — |
| `testResolveWalksDownFromStorageRootOnMiss` | — |
| `testSiblingsAreCachedDuringWalk` | Siblings seen while walking are cached too, so the next lookup is free. |
| `testResolveThrowsOnMissingComponent` | — |
| `testResolveThrowsWhenStorageUnknown` | An unknown storage can't be walked into — there's no root to start from. |
| `testInvalidateDropsSubtree` | After delete/rename/move the stale ids must go, or they'd address objects that no longer exist. |
| `testResolveWithChineseAndSpacedNames` | Real device paths: Chinese storage name plus a leading-space folder. |

### `MTPPathTests` — MTPPathTests.swift

Pure-logic tests for the MTP virtual path model.  Real-device values are used on purpose: the probe against a Galaxy S25 Edge reports a **Chinese** storage description ("内部存储") and a root entry with a **leading space** (" 我的文件"), both of which the path model must survive.

| 用例 | 覆盖点 |
|---|---|
| `testRootHasNoStorage` | — |
| `testStorageRoot` | — |
| `testNestedPath` | — |
| `testParent` | — |
| `testAppending` | — |
| `testStorageNameWithSlashIsSanitized` | A storage description containing "/" would break path splitting. |
| `testTrailingSlashAndDoubleSlashNormalized` | — |
| `testChineseStorageName` | Real device: the storage description comes back as Chinese text. |
| `testLeadingSpaceInNameIsPreserved` | Real device: a root folder literally named " 我的文件" (leading space). Trimming components would make it unaddressable, so spaces must survive. |

### `RemoteEditWatcherTests` — RemoteEditWatcherTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testHasChanged` | — |
| `testRemoteParentDir` | — |
| `testTrackDetectsChangeThenBaselineClears` | — |
| `testPendingDropsMissingFile` | — |
| `testTrackDedupesByTempPath` | — |

### `RemoteSearchLiveTests` — RemoteSearchLiveTests.swift

Live SFTP end-to-end test for Find Files against a remote host: name search, server-side content grep (binaries skipped), non-recursive scoping and cancellation. Skipped unless `SFTP_LIVE=1`. Run with: SFTP_LIVE=1 swift test --filter RemoteSearchLiveTests

| 用例 | 覆盖点 |
|---|---|
| `testRemoteFindFiles` | — |
| `testCancellationReturnsPromptly` | A remote search must actually stop: cancelling kills the ssh process instead of leaving `find` running with nobody to read it. |

### `SFTPDirectorySizeLiveTests` — RemoteSearchLiveTests.swift

Live SFTP test for the Space-key folder size (`SFTPFS.directorySize`). Skipped unless `SFTP_LIVE=1`.

| 用例 | 覆盖点 |
|---|---|
| `testDirectorySizeMatchesTheFilesWePut` | — |

### `RemoteSessionStoreTests` — RemoteSessionStoreTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testIDIgnoresNonIdentityFields` | — |
| `testRegisterAppendsAndDedupes` | — |
| `testRemoveAndNotification` | — |

### `RemoteSessionSwitchTests` — RemoteSessionSwitchTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testConnectSFTPWhileOnS3ClearsS3Session` | — |
| `testConnectRegistersSessionInGlobalStore` | — |
| `testEnterSessionRestoresLastBrowsedPath` | — |
| `testEnterActiveSessionGoesToRoot` | — |
| `testEnterSessionFirstTimeInThisPanelGoesToRoot` | — |
| `testLeaveRemovedSessionsFallsBackToLocal` | — |
| `testConnectS3WhileOnSFTPClearsSFTPSession` | — |

### `S3ConnectionTests` — S3ConnectionTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testDictRoundTrip` | — |
| `testDictRejectsMissing` | — |
| `testLegacySecretQueryShape` | — |
| `testBlobKey` | — |
| `testBlobRoundTrip` | — |
| `testDecodeBlobToleratesGarbage` | — |
| `testUnifiedItemAttributes` | — |

### `S3LiveTests` — S3LiveTests.swift

Live S3 round-trip test — exercises the real multipart-upload + streaming-download SigV4 path against a real endpoint. Skipped unless `S3_LIVE=1`. Run with: S3_LIVE=1 S3_ENDPOINT=… S3_REGION=… S3_ACCESS=… S3_SECRET=… [S3_BUCKET=…] \ swift test --filter S3LiveTests

| 用例 | 覆盖点 |
|---|---|
| `testMultipartRoundTrip` | — |
| `testS3FileRename` | Live S3 file-rename round-trip through `S3FS.rename` (copyObject + deleteObject), then verifies what the panel's `listDirectory` actually returns — old name gone, new name present, content intact. |
| `testS3RenameUIFlow` | — |
| `testS3MultipartCopy` | Live multipart server-side copy (UploadPartCopy) used by large-object rename. A 70 MiB source → 2 parts (64 MiB + 6 MiB); verifies progress sums to the size and the destination object matches. |
| `testS3UploadProgressIsRealtime` | Live multipart UPLOAD progress granularity: a 50 MiB file → 4 parts (16+16+16+2). Proves the intra-part streaming fix — progress must arrive in MANY small deltas (URLSession `didSendBodyData`), not one lump per finished part. Asserts the total sums to the size, there are far more callbacks than parts, and no single delta is as large as a whole part (16 MiB). |

### `S3MultipartPlanTests` — S3MultipartPlanTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testSmallFileNoParts` | — |
| `testJustOverThresholdSplits` | — |
| `testExactMultiple` | — |
| `testContiguousAndCovers` | — |
| `testHugeFileBumpsPartSizeUnderMaxParts` | — |

### `S3SearchLiveTests` — S3SearchLiveTests.swift

Live S3 end-to-end test for Find Files: name search over a real listing, plus the content pass that downloads candidates (binaries skipped). Skipped unless `S3_LIVE=1`. Run with: S3_LIVE=1 S3_ENDPOINT=… S3_REGION=… S3_ACCESS=… S3_SECRET=… [S3_BUCKET=…] \ swift test --filter S3SearchLiveTests

| 用例 | 覆盖点 |
|---|---|
| `testRemoteFindFiles` | — |

### `S3DirectorySizeLiveTests` — S3SearchLiveTests.swift

Live S3 test for the Space-key folder size (`S3FS.directorySize`). Skipped unless `S3_LIVE=1`.

| 用例 | 覆盖点 |
|---|---|
| `testDirectorySizeSumsThePrefix` | — |

### `S3SecretStoreLiveTests` — S3SecretStoreLiveTests.swift

Live Keychain tests — mutate the real login keychain with throwaway fake entries (host "s3secretstore-test.invalid"). Items are created and read by the same test process, so no authorization prompts appear. Gated: run with DF_KEYCHAIN_LIVE=1. Skipped otherwise.  tearDown removes the whole unified "double-finder" item ONLY if it did not exist before the test (so a user's real secret blob is never destroyed).

| 用例 | 覆盖点 |
|---|---|
| `testSaveLoadDeleteRoundTrip` | — |
| `testLazyMigrationFromLegacyItem` | — |

### `S3SignerTests` — S3SignerTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testAWSGetObjectVector` | — |
| `testSha256HexEmpty` | — |

### `S3TransferPlannerTests` — S3TransferPlannerTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testDownloadSingleFile` | — |
| `testDownloadInsideFolderPreservesTree` | — |
| `testUploadSingleFile` | — |
| `testUploadInsideFolderPreservesTree` | — |
| `testUploadEmptyPrefix` | — |
| `testIsWithinAcceptsNormalPaths` | — |
| `testIsWithinRejectsTraversal` | — |
| `testIsWithinDestDirExactMatch` | — |
| `testIsWithinRejectsSiblingDir` | — |

### `S3XMLTests` — S3XMLTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testParseMultipartUploads` | — |
| `testParseMultipartUploadsTruncated` | — |
| `testParseCopyPartETag` | — |
| `testParseCopyPartETagMissing` | — |
| `testParseS3Path` | — |
| `testParseBuckets` | — |
| `testParseListObjects` | — |
| `testParseListObjectsFractionalSeconds` | — |
| `testParseError` | — |
| `testParseUploadId` | — |
| `testParseUploadIdMissing` | — |
| `testCompleteMultipartBody` | — |
| `testEndpointURLPathStyle` | — |
| `testEndpointURLVirtualHosted` | — |
| `testEndpointEncodesSpecialCharsInPath` | The request URL must be sent with the SAME strict RFC3986 encoding the SigV4 signer uses, or the server rejects it with SignatureDoesNotMatch. `$`, `+`, space in a key must reach the wire as %24 / %2B / %20. |
| `testEndpointEncodesQuery` | Query values must be strict-encoded too (slash → %2F, $ → %24). |

### `SFTPSameHostLiveTests` — SFTPSameHostLiveTests.swift

Live SFTP end-to-end test for server-side copy/move within one host (`SFTPFS.serverTransfer`). Proves bytes are transferred entirely on the remote (remote `cp`/`mv`) — a file copied/moved between two remote dirs, plus a folder copied recursively. Skipped unless `SFTP_LIVE=1`. Run with: SFTP_LIVE=1 swift test --filter SFTPSameHostLiveTests

| 用例 | 覆盖点 |
|---|---|
| `testServerSideCopyAndMove` | — |

### `SFTPSameHostTests` — SFTPSameHostTests.swift

Pure-logic tests for the same-SFTP-host server-side copy/move feature: `SFTPConnection.sameHost`, `SFTPFS.shellQuote`, and the remote command builder.

| 用例 | 覆盖点 |
|---|---|
| `testSameHostIgnoresPathNameAndKey` | — |
| `testSameHostFalseOnDifferentHostUserOrPort` | — |
| `testShellQuoteWrapsAndEscapes` | — |
| `testServerCopyCommand` | — |
| `testServerMoveCommandKeepsExistingTrailingSlash` | — |
| `testServerCommandIsInjectionSafe` | — |

### `ServerConnectionTests` — ServerConnectionTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testSMBConnectionDictRoundTrip` | — |
| `testSFTPRoundTripAndKind` | — |
| `testS3RoundTripAndKind` | — |
| `testSMBRoundTripAndKind` | — |
| `testInitRejectsUnknownKind` | — |
| `testStoreAddLoadDelete` | — |
| `testMigrationFromLegacyKeys` | — |
| `testKindLabel` | — |
| `testGrouped` | — |

### `ServerConnectionUpdateTests` — ServerRailTests.swift

`update` is what makes continuous editing safe — the window has no Save button.

| 用例 | 覆盖点 |
|---|---|
| `testRenameMovesTheEntryInsteadOfForkingIt` | — |
| `testEditKeepsPosition` | — |
| `testRenameOntoAnExistingNameDoesNotLeaveTwoRowsWithOneName` | — |
| `testUpdatingSomethingUnknownFallsBackToAdd` | — |
| `testLastConnectedFollowsARename` | — |
| `testDeleteAlsoDropsTheTimestamp` | — |

### `S3SecretResolutionTests` — ServerRailTests.swift

The connect path's secret rule. Its own test because getting it wrong shipped: once the form stopped pre-filling the secret (that Keychain read froze the window on selection), Connect passed the empty field straight through and every saved S3 connection signed with no key.

| 用例 | 覆盖点 |
|---|---|
| `testEmptyFieldFallsBackToTheStoredKey` | — |
| `testATypedKeyWins` | — |
| `testNothingTypedAndNothingStoredIsNil` | — |
| `testStoredIsNotEvaluatedWhenSomethingWasTyped` | The Keychain must not be touched when the field already has a key — reading it is the call that can raise a modal prompt. |

## 文件操作 / 传输 / 队列 / 同步

### `ChecksumTests` — ChecksumTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testKnownVectors` | — |
| `testHashFileStreamsAndReportsBytes` | — |
| `testHashFileCancel` | — |
| `testMissingFileThrows` | — |
| `testAlgorithmForFileName` | — |
| `testAlgorithmForDigestLength` | — |
| `testSerializeSFV` | — |
| `testSerializeMD5Style` | — |
| `testParseRoundTrip` | — |
| `testParseCoreutilsVariants` | — |
| `testParseSkipsGarbage` | — |

### `DeleteConfirmListingTests` — DeleteExtractProviderTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testFewNamesAllListed` | — |
| `testExactlyLimitNoFold` | — |
| `testOverLimitFoldsRemainder` | — |
| `testOneOverLimit` | — |

### `FileOperationConcurrencyTests` — FileOperationConcurrencyTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testUnitsProviderDefersExpansion` | A slow unit-expansion (e.g. S3 listAllKeys) must NOT block the operation from starting — the provider runs after start(), so the progress sheet can appear immediately instead of after the expansion finishes. |
| `testRunsUnitsWithBoundedConcurrencyAndCounts` | — |
| `testFailuresDoNotAbortBatch` | — |
| `testBlockingUnitBodyDoesNotStarveTheMainActor` | A unit whose body does blocking work must not freeze the main actor.  `runConcurrently` schedules every unit with `@MainActor` (it updates completedUnits/failures there), so a unit body that blocks *inline* — `FileManager.copyItem` and friends have no suspension point — owns the main thread for the whole transfer and the UI goes dead. This is exactly how directory sync froze the window: its local↔local branch called copyItem directly instead of hopping off via `Task.detached`, the way every LocalFS transfer method does.  The probe below is a stand-in for the UI: a main-actor timer that must keep ticking while the units run. |
| `testCancelStopsSchedulingFurtherUnits` | Cancelling mid-flight stops scheduling further units.  This is what backs "Close aborts the sync": `SyncDirsSheet.closeWin` calls `cancel()` on the running operation (Move to Background is the way to keep one running without the window — closing is the opposite intent). Units already in flight finish their current file; nothing new is started. |
| `testTransferredBytesAccounting` | The per-Unit `report` reporter accumulates into transferredBytes with no double counting (each unit reports its size exactly once). |

### `QueueToolbarHitTestTests` — QueueToolbarHitTestTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testAccessoryHasRealFrameAndReceivesClicks` | — |

### `RenamedPathTests` — RenamedPathTests.swift

Pure-logic tests for `PanelState.renamedPath` — the in-place rename used to reflect a rename without a network re-list. The S3 folder cases (trailing slash, bucket root) are the easy-to-get-wrong ones.

| 用例 | 覆盖点 |
|---|---|
| `testLocalFileKeepsParent` | — |
| `testS3FileInPrefix` | — |
| `testS3FileAtBucketRoot` | — |
| `testS3FolderKeepsTrailingSlash` | — |
| `testS3FolderAtBucketRootKeepsTrailingSlash` | — |
| `testLocalFolderHasNoTrailingSlash` | — |

### `SelfTransferGuardTests` — SelfTransferGuardTests.swift

F5/F6 must refuse a transfer whose destination equals the source location: copying/moving an item onto itself (dest dir == item's parent dir) would make LocalFS's overwrite path delete the source first (data loss), and copying a folder into itself/its own subfolder can never terminate sensibly.

| 用例 | 覆盖点 |
|---|---|
| `testFileIntoOwnParentIsBlocked` | — |
| `testTrailingSlashOnDestIsNormalized` | — |
| `testDifferentDirIsAllowed` | — |
| `testFolderIntoItselfIsBlocked` | — |
| `testFolderIntoOwnSubfolderIsBlocked` | — |
| `testSiblingWithCommonNamePrefixIsAllowed` | — |
| `testMixedSelectionReturnsOnlyOffenders` | — |
| `testS3StylePaths` | — |
| `testRootDestination` | — |

### `SyncCompareTests` — SyncCompareTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testEqualWhenSameSizeAndTime` | — |
| `testLeftNewerByTime` | — |
| `testIgnoreTimeTreatsSameSizeAsEqual` | — |
| `testLeftOnlyRightOnly` | — |

### `SyncDirsJunkTests` — SyncDirsJunkTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testMetadataFiles` | — |
| `testEditorAndDownloadTemp` | — |
| `testSystemAndVCSAndBuildDirs` | — |
| `testRealFilesAreNotJunk` | — |

### `SyncScanTests` — SyncScanTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testParseFindOutput` | — |
| `testParseFindOutputSkipsMalformed` | — |
| `testS3RelMapStripsPrefix` | — |
| `testScanLocalDir` | — |

### `TransferDestinationTests` — TransferDestinationTests.swift

TC-style destination parsing for the Copy/Move confirm dialog: single item → the field is prefilled with `<destDir>/<name>` and editing the last component renames on transfer; multiple items → prefilled with `<destDir>/*.*` and the mask is stripped back to the directory.

| 用例 | 覆盖点 |
|---|---|
| `testMultiMaskStripsToDirectory` | — |
| `testMultiPlainDirectory` | — |
| `testMultiTrailingSlash` | — |
| `testSingleUneditedDefaultKeepsName` | — |
| `testSingleEditedLastComponentRenames` | — |
| `testSingleUneditedDefaultIsNotDirProbed` | — |
| `testSingleExistingDirectoryTargetMeansCopyInto` | — |
| `testSingleTrailingSlashForcesDirectory` | — |
| `testSingleMaskStripsToDirectory` | — |
| `testRootDestination` | — |
| `testSingleRenameAtRoot` | — |
| `testTransferNameFlattensDisplayPathToLeaf` | Regression: copying a single file from a search-results / branch-view listing, whose `name` is a display *path* ("subA/report.docx"). Feeding the raw path-name into the prefill/parse mis-detects a rename into a non-existent "<dst>/subA" sub-folder — the copy then fails with "file doesn't exist". The pipeline flattens `name` to its leaf first. |
| `testTransferNameLeavesPlainLeafUntouched` | — |
| `testDisplayPathNameMisparsesAsSubfolderRename` | The pre-fix bug, pinned: the raw display-path name parses as a rename into a sub-folder that doesn't exist at the destination. |
| `testFlattenedNameParsesAsFlatCopyIntoDestDir` | The fix end-to-end: flattening the name to its leaf before prefill/parse yields a plain flat copy into the destination directory, no rename. |

### `SelfTransferRenameTests` — TransferDestinationTests.swift

Rename-aware self-transfer guard: copying a file to its own directory under a NEW name is legitimate (TC allows it); under the same name it stays blocked.

| 用例 | 覆盖点 |
|---|---|
| `testRenameInSameDirIsAllowed` | — |
| `testSameNameViaRenameIsBlocked` | — |
| `testFolderIntoItselfStillBlockedWithRename` | — |

### `RenameOnTransferPathTests` — TransferDestinationTests.swift

Rename-on-transfer threading through the pure backend path builders.

| 用例 | 覆盖点 |
|---|---|
| `testS3DownloadSingleFileRename` | — |
| `testS3DownloadFolderRenameReplacesRootOnly` | — |
| `testS3UploadSingleFileRename` | — |
| `testS3UploadFolderRenameReplacesRootOnly` | — |
| `testSFTPServerCopyCommandRename` | — |
| `testSFTPServerMoveCommandWithoutRenameUnchanged` | — |

### `TransferProviderTests` — TransferProviderTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testLocalCopyFlatUsesByteMode` | — |
| `testLocalCopyExpandedUsesStructuredIndeterminate` | — |
| `testLocalCopyArchiveSourceUsesStructuredIndeterminate` | — |
| `testLocalMove` | — |
| `testSFTPDownloadByteMode` | — |
| `testSFTPUploadIndeterminate` | — |
| `testS3DownloadCountModeConcurrent` | — |
| `testS3UploadVerb` | — |

### `TransferQueueAdoptTests` — TransferQueueAdoptTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testAdoptOnIdleSetsCurrentWithoutRestart` | Adopting a running op on an IDLE queue makes it `current` synchronously, fires onChange, does NOT restart it (its unit runs exactly once), and the chained onComplete clears `current` when it finishes. |
| `testAdoptRunsOnFinishOnCompletion` | The adopted op's onFinish runs when it completes. |
| `testAdoptOfAlreadyCompleteOpRunsOnFinishOnceAndDoesNotStick` | Fix 1 regression guard: if the op already completed before adopt() is called (the ~100ms race between isComplete=true and the modal timer dismiss), adopt must run onFinish immediately, NOT set it as current, and fire onChange so the drain logic can close the queue window. |
| `testAdoptWhileBusyDoesNotClobberCurrent` | Adopting a running op while another job is already `current` must NOT overwrite/clear that current op; the adopted op finishes independently. |

## 面板 / 列表 / 视图 / 搜索

### `ColumnSetsTests` — ColumnSetsTests.swift

Named column sets — uses the real UserDefaults key, so snapshot/restore.

| 用例 | 覆盖点 |
|---|---|
| `testRoundTrip` | — |
| `testSaveReplacesSameName` | — |
| `testRemove` | — |
| `testGarbageEntriesSkipped` | — |

### `DriveJumpTests` — DriveJumpTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testLastVisitedDirectoryWins` | — |
| `testVanishedLastPathFallsThrough` | — |
| `testOtherPanelSameVolume` | — |
| `testOtherPanelOnDifferentVolumeIsIgnored` | — |
| `testHomeVolumeFallsBackToHome` | — |
| `testNoMemoryNoOtherNotHomeVolume` | — |
| `testStaleLastPathOnWrongVolumeIsIgnored` | — |
| `testLastPathPriorityOverHomeOnHomeVolume` | — |

### `FavoritesTests` — FavoritesTests.swift

FavoriteItem model + legacy migration + menu grouping. Uses the real UserDefaults keys, so each test snapshots and restores them.

| 用例 | 覆盖点 |
|---|---|
| `testDisplayNameFallsBackToLeaf` | — |
| `testLegacyMigration` | — |
| `testRoundTripPreservesNameAndGroup` | — |
| `testAddRemoveContains` | — |
| `testGroupedOrdering` | — |

### `FileColumnLayoutTests` — FileColumnLayoutTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testNameFlexFillsRemaining` | — |
| `testColumnAtXAndDivider` | — |
| `testWidthOverridePersisted` | — |

### `FileColumnWidthsTests` — FileColumnWidthsTests.swift

TDD for AppSettings.columnWidths — round-trip via UserDefaults. These tests run against the shared UserDefaults suite and clean up after themselves.

| 用例 | 覆盖点 |
|---|---|
| `testDefaultIsEmpty` | Default must be an empty dictionary (no stored value). |
| `testSingleKeyPersists` | Setting a single key must round-trip with the same CGFloat value. |
| `testRoundTrip` | Full round-trip: multiple keys, values survive a get → set → get cycle. |
| `testOverwrite` | Overwriting with a new dict must fully replace (not merge) the old value. |
| `testSetEmpty` | Setting to empty dict must produce an empty result on read-back. |

### `FileIconProviderTests` — FileIconProviderTests.swift

Async integration tests for FileIconProvider. These tests use real temp files (not mocks) and XCTestExpectation so they are deterministic and don't rely on sleep.

| 用例 | 覆盖点 |
|---|---|
| `testIconForUncachedFileReturnsImmediately` | — |
| `testOnReadyFiresAndCacheIsPopulated` | — |
| `testClearEmptiesCacheAndOnReadyFiresAgain` | — |
| `testSameExtensionSharesCachedIcon` | — |
| `testCancelOffscreenDropsPendingRequests` | — |

### `FileRowGeometryTests` — FileRowGeometryTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testRowHeightFull` | — |
| `testRowHeightBrief` | — |
| `testRowHeightThumbnails` | — |
| `testRowHeightFullCustomIconSize` | — |
| `testRowRectRow0` | — |
| `testRowRectRow1` | — |
| `testRowRectRow3` | — |
| `testRowAtMiddleOfRow1` | — |
| `testRowAtNegativeY` | — |
| `testRowAtYBeyondCount` | — |
| `testRowAtExactlyZero` | — |
| `testRowAtLastPixelOfRow0` | — |
| `testRowAtZeroCount` | — |
| `testVisibleRowsBasic` | — |
| `testVisibleRowsClampedToCount` | — |
| `testVisibleRowsZeroCount` | — |
| `testVisibleRowsEmptyRect` | — |
| `testVisibleRowsClampsLower` | — |
| `testDisclosureRectDepth0WithinRowY` | — |
| `testDisclosureRectShiftsRightWithDepth` | — |
| `testDisclosureRectIsSmall` | — |

### `FileSearchTests` — FileSearchTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testSubstringMatchIsCaseInsensitive` | — |
| `testWildcardMatch` | — |
| `testStarMeansEverything` | — |
| `testRegexMatch` | — |
| `testFindGlobPushDown` | — |
| `testContentMatchesAcrossEncodings` | — |
| `testBinaryFilesNeverMatch` | — |
| `testBOMDefeatsTheNULHeuristic` | — |
| `testEmptyNeedleMatchesAnything` | — |
| `testListCommandQuotesAndScopes` | — |
| `testMaxdepthPrecedesTests` | — |
| `testGrepCommandUsesExecPlus` | — |
| `testParseListLine` | — |
| `testS3CandidatePathsAreBucketAbsolute` | — |
| `testS3CandidatesSkipFolderMarkersAndHonourSubfolders` | — |
| `testS3CandidatesMatchOnTheLeafName` | — |
| `testRemoteSearchResultItemsUseSuppliedMetadata` | — |
| `testRemoteSearchResultItemsFallBackToLeafOutsideBase` | — |
| `testWalkRecursesAndMatchesOnTheLeafName` | — |
| `testWalkStopsAtOneLevelWhenSubfoldersIsOff` | — |
| `testWalkPropagatesTheFirstListingFailure` | The first listing failing means the device is gone; that has to surface rather than look like "no matches". |
| `testWalkSkipsDeeperUnreadableFolders` | …but one unreadable folder deeper in must not abort the whole search. |
| `testParseDuSize` | — |
| `testRemoteSizeConcurrencyIsBounded` | — |
| `testLocalNameSearchRecursesAndReportsProgress` | — |
| `testLocalContentSearchSkipsBinariesAndFindsSubfolders` | — |
| `testSubfoldersOffStaysShallow` | — |
| `testCancellationStopsTheWalk` | — |

### `ListerSearchTests` — ListerSearchTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testCrossChunkBoundaryMatch` | — |
| `testNextPrevSemanticsAndFirstPrevRefused` | — |
| `testOverlappingMatches` | — |
| `testPatternEqualsChunkSize` | — |
| `testASCIICaseFolding` | — |
| `testHexPatternParsing` | — |
| `testFoldCaseIsPartOfCacheKeySemantics` | — |
| `testMatchCacheCapTruncatesButKeepsForwardSemantics` | — |
| `testParseHexPatternRejectsSignPrefix` | — |

### `PanelStatePerfTests` — PanelStatePerfTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testItemsVersionIncrementsOnAssignment` | — |
| `testItemsVersionIncrementsByTwoAfterTwoAssignments` | — |
| `testIsRemoteFalseForLocalPath` | — |
| `testIsRemoteTrueWhenSFTPConnected` | — |
| `testIsRemoteTrueWhenS3Connected` | — |
| `testStatusTextTotalExcludesParentEntry` | — |
| `testStatusTextNoSelectionUsesSimpleForm` | — |
| `testStatusTextWithSelectionShowsCount` | — |
| `testStatusTextLargeArrayNoSelectionIsStructurallyCorrect` | — |

### `QuickFilterTests` — QuickFilterTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testPinyinInitials` | — |
| `testPinyinMatch` | — |
| `testLiteralSubstring` | — |
| `testEmptyQueryMatchesAll` | — |

### `TabClosePlanTests` — TabClosePlanTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testCloseOthers` | — |
| `testCloseOthersSkipsLocked` | — |
| `testCloseOthersKeepItselfLockedStillKept` | — |
| `testCloseOthersAllLocked` | — |
| `testCloseRight` | — |
| `testCloseRightSkipsLocked` | — |
| `testCloseRightNothingToTheRight` | — |

### `TabSessionTests` — TabSessionTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testEncodeDecodeRoundtrip` | — |
| `testDecodeUnreachablePathFallsBackToHome` | — |
| `testDecodeGoneLockedFolderDropsMemoryNotLock` | — |
| `testDecodeIgnoresLockedPathOnUnlockedTab` | — |
| `testEncodeOmitsLockedPathWhenNil` | — |
| `testDecodeGarbageReturnsEmpty` | — |
| `testDecodeDropsEntriesWithoutPath` | — |
| `testClampActive` | — |

## Lister 查看器 / 渲染

### `DiagramSupportTests` — DiagramSupportTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testFenceLanguageMapping` | — |
| `testWrappedPlantUMLAddsEnvelope` | — |
| `testWrappedPlantUMLKeepsExistingEnvelope` | — |
| `testWrappedPlantUMLTolerantOfLeadingBlank` | — |
| `testSanitizeStripsScriptBlocks` | — |
| `testSanitizeStripsEventHandlers` | — |
| `testSanitizeStripsJavascriptHref` | — |
| `testSanitizeDropsXMLPrologAndDoctype` | — |
| `testSanitizeKeepsInnocentSVG` | — |
| `testCacheHitAndEviction` | — |
| `testCacheKeyDistinguishesKindAndTheme` | — |
| `testCacheOverwriteSameKeyDoesNotEvict` | — |

### `HexFormatterTests` — HexFormatterTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testFullRow` | — |
| `testPartialTailRowPadsHexColumn` | — |
| `testNonPrintableDots` | — |
| `testOffsetDigits` | — |

### `InternalViewerNavTests` — InternalViewerNavTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testNext` | — |
| `testNextClampAtEnd` | — |
| `testPrev` | — |
| `testPrevClampAtStart` | — |
| `testEmpty` | — |
| `testSingle` | — |

### `ListerSourceTests` — ListerSourceTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testReadMiddleAndClampAtEOF` | — |
| `testInitFailsOnMissingFile` | — |
| `testDecoderCarriesSplitUTF8Character` | — |
| `testDecoderFinalFlushFallsBackLatin1` | — |

### `MarkdownToHTMLTests` — MarkdownToHTMLTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testHeadings` | — |
| `testParagraphLazyJoin` | — |
| `testFencedCodeBlockHighlighted` | — |
| `testFencedCodeBlockUnknownLangPlain` | — |
| `testUnterminatedFenceRunsToEnd` | — |
| `testBlockquoteNested` | — |
| `testUnorderedAndOrderedLists` | — |
| `testNestedListByIndent` | — |
| `testTaskList` | — |
| `testHorizontalRule` | — |
| `testRawHTMLEscaped` | — |
| `testEmptyInput` | — |
| `testDeeplyNestedBlockquoteDoesNotCrash` | — |
| `testCRLFNormalized` | — |
| `testEmphasis` | — |
| `testInlineCodeNotParsedInside` | — |
| `testBackslashEscape` | — |
| `testLink` | — |
| `testNestedEmphasisInStrong` | — |
| `testTableWithAlignment` | — |
| `testLocalImageBecomesDataURI` | — |
| `testMissingImagePlaceholder` | — |
| `testRemoteImagePassthrough` | — |
| `testImagePathTraversalBlocked` | — |
| `testImageSiblingDirectoryPrefixBlocked` | — |
| `testImageSymlinkEscapeBlocked` | — |
| `testMermaidFenceBecomesPlaceholder` | — |
| `testPlantUMLFenceAliasesAndOrdering` | — |
| `testDiagramInsideBlockquoteCollected` | — |
| `testNormalFenceUnaffectedAndRenderWrapperCompatible` | — |
| `testSubstituteSVGReplacesWholePlaceholder` | — |
| `testSubstitutePlantUMLGetsWhiteCardClass` | — |
| `testSubstituteFailureKeepsCodeAndAddsEscapedNote` | — |
| `testSubstituteMissingResultLeavesPlaceholderUntouched` | — |
| `testLiteralPlaceholderTextInProseNotSubstituted` | — |

### `SyntaxHighlighterTests` — SyntaxHighlighterTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testKeywordWordBoundary` | — |
| `testStringWithEscape` | — |
| `testUnterminatedStringStopsAtEOL` | — |
| `testLineComment` | — |
| `testBlockCommentSpansLines` | — |
| `testUnterminatedBlockCommentRunsToEnd` | — |
| `testNumbers` | — |
| `testYAMLKeyRule` | — |
| `testMarkdownLineRules` | — |
| `testUTF16RangesWithCJK` | — |
| `testEmptyInput` | — |
| `testYAMLCommentLineWithColonIsNotKey` | — |
| `testCRLFLineEndings` | — |

### `ViewerModeChooserTests` — ViewerModeChooserTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testMediaExtensionsGoToPreview` | — |
| `testNULByteMeansHex` | — |
| `testUTF16BOMBeatsNULSniff` | — |
| `testPlainTextAndEmpty` | — |
| `testNonUTF8GarbageWithoutNULOrBOMFallsBackToText` | — |
| `testMarkdownRoutesToPreviewKeepingEncoding` | — |
| `testMarkdownWithNULStillSniffsToHex` | — |
| `testEmptyMarkdownStaysText` | — |
| `testDiagramSourceFilesRouteToPreviewWithEncoding` | — |
| `testBinaryDotPumlStillGoesHex` | — |

## 设置 / 快捷键 / 本地化 / 其它

### `AppearanceTests` — AppearanceTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testAppKitNameMapping` | — |
| `testRawValueRoundTrip` | — |
| `testAllCasesOrder` | — |
| `testSettingDefaultsToSystem` | Unknown / absent stored value resolves to .system. |

### `ColorGridLayoutTests` — ColorGridLayoutTests.swift

Reflow geometry for the Appearance pane's colour-well grids.

| 用例 | 覆盖点 |
|---|---|
| `testNarrowWidthFallsBackToOneColumn` | — |
| `testWidthForExactlyTwoColumns` | — |
| `testWidthForThreeColumns` | — |
| `testColumnsNeverExceedItemCount` | — |
| `testDegenerateInputs` | — |
| `testRowsRoundUp` | — |
| `testFillsColumnFirst` | Folding must keep the vertical reading order: the first column holds the first N items top-to-bottom, not every other item. |
| `testOddCountLeavesTheLastColumnShort` | — |
| `testOriginStepsByCellAndRow` | — |
| `testHeightTracksTheColumnCount` | — |

### `DiffEngineTests` — DiffEngineTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testIdenticalFiles` | — |
| `testBothEmpty` | — |
| `testEmptyAgainstContent` | — |
| `testInsertion` | — |
| `testDeletion` | — |
| `testChangePairsDeletionWithInsertion` | — |
| `testUnbalancedChangeRun` | — |
| `testAlignmentCoversAllLines` | Every left line number 1..n and right line number 1..m must appear exactly once across the aligned rows — no drops, no duplicates. |
| `testFallbackOnHugeDistance` | Completely disjoint big inputs blow the edit-distance cap and use the naive positional fallback — alignment must still cover every line. |

### `DiskSpaceNoteTests` — DiskSpaceNoteTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testNoteIsEmptyWhenCapacityUnreadable` | — |
| `testNoteMentionsBothFreeAndTotal` | — |
| `testNoteChangesWhenFreeSpaceChanges` | — |
| `testRefreshFillsNoteForLocalPath` | — |
| `testRefreshClearsNoteWhenPanelGoesRemote` | — |
| `testRefreshDropsReadingFromAPathWeLeft` | — |

### `DuplicateScanTests` — DuplicateScanTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testEmptyOptionsGroupsNothing` | — |
| `testSameNameIsCaseInsensitive` | — |
| `testSameNameAndSizeMustMatchBoth` | — |
| `testSameSizeOnly` | — |
| `testSameContentHashesOnlyWithinSizeBuckets` | — |
| `testUnreadableFileDroppedFromContentGroups` | — |
| `testGroupsAndMembersSortedByPath` | — |
| `testCancellationReturnsEmpty` | — |
| `testFindDuplicatesOnDisk` | End-to-end against a real directory tree via findDuplicates. |

### `EncodingDetectorTests` — EncodingDetectorTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testBOMs` | — |
| `testASCIIAndUTF8Chinese` | — |
| `testGB18030RoundTrip` | — |
| `testTruncatedTailDoesNotDemoteToFallback` | — |
| `testGarbageNeverFails` | — |

### `FileCodecTests` — FileCodecTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testBase64RoundTripAndWrapping` | — |
| `testDecodeBase64ToleratesHeadersAndWhitespace` | — |
| `testUUEncodeKnownVector` | — |
| `testUURoundTripVariousSizes` | — |
| `testUUDecodeToleratesJunkAroundBody` | — |
| `testUUDecodeRejectsMissingBegin` | — |
| `testDetect` | — |

### `FileDropTargetTests` — FileDropTargetTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testFolderRowIsTheDestination` | — |
| `testDotDotRowGoesToParent` | — |
| `testDotDotAtVolumeRootStaysAtRoot` | — |
| `testFileRowFallsBackToCurrentDirectory` | — |
| `testPackageBundleIsNotADropTarget` | .app/.framework 等 bundle 是目录，但往里投文件会破坏签名 —— 不作落点。 |
| `testNilRowFallsBackToCurrentDirectory` | — |
| `testOutOfRangeRowFallsBackToCurrentDirectory` | — |
| `testNestedFolderRowUsesItsOwnPath` | — |
| `testDotDotUsesCurrentPathNotItemPath` | ".." 的落点必须来自 currentPath，而不是该行自己的 path —— 两者在生产中一致，这条用例把契约钉死，防止将来改用 item.path。 |
| `testEmptyItemsFallsBackToCurrentDirectory` | — |
| `testTrailingSlashOnCurrentPathStillResolvesParent` | currentPath 带尾斜杠时 ".." 仍要落到正确的父目录 （命令行栏 / GoToFolder / 收藏项都可能存进带斜杠的路径）。 |
| `testDotDotIsRecognizedAtAnyRow` | ".." 的判定看的是名字而非行号——分支视图/过滤列表里它未必在第 0 行。 |
| `testPlainFolderNamedLikeAPackageIsAlsoExcluded` | 名字像 bundle 的普通目录也被当作 package 挡掉——扩展名判定是 刻意的近似，宁可少投放也不能往真 bundle 里灌文件。 |

### `GridGeometryTests` — GridGeometryTests.swift

Brief-mode multi-column grid math (column-major flow, horizontal scroll).

| 用例 | 覆盖点 |
|---|---|
| `testRowsPerColumn` | — |
| `testRowRectColumnMajor` | — |
| `testHitTestInvertsRowRect` | — |
| `testVisibleRowsCoversDirtyColumns` | — |
| `testContentSize` | — |
| `testDisclosureRectOffsetsByCell` | — |

### `HelpContentTests` — HelpContentTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testShortcutGroupsWellFormed` | Shortcut data is well-formed: groups non-empty, key strings present. |
| `testURLsValid` | — |

### `LanguageSpecTests` — LanguageSpecTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testExtensionMappingCoreLanguages` | — |
| `testUnknownExtensionIsNil` | — |
| `testFieldShapes` | — |
| `testRegistryCompleteness` | — |
| `testAllSpecsHaveNonEmptyName` | — |

### `LocalizerTests` — LocalizerTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testSystemResolution` | — |
| `testJsonNameMapping` | — |

### `MaterializedCacheTests` — MaterializedCacheTests.swift

F3 materializes remote / inside-archive items into a temp file before showing them. Re-viewing the same file (⌘↑ / ⌘↓ back and forth) must reuse that file instead of paying the download / decompression again — on a solid 7z a single entry costs a full pass over the archive.

| 用例 | 覆盖点 |
|---|---|
| `testSlugIsStableForTheSameItem` | — |
| `testSlugChangesWithPathSizeOrDate` | Any change to identity, size or mtime must land in a DIFFERENT folder, so a changed remote file can never be served from a stale cached copy. |
| `testFreshOnlyWhenFileExistsWithTheExpectedSize` | — |

### `MirrorLocationLiveTests` — MirrorLocationLiveTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testOpenInOtherPanelJoinsSFTPSession` | — |

### `MirrorLocationTests` — MirrorLocationTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testMirrorFromSFTPJoinsRemoteSession` | — |
| `testMirrorWhenAlreadySameSFTPJustNavigates` | — |
| `testMirrorFromS3JoinsRemoteSession` | — |
| `testMirrorFromLocalLeavesTargetSFTP` | — |
| `testMirrorFromLocalLeavesTargetS3` | — |

### `PrivilegedRunnerTests` — PrivilegedRunnerTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testShellQuoteEscapesSingleQuotes` | — |
| `testAppleScriptQuoteEscapesBackslashAndQuote` | — |
| `testCommandsPerOperationType` | — |
| `testPermissionDeniedDetection` | — |

### `ProgressSpeedTests` — ProgressSpeedTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testByteRateShowsPerSecond` | — |
| `testByteRateZeroShowsDash` | — |
| `testFilesPerSecondFallback` | — |
| `testFilesRateZeroShowsDash` | — |
| `testByteModeIgnoresFilesRate` | — |

### `ServerRailTests` — ServerRailTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testSubtitleTellsSimilarlyNamedEntriesApart` | — |
| `testSectionsAndEmptyStates` | — |
| `testDeviceSectionAppearsWhileScanning` | — |
| `testFilterKeepsOnlyMatchesAndDropsEmptyHeaders` | — |
| `testFilterMatchesTheSubtitleToo` | — |
| `testNoMatchesGivesOneNote` | — |
| `testOnlyEntriesAreSelectable` | — |

### `ServerURLTests` — ServerURLTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testSMBBasic` | — |
| `testSMBWithUserPortShare` | — |
| `testSMBHostOnly` | — |
| `testSFTP` | — |
| `testRejectsUnsupportedAndGarbage` | — |

### `SettingsCategoryTests` — SettingsCategoryTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testRegistryHasEightCategoriesInOrder` | — |
| `testCategoryIndexResolves` | — |
| `testIDsAreUnique` | — |

### `SettingsResetTests` — SettingsResetTests.swift

The "Reset to Defaults" key tables. These run against a private UserDefaults suite, never the app's own domain, so a failing test can't wipe the developer's settings.

| 用例 | 覆盖点 |
|---|---|
| `testEveryResettableCategoryOwnsSomething` | — |
| `testFavoritesAreNotResettable` | — |
| `testProtectedKeysAreNeverInAnyCategory` | The whole promise of the feature: a preferences reset never touches data. |
| `testCategoryKeysAreDisjoint` | — |
| `testResetCategoryRemovesOnlyItsOwnKeys` | — |
| `testResetShortcutsClearsPrefixedKeysOnly` | — |
| `testResetUnknownCategoryIsANoOp` | — |
| `testResetAllClearsPreferencesAndKeepsData` | — |
| `testCommandLineRoleDefaultsAreDistinct` | — |
| `testCommandLineColorKeysAreCoveredByTheAppearanceReset` | — |

### `ToolbarCommandTests` — ToolbarCommandTests.swift

| 用例 | 覆盖点 |
|---|---|
| `testPlaceholders` | — |
| `testPercentEscapes` | — |
| `testShellQuote` | — |
| `testCustomButtonRoundTripAndValidation` | — |
| `testStoreRoundTrip` | — |

### `VolumeEjectableTests` — VolumeEjectableTests.swift

`Volumes.isEjectable` — which mounted volumes get an ⏏ Eject affordance.

| 用例 | 覆盖点 |
|---|---|
| `testBootVolumeNeverEjectable` | — |
| `testInternalSecondaryVolumeNotEjectable` | — |
| `testUSBStickRemovable` | — |
| `testExternalHardDriveNeitherEjectableNorRemovable` | The case that motivated `internalStorage`: USB/Thunderbolt hard drives report ejectable=false AND removable=false — only internal=false catches them. |
| `testMountedDMGEjectable` | — |
| `testNetworkMountEjectable` | — |
| `testAllNilNotEjectable` | nil resource values (unknown) must not make a volume ejectable. |

## 最近一次全量执行

- 日期：2026-09-05（macOS，arm64，`swift test`）
- 结果：执行 625 个用例，0 个失败，15 个跳过
- 跳过的全部是需要真实远端/设备的 Live 测试（未设环境变量即自动跳过）：
  - `AndroidSearchLiveTests.testFindFilesOnDevice`
  - `MirrorLocationLiveTests.testOpenInOtherPanelJoinsSFTPSession`
  - `RemoteSearchLiveTests.testCancellationReturnsPromptly`
  - `RemoteSearchLiveTests.testRemoteFindFiles`
  - `S3DirectorySizeLiveTests.testDirectorySizeSumsThePrefix`
  - `S3LiveTests.testMultipartRoundTrip`
  - `S3LiveTests.testS3FileRename`
  - `S3LiveTests.testS3MultipartCopy`
  - `S3LiveTests.testS3RenameUIFlow`
  - `S3LiveTests.testS3UploadProgressIsRealtime`
  - `S3SearchLiveTests.testRemoteFindFiles`
  - `S3SecretStoreLiveTests.testLazyMigrationFromLegacyItem`
  - `S3SecretStoreLiveTests.testSaveLoadDeleteRoundTrip`
  - `SFTPDirectorySizeLiveTests.testDirectorySizeMatchesTheFilesWePut`
  - `SFTPSameHostLiveTests.testServerSideCopyAndMove`
- 执行前后核对：`net.qian.double-finder` 的 UserDefaults 导出无差异，钥匙串 `double-finder / S3Secrets` 条目仍在。
