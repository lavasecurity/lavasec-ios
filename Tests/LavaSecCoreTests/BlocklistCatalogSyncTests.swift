import XCTest
@testable import LavaSecCore

final class BlocklistCatalogSyncTests: XCTestCase {
    func testCatalogDecodesWorkerDocument() throws {
        let json = """
        {
          "schema_version": 2,
          "catalog_version": "20260516T044815Z",
          "generated_at": "2026-05-16T04:48:15.772Z",
          "sources": [
            {
              "id": "hagezi-multi-pro-mini",
              "name": "HaGeZi Multi PRO mini",
              "category": "ads_tracking",
              "risk_level": "normal",
              "default_enabled": true,
              "license_name": "GPL-3.0",
              "attribution": "HaGeZi DNS Blocklists",
              "project_url": "https://github.com/hagezi/dns-blocklists",
              "source_url": "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.mini-onlydomains.txt",
              "redistribution_mode": "source_url_only",
              "parse_format": "auto",
              "license_text_url": "https://www.gnu.org/licenses/gpl-3.0.en.html",
              "notice_url": null,
              "version_id": "hagezi-multi-pro-mini-20260516T042929Z-7fe23d076bbf",
              "entry_count": 78533,
              "byte_size": 1564206,
              "source_hash": "c9d2f17272119ecc571965d5d69228151b1c793b5ba535ff0a14b3a2faf3003f",
              "accepted_source_hashes": [
                {
                  "sha256": "c9d2f17272119ecc571965d5d69228151b1c793b5ba535ff0a14b3a2faf3003f",
                  "byte_size": 1564206,
                  "entry_count": 78533,
                  "reviewed_at": "2026-05-16T04:30:00.000Z",
                  "status": "accepted"
                }
              ],
              "normalized_hash": "7fe23d076bbf56cd7908d6315a10f2c697bfe4a9b8c6c638b3276e825b451a68",
              "published_at": "2026-05-16T04:29:31.401+00:00"
            }
          ],
          "guardrails": []
        }
        """

        let catalog = try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(
            BlocklistCatalog.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(catalog.schemaVersion, 2)
        XCTAssertEqual(catalog.catalogVersion, "20260516T044815Z")
        XCTAssertEqual(catalog.sources.first?.id, "hagezi-multi-pro-mini")
        XCTAssertEqual(catalog.sources.first?.entryCount, 78_533)
        XCTAssertEqual(catalog.sources.first?.sourceURL.host, "raw.githubusercontent.com")
        XCTAssertEqual(catalog.sources.first?.acceptedSourceHashes.first?.sha256, "c9d2f17272119ecc571965d5d69228151b1c793b5ba535ff0a14b3a2faf3003f")
    }

    func testCatalogDecodesSourceURLOnlyMetadata() throws {
        let json = """
        {
          "schema_version": 2,
          "catalog_version": "20260525T000000Z",
          "generated_at": "2026-05-25T00:00:00.000Z",
          "sources": [
            {
              "id": "hagezi-multi-light",
              "name": "HaGeZi Multi Light",
              "category": "ads_tracking",
              "risk_level": "normal",
              "default_enabled": false,
              "license_name": "GPL-3.0",
              "attribution": "HaGeZi DNS Blocklists",
              "project_url": "https://github.com/hagezi/dns-blocklists",
              "source_url": "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/light-onlydomains.txt",
              "redistribution_mode": "source_url_only",
              "parse_format": "auto",
              "license_text_url": "https://www.gnu.org/licenses/gpl-3.0.en.html",
              "notice_url": null,
              "version_id": "example",
              "entry_count": 2,
              "byte_size": 42,
              "source_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "accepted_source_hashes": [
                {
                  "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                  "byte_size": 42,
                  "entry_count": 2,
                  "reviewed_at": "2026-05-25T00:00:00.000Z",
                  "status": "accepted"
                },
                {
                  "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                  "byte_size": 40,
                  "entry_count": 2,
                  "reviewed_at": "2026-05-24T00:00:00.000Z",
                  "status": "accepted"
                }
              ],
              "normalized_hash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "published_at": "2026-05-25T00:00:00.000Z"
            }
          ],
          "guardrails": []
        }
        """

        let catalog = try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(
            BlocklistCatalog.self,
            from: Data(json.utf8)
        )

        let source = try XCTUnwrap(catalog.sources.first)
        XCTAssertEqual(source.redistributionMode, "source_url_only")
        XCTAssertEqual(source.parseFormat, .auto)
        XCTAssertEqual(source.acceptedSourceHashes.map(\.sha256), [
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        ])
        XCTAssertEqual(source.licenseTextURL?.host, "www.gnu.org")
        XCTAssertNil(source.noticeURL)
    }

    func testCatalogRejectsLegacyMetadataInsteadOfUsingArtifactURLs() throws {
        let json = """
        {
          "schema_version": 1,
          "catalog_version": "20260517T074259Z",
          "generated_at": "2026-05-17T07:42:59.047Z",
          "sources": [
            {
              "id": "adguard-dns-filter",
              "name": "AdGuard DNS Filter",
              "category": "ads_tracking",
              "risk_level": "advanced",
              "default_enabled": false,
              "license_name": "GPL-3.0",
              "attribution": "AdGuard DNS Filter",
              "project_url": "https://github.com/AdguardTeam/AdGuardSDNSFilter",
              "source_url": "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt",
              "version_id": "adguard-dns-filter-20260516T092156Z-75ee2257dbde",
              "entry_count": 164446,
              "byte_size": 3960152,
              "source_hash": "07371ae4a3326a7d3289de245e9be24425f7ac1a91a8da02b4c03167f683e1db",
              "normalized_hash": "75ee2257dbdee7796a6e10bd66d26c232f52d6173ab88ce745bcad6e6f26b597",
              "published_at": "2026-05-16T09:21:59.227+00:00",
              "download_path": "https://api.lavasecurity.app/v1/blocklists/adguard-dns-filter/example/domains.txt"
            }
          ],
          "guardrails": []
        }
        """

        XCTAssertThrowsError(
            try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(
                BlocklistCatalog.self,
                from: Data(json.utf8)
            )
        )
    }

    func testSHA256HexMatchesKnownPayload() {
        let data = Data("ads.example.com\n".utf8)

        XCTAssertEqual(
            BlocklistCatalogSynchronizer.sha256Hex(of: data),
            "3d439fc6b959423465db4238e7df7ebda7d47a3a9e123ce899faed5e49e4b1eb"
        )
    }

    func testCatalogDoesNotRewriteUpstreamSourceURLsForFallbackCatalogOrigins() throws {
        let source = CatalogBlocklistSource(
            id: "hagezi-multi-pro-mini",
            name: "HaGeZi Multi PRO mini",
            category: "ads_tracking",
            riskLevel: "normal",
            defaultEnabled: true,
            licenseName: "GPL-3.0",
            attribution: "HaGeZi DNS Blocklists",
            projectURL: URL(string: "https://github.com/hagezi/dns-blocklists")!,
            sourceURL: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.mini-onlydomains.txt")!,
            versionID: "hagezi-multi-pro-mini-20260516T042929Z-7fe23d076bbf",
            entryCount: 78_533,
            byteSize: 1_564_206,
            sourceHash: "c9d2f17272119ecc571965d5d69228151b1c793b5ba535ff0a14b3a2faf3003f",
            acceptedSourceHashes: [
                CatalogAcceptedSourceHash(
                    sha256: "c9d2f17272119ecc571965d5d69228151b1c793b5ba535ff0a14b3a2faf3003f",
                    byteSize: 1_564_206,
                    entryCount: 78_533,
                    reviewedAt: Date(timeIntervalSince1970: 1_768_385_400)
                )
            ],
            normalizedHash: "7fe23d076bbf56cd7908d6315a10f2c697bfe4a9b8c6c638b3276e825b451a68",
            publishedAt: Date(timeIntervalSince1970: 1_768_385_371),
            redistributionMode: "source_url_only",
            parseFormat: .auto,
            licenseTextURL: URL(string: "https://www.gnu.org/licenses/gpl-3.0.en.html"),
            noticeURL: nil
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260516T044815Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: [source]
        )

        let encoded = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        let decoded = try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self, from: encoded)

        XCTAssertEqual(decoded.sources.first?.sourceURL.host, "raw.githubusercontent.com")
        XCTAssertEqual(decoded.guardrails.first?.sourceURL.host, "raw.githubusercontent.com")
    }

    func testCachedSnapshotCompilerBuildsTunnelSnapshotFromCachedTextFiles() async throws {
        let source = makeSource(
            id: "hagezi-multi-pro-mini",
            sourceHash: "3d439fc6b959423465db4238e7df7ebda7d47a3a9e123ce899faed5e49e4b1eb"
        )
        let guardrail = makeSource(
            id: "phishing-database-active",
            sourceHash: "77f0f2381a023aa88776d6245456a6451b1b43cd721f4609897a867c8188e879"
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260516T044815Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: [guardrail]
        )
        let cacheURL = try makeTemporaryCacheDirectory()
        try writeCatalog(catalog, to: cacheURL)
        try writeLatestBlocklist(
            "ads.example.com\n",
            sourceID: source.id,
            to: cacheURL
        )
        try writeLatestBlocklist(
            "phishing.example.com\n",
            sourceID: guardrail.id,
            to: cacheURL
        )

        var allowRules = DomainRuleSet()
        try allowRules.insert(domain: "allowed.example.com")
        try allowRules.insert(domain: "phishing.example.com")
        let baseSnapshot = FilterSnapshot(
            blockRules: DomainRuleSet(),
            allowRules: allowRules,
            resolver: .cloudflare
        )
        let configuration = AppConfiguration(
            enabledBlocklistIDs: [source.id],
            allowedDomains: ["allowed.example.com", "phishing.example.com"],
            resolverPresetID: DNSResolverPreset.cloudflare.id
        )

        let snapshot = try await CachedFilterSnapshotCompiler(
            cacheDirectoryURL: cacheURL
        ).compile(baseSnapshot: baseSnapshot, configuration: configuration)

        XCTAssertEqual(snapshot.decision(for: "ads.example.com").reason, .blocklist)
        XCTAssertEqual(snapshot.decision(for: "allowed.example.com").reason, .localAllowlist)
        XCTAssertEqual(snapshot.decision(for: "phishing.example.com").reason, .threatGuardrail)
        XCTAssertEqual(snapshot.resolver, .cloudflare)

        let tunnelStartupSnapshot = try await CachedFilterSnapshotCompiler(
            cacheDirectoryURL: cacheURL,
            includesGuardrails: false
        ).compile(baseSnapshot: baseSnapshot, configuration: configuration)

        XCTAssertEqual(tunnelStartupSnapshot.decision(for: "ads.example.com").reason, .blocklist)
        XCTAssertEqual(tunnelStartupSnapshot.decision(for: "phishing.example.com").reason, .localAllowlist)
    }

    func testCachedRawSourceCatalogParsesLocallyForTunnelStartup() async throws {
        let rawText = """
        # Raw upstream notice stays in the downloaded artifact.
        ||ads.example.net^
        0.0.0.0 tracker.example.com
        @@||allowed.example.com^
        """
        let rawHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(rawText.utf8))
        let source = makeSource(
            id: "hagezi-multi-light",
            licenseName: "GPL-3.0",
            sourceHash: rawHash,
            redistributionMode: "source_url_only",
            parseFormat: .auto
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T000000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: []
        )
        let cacheURL = try makeTemporaryCacheDirectory()
        try writeCatalog(catalog, to: cacheURL)
        try writeLatestBlocklist(rawText, sourceID: source.id, to: cacheURL)

        let result = try await BlocklistCatalogSynchronizer(
            catalogURL: URL(string: "https://example.com/catalog.json")!,
            cacheDirectoryURL: cacheURL
        ).loadCached(enabledSourceIDs: [source.id])

        let ruleSet = try XCTUnwrap(result.sourceRuleSets[source.id])
        XCTAssertTrue(ruleSet.contains("ads.example.net"))
        XCTAssertTrue(ruleSet.contains("tracker.example.com"))
        XCTAssertFalse(ruleSet.contains("allowed.example.com"))
        XCTAssertEqual(result.metadataBySourceID[source.id]?.checksumSHA256, rawHash)
    }

    func testAppParseRejectsAnOverCapSourceInsteadOfSilentlyTruncating() async throws {
        // A source with more rules than the per-source cap must surface an over-limit error,
        // NOT cache + serve a silently truncated set under the source's full identity (which
        // also masks the overage from the tier/device aggregate gate). The raised 45 MB
        // intake cap admits larger payloads, so this guard — not the byte gate — is what now
        // catches an over-cap source on the foreground app parse path.
        let rawText = (0..<5).map { "d\($0).example.com" }.joined(separator: "\n") + "\n"
        let rawHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(rawText.utf8))
        let source = makeSource(
            id: "over-cap",
            sourceHash: rawHash,
            normalizedHash: rawHash,
            redistributionMode: "source_url_only",
            parseFormat: .plainDomains
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T000000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: []
        )
        let cacheURL = try makeTemporaryCacheDirectory()
        try writeCatalog(catalog, to: cacheURL)
        try writeLatestBlocklist(rawText, sourceID: source.id, to: cacheURL)

        let cappedBudget = BlocklistParseResourceBudget(
            maximumBlocklistBytes: 45 * 1024 * 1024,
            maxRulesPerSource: 3, // below the 5 rules in the source
            maxConcurrentSources: 1
        )
        do {
            _ = try await BlocklistCatalogSynchronizer(
                cacheDirectoryURL: cacheURL,
                parseBudget: cappedBudget
            ).loadCached(enabledSourceIDs: [source.id])
            XCTFail("expected an over-limit error for a source exceeding the per-source cap")
        } catch let error as BlocklistCatalogSyncError {
            XCTAssertEqual(error, .blocklistExceedsRuleLimit(sourceID: source.id, ruleLimit: 3))
        }

        // The throw happens BEFORE the parsed-rules cache store, so nothing truncated was
        // persisted: re-loading the same cache dir under a cap above the source size parses it
        // fresh and IN FULL (no false positive, no poisoned cache).
        let okBudget = BlocklistParseResourceBudget(
            maximumBlocklistBytes: 45 * 1024 * 1024,
            maxRulesPerSource: 100,
            maxConcurrentSources: 1
        )
        let okResult = try await BlocklistCatalogSynchronizer(
            cacheDirectoryURL: cacheURL,
            parseBudget: okBudget
        ).loadCached(enabledSourceIDs: [source.id])
        let ruleSet = try XCTUnwrap(okResult.sourceRuleSets[source.id])
        XCTAssertTrue(ruleSet.contains("d0.example.com"))
        XCTAssertTrue(ruleSet.contains("d4.example.com"))
    }

    func testAppParseAcceptsAnAtCapSourceWithTrailingFooterLines() async throws {
        // A source with exactly `maxRulesPerSource` rules followed by footer/comment/blank
        // lines is IN LIMIT and must load fully — the over-cap guard must trip only when a
        // real rule is dropped, not on trailing non-rule lines after the last rule.
        let rawText = "a.example.com\nb.example.com\n# stats: 2 rules\n\n"
        let rawHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(rawText.utf8))
        let source = makeSource(
            id: "at-cap-with-footer",
            sourceHash: rawHash,
            normalizedHash: rawHash,
            redistributionMode: "source_url_only",
            parseFormat: .plainDomains
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T000000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: []
        )
        let cacheURL = try makeTemporaryCacheDirectory()
        try writeCatalog(catalog, to: cacheURL)
        try writeLatestBlocklist(rawText, sourceID: source.id, to: cacheURL)

        let atCapBudget = BlocklistParseResourceBudget(
            maximumBlocklistBytes: 45 * 1024 * 1024,
            maxRulesPerSource: 2, // exactly the source's rule count
            maxConcurrentSources: 1
        )
        let result = try await BlocklistCatalogSynchronizer(
            cacheDirectoryURL: cacheURL,
            parseBudget: atCapBudget
        ).loadCached(enabledSourceIDs: [source.id])
        let ruleSet = try XCTUnwrap(result.sourceRuleSets[source.id])
        XCTAssertTrue(ruleSet.contains("a.example.com"))
        XCTAssertTrue(ruleSet.contains("b.example.com"))
    }

    func testAppParseAcceptsAnAtCapSourceWithDuplicateRules() async throws {
        // The cap is on UNIQUE rules: duplicates don't add new rules, so a source whose unique
        // count is within the cap must load in full even when its raw line count (with repeats)
        // exceeds the cap. A raw-count cap would mistake the repeated rule for an overflow.
        let rawText = "a.example.com\nb.example.com\na.example.com\nb.example.com\na.example.com\n"
        let rawHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(rawText.utf8))
        let source = makeSource(
            id: "at-cap-with-dups",
            sourceHash: rawHash,
            normalizedHash: rawHash,
            redistributionMode: "source_url_only",
            parseFormat: .plainDomains
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T000000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: []
        )
        let cacheURL = try makeTemporaryCacheDirectory()
        try writeCatalog(catalog, to: cacheURL)
        try writeLatestBlocklist(rawText, sourceID: source.id, to: cacheURL)

        // 5 raw rules, only 2 unique; cap = 2 → in limit.
        let atCapBudget = BlocklistParseResourceBudget(
            maximumBlocklistBytes: 45 * 1024 * 1024,
            maxRulesPerSource: 2,
            maxConcurrentSources: 1
        )
        let result = try await BlocklistCatalogSynchronizer(
            cacheDirectoryURL: cacheURL,
            parseBudget: atCapBudget
        ).loadCached(enabledSourceIDs: [source.id])
        let ruleSet = try XCTUnwrap(result.sourceRuleSets[source.id])
        XCTAssertEqual(ruleSet.count, 2)
        XCTAssertTrue(ruleSet.contains("a.example.com"))
        XCTAssertTrue(ruleSet.contains("b.example.com"))
    }

    func testSyncFetchesBlocklistFromUpstreamSourceURL() async throws {
        let catalogURL = URL(string: "https://api.lavasecurity.app/v1/catalog")!
        let sourceURL = URL(string: "https://upstream.example.com/list.txt")!
        let rawText = "ads.example.com\n"
        let rawHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(rawText.utf8))
        let source = makeSource(
            id: "upstream-only",
            sourceURL: sourceURL,
            sourceHash: rawHash,
            normalizedHash: rawHash,
            redistributionMode: "source_url_only",
            parseFormat: .plainDomains
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T010000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: []
        )
        let catalogData = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        let requestLog = RequestLog()

        let result = try await BlocklistCatalogSynchronizer(
            catalogURL: catalogURL,
            cacheDirectoryURL: makeTemporaryCacheDirectory(),
            dataFetcher: { url in
                await requestLog.append(url)
                if url == catalogURL {
                    return catalogData
                }
                if url == sourceURL {
                    return Data(rawText.utf8)
                }

                throw URLError(.unsupportedURL)
            }
        ).sync(enabledSourceIDs: [source.id])

        XCTAssertTrue(result.sourceRuleSets[source.id]?.contains("ads.example.com") == true)
        let requestedURLs = await requestLog.urls
        XCTAssertEqual(requestedURLs, [catalogURL, sourceURL])
    }

    func testBuiltInFallbackCatalogWithoutAcceptedHashesDoesNotFetchSourceURL() async throws {
        let catalogURL = URL(string: "https://api.example.invalid/v1/catalog")!
        let source = DefaultCatalog.oisdSmall
        let requestLog = RequestLog()

        do {
            _ = try await BlocklistCatalogSynchronizer(
                catalogURLs: [catalogURL],
                cacheDirectoryURL: makeTemporaryCacheDirectory(),
                dataFetcher: { url in
                    await requestLog.append(url)
                    throw URLError(.cannotFindHost)
                }
            ).sync(enabledSourceIDs: [source.id])
            XCTFail("Expected missing reviewed hash metadata to stop source-url fallback fetch.")
        } catch BlocklistCatalogSyncError.noAcceptedSourceHashes(let sourceID) {
            XCTAssertEqual(sourceID, source.id)
        }

        let requestedURLs = await requestLog.urls
        XCTAssertEqual(requestedURLs, [catalogURL])
    }

    func testBackupRestoredBuiltInSourceURLBlocklistCompilesAndReloadsFromCache() async throws {
        let catalogURL = URL(string: "https://api.lavasecurity.app/v1/catalog")!
        let source = DefaultCatalog.oisdSmall
        let rawText = "oisd-ad.example.com\n"
        let rawHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(rawText.utf8))
        let reviewedSource = makeSource(
            id: source.id,
            sourceURL: source.sourceURL,
            licenseName: source.licenseName,
            sourceHash: rawHash,
            normalizedHash: rawHash,
            redistributionMode: "source_url_only",
            parseFormat: .plainDomains
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260607T000000Z",
            generatedAt: Date(timeIntervalSince1970: 1_780_272_000),
            sources: [reviewedSource],
            guardrails: []
        )
        let catalogData = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        let backedUpConfiguration = AppConfiguration(
            protectionEnabled: true,
            enabledBlocklistIDs: [source.id]
        )
        let restoredConfiguration = BackupConfigurationPayload(
            configuration: backedUpConfiguration
        ).restoredConfiguration()
        let cacheURL = try makeTemporaryCacheDirectory()
        let requestLog = RequestLog()

        let syncResult = try await BlocklistCatalogSynchronizer(
            catalogURL: catalogURL,
            cacheDirectoryURL: cacheURL,
            dataFetcher: { url in
                await requestLog.append(url)
                if url == catalogURL {
                    return catalogData
                }
                if url == source.sourceURL {
                    return Data(rawText.utf8)
                }

                throw URLError(.unsupportedURL)
            }
        ).sync(enabledSourceIDs: restoredConfiguration.enabledBlocklistIDs)

        XCTAssertTrue(try XCTUnwrap(syncResult.sourceRuleSets[source.id]).contains("oisd-ad.example.com"))
        let resolvedSource = try XCTUnwrap(syncResult.catalog.sources.first { $0.id == source.id })
        XCTAssertEqual(resolvedSource.sourceHash, rawHash)
        XCTAssertEqual(resolvedSource.acceptedSourceHashes.first?.sha256, rawHash)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: BlocklistCatalogSynchronizer.latestCatalogURL(in: cacheURL).path
            )
        )

        let cachedSnapshot = try await CachedFilterSnapshotCompiler(
            cacheDirectoryURL: cacheURL
        ).compile(
            baseSnapshot: FilterSnapshot(blockRules: DomainRuleSet(), allowRules: DomainRuleSet()),
            configuration: restoredConfiguration
        )

        XCTAssertEqual(cachedSnapshot.decision(for: "oisd-ad.example.com").reason, .blocklist)
        let requestedURLs = await requestLog.urls
        XCTAssertEqual(requestedURLs, [catalogURL, source.sourceURL])
    }

    func testSourceURLOnlySyncAcceptsRotatedUpstreamAndCachesAcceptedHashForReload() async throws {
        let catalogURL = URL(string: "https://api.lavasecurity.app/v1/catalog")!
        let sourceURL = URL(string: "https://upstream.example.com/list.txt")!
        let previousText = "previous.example.com\n"
        let rotatedText = "rotated.example.com\n"
        let previousHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(previousText.utf8))
        let rotatedHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(rotatedText.utf8))
        let source = makeSource(
            id: "upstream-only",
            sourceURL: sourceURL,
            sourceHash: previousHash,
            normalizedHash: previousHash,
            redistributionMode: "source_url_only",
            parseFormat: .plainDomains
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T010000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: []
        )
        let catalogData = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        let cacheURL = try makeTemporaryCacheDirectory()

        let result = try await BlocklistCatalogSynchronizer(
            catalogURL: catalogURL,
            cacheDirectoryURL: cacheURL,
            dataFetcher: { url in
                if url == catalogURL {
                    return catalogData
                }
                if url == sourceURL {
                    return Data(rotatedText.utf8)
                }

                throw URLError(.unsupportedURL)
            }
        ).sync(enabledSourceIDs: [source.id])

        let ruleSet = try XCTUnwrap(result.sourceRuleSets[source.id])
        XCTAssertTrue(ruleSet.contains("rotated.example.com"))
        XCTAssertFalse(ruleSet.contains("previous.example.com"))

        let resolvedSource = try XCTUnwrap(result.catalog.sources.first { $0.id == source.id })
        XCTAssertEqual(resolvedSource.sourceHash, rotatedHash)
        XCTAssertEqual(resolvedSource.acceptedSourceHashes.first?.sha256, rotatedHash)
        XCTAssertTrue(resolvedSource.acceptedSourceHashes.contains { $0.sha256 == previousHash })
        XCTAssertFalse(result.usedCachedSourceIDs.contains(source.id))

        let cachedSnapshot = try await CachedFilterSnapshotCompiler(
            cacheDirectoryURL: cacheURL
        ).compile(
            baseSnapshot: FilterSnapshot(blockRules: DomainRuleSet(), allowRules: DomainRuleSet()),
            configuration: AppConfiguration(enabledBlocklistIDs: [source.id])
        )

        XCTAssertEqual(cachedSnapshot.decision(for: "rotated.example.com").reason, .blocklist)
        XCTAssertEqual(cachedSnapshot.decision(for: "previous.example.com").reason, .defaultAllow)
    }

    func testSyncRejectsChangedArtifactBytesWhenNoAcceptedHashMatches() async throws {
        let catalogURL = URL(string: "https://api.lavasecurity.app/v1/catalog")!
        let sourceURL = URL(string: "https://upstream.example.com/list.txt")!
        let rawText = "ads.example.com\n"
        let source = makeSource(
            id: "artifact-source",
            sourceURL: sourceURL,
            sourceHash: String(repeating: "0", count: 64),
            normalizedHash: String(repeating: "1", count: 64),
            redistributionMode: "artifact",
            parseFormat: .plainDomains
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T010000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: []
        )
        let catalogData = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)

        do {
            _ = try await BlocklistCatalogSynchronizer(
                catalogURL: catalogURL,
                cacheDirectoryURL: makeTemporaryCacheDirectory(),
                dataFetcher: { url in
                    if url == catalogURL {
                        return catalogData
                    }
                    if url == sourceURL {
                        return Data(rawText.utf8)
                    }

                    throw URLError(.unsupportedURL)
                }
            ).sync(enabledSourceIDs: [source.id])
            XCTFail("Expected checksum mismatch for changed artifact bytes.")
        } catch BlocklistCatalogSyncError.checksumMismatch(let sourceID) {
            XCTAssertEqual(sourceID, source.id)
        }
    }

    func testSyncUsesCachedLastGoodBlocklistWhenDirectUpstreamFetchFails() async throws {
        let catalogURL = URL(string: "https://api.lavasecurity.app/v1/catalog")!
        let sourceURL = URL(string: "https://upstream.example.com/list.txt")!
        let lastGoodText = "ads.example.com\n"
        let lastGoodHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(lastGoodText.utf8))
        let source = makeSource(
            id: "upstream-only",
            sourceURL: sourceURL,
            sourceHash: lastGoodHash,
            normalizedHash: lastGoodHash,
            redistributionMode: "source_url_only",
            parseFormat: .plainDomains
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T010000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: []
        )
        let catalogData = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        let cacheURL = try makeTemporaryCacheDirectory()
        try writeLatestBlocklist(lastGoodText, sourceID: source.id, to: cacheURL)

        let result = try await BlocklistCatalogSynchronizer(
            catalogURL: catalogURL,
            cacheDirectoryURL: cacheURL,
            dataFetcher: { url in
                if url == catalogURL {
                    return catalogData
                }
                if url == sourceURL {
                    throw URLError(.notConnectedToInternet)
                }

                throw URLError(.unsupportedURL)
            }
        ).sync(enabledSourceIDs: [source.id])

        let ruleSet = try XCTUnwrap(result.sourceRuleSets[source.id])
        XCTAssertTrue(ruleSet.contains("ads.example.com"))
        XCTAssertFalse(ruleSet.contains("malware.example.com"))
        XCTAssertTrue(result.usedCachedSourceIDs.contains(source.id))
    }

    func testSyncPrefersCurrentAcceptedUpstreamHashOverOlderAcceptedCache() async throws {
        let catalogURL = URL(string: "https://api.lavasecurity.app/v1/catalog")!
        let sourceURL = URL(string: "https://upstream.example.com/list.txt")!
        let oldText = "old.example.com\n"
        let currentText = "current.example.com\n"
        let oldHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(oldText.utf8))
        let currentHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(currentText.utf8))
        let source = makeSource(
            id: "upstream-only",
            sourceURL: sourceURL,
            sourceHash: currentHash,
            acceptedSourceHashes: [
                CatalogAcceptedSourceHash(sha256: currentHash),
                CatalogAcceptedSourceHash(sha256: oldHash)
            ],
            normalizedHash: currentHash,
            redistributionMode: "source_url_only",
            parseFormat: .plainDomains
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T010000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: []
        )
        let catalogData = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        let cacheURL = try makeTemporaryCacheDirectory()
        try writeVersionedBlocklist(oldText, source: source, checksumSHA256: oldHash, to: cacheURL)
        let requestLog = RequestLog()

        let result = try await BlocklistCatalogSynchronizer(
            catalogURL: catalogURL,
            cacheDirectoryURL: cacheURL,
            dataFetcher: { url in
                await requestLog.append(url)
                if url == catalogURL {
                    return catalogData
                }
                if url == sourceURL {
                    return Data(currentText.utf8)
                }

                throw URLError(.unsupportedURL)
            }
        ).sync(enabledSourceIDs: [source.id])

        let ruleSet = try XCTUnwrap(result.sourceRuleSets[source.id])
        XCTAssertTrue(ruleSet.contains("current.example.com"))
        XCTAssertFalse(ruleSet.contains("old.example.com"))
        XCTAssertFalse(result.usedCachedSourceIDs.contains(source.id))
        let requestedURLs = await requestLog.urls
        XCTAssertEqual(requestedURLs, [catalogURL, sourceURL])
    }

    func testSyncRejectsNonBootstrapCatalogSourcesWithoutAcceptedHashes() async throws {
        let catalogURL = URL(string: "https://api.lavasecurity.app/v1/catalog")!
        let sourceURL = URL(string: "https://upstream.example.com/list.txt")!
        let source = makeSource(
            id: "metadata-only",
            sourceURL: sourceURL,
            sourceHash: "",
            acceptedSourceHashes: [],
            normalizedHash: "",
            redistributionMode: "artifact",
            parseFormat: .plainDomains
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T020000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: []
        )
        let catalogData = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        let requestLog = RequestLog()

        do {
            _ = try await BlocklistCatalogSynchronizer(
                catalogURL: catalogURL,
                cacheDirectoryURL: makeTemporaryCacheDirectory(),
                dataFetcher: { url in
                    await requestLog.append(url)
                    if url == catalogURL {
                        return catalogData
                    }

                    throw URLError(.unsupportedURL)
                }
            ).sync(enabledSourceIDs: [source.id])
            XCTFail("Expected missing accepted hash metadata to stop source fetch.")
        } catch BlocklistCatalogSyncError.noAcceptedSourceHashes(let sourceID) {
            XCTAssertEqual(sourceID, source.id)
        }

        let requestedURLs = await requestLog.urls
        XCTAssertEqual(requestedURLs, [catalogURL])
    }

    func testDirectSourceParsingSkipsProtectedDomainsBeforeRulesReachSnapshot() async throws {
        let catalogURL = URL(string: "https://api.lavasecurity.app/v1/catalog")!
        let sourceURL = URL(string: "https://upstream.example.com/list.txt")!
        let rawText = """
        api.lavasecurity.app
        apps.apple.com
        accounts.google.com
        ads.example.com
        """
        let rawHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(rawText.utf8))
        let source = makeSource(
            id: "upstream-only",
            sourceURL: sourceURL,
            sourceHash: rawHash,
            normalizedHash: rawHash,
            redistributionMode: "source_url_only",
            parseFormat: .plainDomains
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T020000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: []
        )
        let catalogData = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)

        let result = try await BlocklistCatalogSynchronizer(
            catalogURL: catalogURL,
            cacheDirectoryURL: makeTemporaryCacheDirectory(),
            dataFetcher: { url in
                if url == catalogURL {
                    return catalogData
                }
                if url == sourceURL {
                    return Data(rawText.utf8)
                }

                throw URLError(.unsupportedURL)
            }
        ).sync(enabledSourceIDs: [source.id])

        let ruleSet = try XCTUnwrap(result.sourceRuleSets[source.id])
        XCTAssertTrue(ruleSet.contains("ads.example.com"))
        XCTAssertFalse(ruleSet.contains("api.lavasecurity.app"))
        XCTAssertFalse(ruleSet.contains("apps.apple.com"))
        XCTAssertFalse(ruleSet.contains("accounts.google.com"))
    }

    func testCachedCatalogFreshnessUsesLatestCatalogModificationDate() throws {
        let cacheURL = try makeTemporaryCacheDirectory()
        let latestURL = BlocklistCatalogSynchronizer.latestCatalogURL(in: cacheURL)
        try FileManager.default.createDirectory(
            at: latestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: latestURL)

        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let freshDate = now.addingTimeInterval(-60)
        try FileManager.default.setAttributes(
            [.modificationDate: freshDate],
            ofItemAtPath: latestURL.path
        )

        let age = try XCTUnwrap(
            BlocklistCatalogSynchronizer.cachedCatalogAge(in: cacheURL, now: now)
        )
        XCTAssertEqual(age, 60, accuracy: 0.1)
        XCTAssertTrue(
            BlocklistCatalogSynchronizer.hasFreshCachedCatalog(
                in: cacheURL,
                maxAge: 300,
                now: now
            )
        )
        XCTAssertFalse(
            BlocklistCatalogSynchronizer.hasFreshCachedCatalog(
                in: cacheURL,
                maxAge: 30,
                now: now
            )
        )
    }

    func testCatalogFreshnessPolicyKeepsInitialEvaluationWindowFresh() {
        let policy = BlocklistCatalogFreshnessPolicy(maxAge: 7 * 24 * 60 * 60)

        XCTAssertTrue(policy.isFresh(age: nil, statusIsError: false))
        XCTAssertTrue(policy.isFresh(age: 6 * 24 * 60 * 60, statusIsError: false))
        XCTAssertFalse(policy.isFresh(age: 8 * 24 * 60 * 60, statusIsError: false))
        XCTAssertFalse(policy.isFresh(age: nil, statusIsError: true))
    }

    func testLowRiskLaunchCacheKeepsActiveAdGuardCatalog() throws {
        let cacheURL = try makeTemporaryCacheDirectory()
        let defaultSource = makeSource(
            id: DefaultCatalog.blockListProjectBasic.id,
            licenseName: "Unlicense"
        )
        let adGuardSource = makeSource(
            id: "adguard-dns-filter",
            licenseName: "GPL-3.0"
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T122050Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [defaultSource, adGuardSource],
            guardrails: []
        )
        try writeCatalog(catalog, to: cacheURL)

        XCTAssertFalse(
            BlocklistCatalogSynchronizer.cachedCatalogRequiresLowRiskLaunchRefresh(
                in: cacheURL,
                requiredSourceIDs: [DefaultCatalog.blockListProjectBasic.id]
            )
        )
    }

    func testLowRiskLaunchCacheMigrationKeepsActiveAdGuardCatalogAndPayload() throws {
        let cacheURL = try makeTemporaryCacheDirectory()
        let defaultSource = makeSource(
            id: DefaultCatalog.blockListProjectBasic.id,
            licenseName: "Unlicense"
        )
        let adGuardSource = makeSource(
            id: "adguard-dns-filter",
            licenseName: "GPL-3.0"
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T122050Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [defaultSource, adGuardSource],
            guardrails: []
        )
        try writeCatalog(catalog, to: cacheURL)
        try writeLatestBlocklist("ads.example.com\n", sourceID: adGuardSource.id, to: cacheURL)

        let changed = BlocklistCatalogSynchronizer.migrateLowRiskLaunchCacheIfNeeded(
            in: cacheURL,
            requiredSourceIDs: [DefaultCatalog.blockListProjectBasic.id]
        )

        XCTAssertFalse(changed)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: BlocklistCatalogSynchronizer.latestCatalogURL(in: cacheURL).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: cacheURL
                    .appendingPathComponent("blocklists", isDirectory: true)
                    .appendingPathComponent(adGuardSource.id, isDirectory: true)
                    .path
            )
        )
    }

    func testLowRiskLaunchCacheMigrationInvalidatesCatalogWithLegacyGuardrails() throws {
        let cacheURL = try makeTemporaryCacheDirectory()
        let source = makeSource(
            id: DefaultCatalog.blockListProjectBasic.id,
            licenseName: "Unlicense"
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T122050Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: [makeSource(id: "phishing-database-active", licenseName: "MIT")]
        )
        try writeCatalog(catalog, to: cacheURL)

        let changed = BlocklistCatalogSynchronizer.migrateLowRiskLaunchCacheIfNeeded(
            in: cacheURL,
            requiredSourceIDs: [DefaultCatalog.blockListProjectBasic.id]
        )

        XCTAssertTrue(changed)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: BlocklistCatalogSynchronizer.latestCatalogURL(in: cacheURL).path
            )
        )
    }

    func testLowRiskLaunchCacheMigrationKeepsCurrentCatalog() throws {
        let cacheURL = try makeTemporaryCacheDirectory()
        let source = makeSource(
            id: DefaultCatalog.blockListProjectBasic.id,
            licenseName: "Unlicense"
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260526T000000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: []
        )
        try writeCatalog(catalog, to: cacheURL)

        let changed = BlocklistCatalogSynchronizer.migrateLowRiskLaunchCacheIfNeeded(
            in: cacheURL,
            requiredSourceIDs: [DefaultCatalog.blockListProjectBasic.id]
        )

        XCTAssertFalse(changed)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: BlocklistCatalogSynchronizer.latestCatalogURL(in: cacheURL).path
            )
        )
    }

    func testSyncCustomBlocklistFetchesDirectURLAndCachesLocally() async throws {
        let sourceURL = URL(string: "https://user.example.com/list.txt")!
        let source = try CustomBlocklistSource(
            id: "custom-test",
            displayName: "My List",
            rawURL: sourceURL.absoluteString
        )
        let rawText = """
        0.0.0.0 ads.example.com
        0.0.0.0 api.lavasecurity.app
        """
        let requestLog = RequestLog()
        let cacheURL = try makeTemporaryCacheDirectory()

        let result = try await BlocklistCatalogSynchronizer(
            catalogURL: URL(string: "https://api.lavasecurity.app/v1/catalog")!,
            cacheDirectoryURL: cacheURL,
            dataFetcher: { url in
                await requestLog.append(url)
                if url == sourceURL {
                    return Data(rawText.utf8)
                }

                throw URLError(.unsupportedURL)
            }
        ).syncCustomBlocklists([source])

        XCTAssertTrue(try XCTUnwrap(result.sourceRuleSets[source.id]).contains("ads.example.com"))
        XCTAssertFalse(try XCTUnwrap(result.sourceRuleSets[source.id]).contains("api.lavasecurity.app"))
        let requestedURLs = await requestLog.snapshot()
        XCTAssertEqual(requestedURLs, [sourceURL])
        XCTAssertFalse(result.usedCachedSourceIDs.contains(source.id))
        XCTAssertEqual(
            result.sourceHashes[source.id],
            BlocklistCatalogSynchronizer.sha256Hex(of: Data(rawText.utf8))
        )

        let cached = try await BlocklistCatalogSynchronizer(
            cacheDirectoryURL: cacheURL,
            dataFetcher: { _ in throw URLError(.notConnectedToInternet) }
        ).loadCachedCustomBlocklists([source])

        XCTAssertTrue(try XCTUnwrap(cached.sourceRuleSets[source.id]).contains("ads.example.com"))
        XCTAssertTrue(cached.usedCachedSourceIDs.contains(source.id))
    }

    func testSyncCustomBlocklistAcceptsChangedNetworkBytesAndUpdatesHash() async throws {
        let sourceURL = URL(string: "https://user.example.com/list.txt")!
        let oldText = "old.example.com\n"
        let newText = "new.example.com\n"
        let oldHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(oldText.utf8))
        let newHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(newText.utf8))
        let source = try CustomBlocklistSource(
            id: "custom-changing",
            displayName: "Changing",
            rawURL: sourceURL.absoluteString,
            lastAcceptedHash: oldHash
        )

        let result = try await BlocklistCatalogSynchronizer(
            cacheDirectoryURL: makeTemporaryCacheDirectory(),
            dataFetcher: { url in
                if url == sourceURL {
                    return Data(newText.utf8)
                }

                throw URLError(.unsupportedURL)
            }
        ).syncCustomBlocklists([source])

        let rules = try XCTUnwrap(result.sourceRuleSets[source.id])
        XCTAssertTrue(rules.contains("new.example.com"))
        XCTAssertFalse(rules.contains("old.example.com"))
        XCTAssertEqual(result.sourceHashes[source.id], newHash)
    }

    func testCachedCustomBlocklistRequiresLastAcceptedHashMatch() async throws {
        // A custom source's lastAcceptedHash is the FREEZE anchor for a downgraded
        // (cacheOnly) filter — it must fail closed when the only cached content differs,
        // rather than silently re-hash from latest. (Dropping hash-pinning applies to catalog
        // COMMUNITY sources, not to this custom-list freeze gate.)
        let sourceURL = URL(string: "https://user.example.com/list.txt")!
        let acceptedText = "accepted.example.com\n"
        let changedText = "changed.example.com\n"
        let acceptedHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(acceptedText.utf8))
        let source = try CustomBlocklistSource(
            id: "custom-hash",
            displayName: "Hash Checked",
            rawURL: sourceURL.absoluteString,
            lastAcceptedHash: acceptedHash
        )
        let cacheURL = try makeTemporaryCacheDirectory()
        try writeLatestCustomBlocklist(changedText, sourceID: source.id, to: cacheURL)

        do {
            _ = try await BlocklistCatalogSynchronizer(
                cacheDirectoryURL: cacheURL
            ).loadCachedCustomBlocklists([source])
            XCTFail("Expected cached custom list with a mismatched accepted hash to be rejected.")
        } catch BlocklistCatalogSyncError.checksumMismatch(let sourceID) {
            XCTAssertEqual(sourceID, source.id)
        }
    }

    func testAcceptsDirectUpstreamRotationExcludesGuardrail() {
        // Community source_url_only lists accept direct upstream rotation (no hard pin); the
        // threat guardrail tier stays strict even though it is also published source_url_only.
        let community = makeSource(id: "community", redistributionMode: "source_url_only")
        XCTAssertTrue(community.acceptsDirectUpstreamRotation)

        let pinned = String(repeating: "a", count: 64)
        let guardrail = CatalogBlocklistSource(
            id: "threat-guardrail",
            name: "Threat Guardrail",
            category: CatalogBlocklistSource.guardrailCategory,
            riskLevel: "high",
            defaultEnabled: true,
            licenseName: "Test",
            attribution: "Lava",
            projectURL: URL(string: "https://example.com/project")!,
            sourceURL: URL(string: "https://example.com/guardrail")!,
            versionID: "g1",
            entryCount: 1,
            byteSize: 16,
            sourceHash: pinned,
            acceptedSourceHashes: [CatalogAcceptedSourceHash(sha256: pinned)],
            normalizedHash: pinned,
            publishedAt: Date(timeIntervalSince1970: 1_768_385_371),
            redistributionMode: "source_url_only",
            parseFormat: .plainDomains,
            licenseTextURL: nil,
            noticeURL: nil
        )
        XCTAssertFalse(guardrail.acceptsDirectUpstreamRotation)
    }

    func testSourceURLOnlyCacheServesRotatedLatestWhenHashNotPinned() async throws {
        // Refresh-wedge root cause: a community source_url_only list rotated upstream, so its
        // cached `latest` no longer matches the catalog's (now stale) pinned hash. On the
        // cache-only path (the tunnel's cold-start in-extension compile) the device must SERVE
        // that cached content — size/rule caps still apply at parse time — rather than throw
        // checksumMismatch and clear protection.
        let pinnedHash = String(repeating: "b", count: 64)
        let source = makeSource(
            id: "rotating-community",
            sourceHash: pinnedHash,
            normalizedHash: pinnedHash,
            redistributionMode: "source_url_only"
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260623T000000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: []
        )
        let cacheURL = try makeTemporaryCacheDirectory()
        try writeCatalog(catalog, to: cacheURL)
        // The cached `latest` is the ROTATED content — its hash is NOT the pinned one, and no
        // versioned file matches the pin, so the load falls through to the latest payload.
        try writeLatestBlocklist("rotated.example.com\n", sourceID: source.id, to: cacheURL)

        let result = try await BlocklistCatalogSynchronizer(
            cacheDirectoryURL: cacheURL
        ).loadCached(enabledSourceIDs: [source.id])

        let rules = try XCTUnwrap(result.sourceRuleSets[source.id])
        XCTAssertTrue(rules.contains("rotated.example.com"))
    }

    func testDecodedGuardrailIsStampedStrictRegardlessOfServerCategory() throws {
        // Guardrail strictness must derive from guardrails[] array MEMBERSHIP, not the server's
        // freeform `category` string (unsigned, TLS-only channel). A guardrails[] entry that
        // arrives with a non-guardrail category is normalized on decode so it can never relax to
        // community (rotation-accepting) behavior; a regular source keeps its category.
        let community = makeSource(id: "community-src") // category "security"
        let mislabeledGuardrail = makeSource(id: "threat-src") // also "security" — server mistagged it
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260623T000000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [community],
            guardrails: [mislabeledGuardrail]
        )

        let encoded = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        let decoded = try BlocklistCatalogSynchronizer.makeJSONDecoder().decode(BlocklistCatalog.self, from: encoded)

        let decodedGuardrail = try XCTUnwrap(decoded.guardrails.first)
        XCTAssertEqual(decodedGuardrail.category, CatalogBlocklistSource.guardrailCategory)
        XCTAssertFalse(
            decodedGuardrail.acceptsDirectUpstreamRotation,
            "A decoded guardrails[] entry must stay strict (no rotation acceptance) regardless of its server category."
        )

        let decodedSource = try XCTUnwrap(decoded.sources.first)
        XCTAssertEqual(decodedSource.category, "security", "Regular sources keep their server category.")
        XCTAssertTrue(decodedSource.acceptsDirectUpstreamRotation)
    }

    func testRestoredCustomBlocklistFetchesAndCachedCompilerReloadsFromHash() async throws {
        let sourceURL = URL(string: "https://user.example.com/list.txt")!
        let rawText = "custom-ad.example.com\n"
        let rawHash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(rawText.utf8))
        let source = try CustomBlocklistSource(
            id: "custom-restore",
            displayName: "Restore",
            rawURL: sourceURL.absoluteString
        )
        let backedUpConfiguration = AppConfiguration(
            protectionEnabled: true,
            enabledBlocklistIDs: [source.id],
            isPaid: true,
            customBlocklists: [source]
        )
        var restoredConfiguration = BackupConfigurationPayload(
            configuration: backedUpConfiguration
        ).restoredConfiguration()
        let cacheURL = try makeTemporaryCacheDirectory()
        try writeCatalog(
            BlocklistCatalog(
                schemaVersion: 2,
                catalogVersion: "empty",
                generatedAt: Date(timeIntervalSince1970: 1_780_272_000),
                sources: [],
                guardrails: []
            ),
            to: cacheURL
        )

        let customResult = try await BlocklistCatalogSynchronizer(
            cacheDirectoryURL: cacheURL,
            dataFetcher: { url in
                if url == sourceURL {
                    return Data(rawText.utf8)
                }

                throw URLError(.unsupportedURL)
            }
        ).syncCustomBlocklists(restoredConfiguration.customBlocklists)

        restoredConfiguration.customBlocklists[0].lastAcceptedHash = try XCTUnwrap(customResult.sourceHashes[source.id])
        let cachedSnapshot = try await CachedFilterSnapshotCompiler(
            cacheDirectoryURL: cacheURL
        ).compile(
            baseSnapshot: FilterSnapshot(blockRules: DomainRuleSet(), allowRules: DomainRuleSet()),
            configuration: restoredConfiguration
        )

        XCTAssertEqual(rawHash, restoredConfiguration.customBlocklists[0].lastAcceptedHash)
        XCTAssertEqual(cachedSnapshot.decision(for: "custom-ad.example.com").reason, .blocklist)
    }

    func testCachedSnapshotCompilerFailsForEnabledIDWithoutCatalogOrCustomSource() async throws {
        let cacheURL = try makeTemporaryCacheDirectory()
        try writeCatalog(
            BlocklistCatalog(
                schemaVersion: 2,
                catalogVersion: "empty",
                generatedAt: Date(timeIntervalSince1970: 1_780_272_000),
                sources: [],
                guardrails: []
            ),
            to: cacheURL
        )
        let configuration = AppConfiguration(enabledBlocklistIDs: ["missing-source"])

        do {
            _ = try await CachedFilterSnapshotCompiler(
                cacheDirectoryURL: cacheURL
            ).compile(
                baseSnapshot: FilterSnapshot(blockRules: DomainRuleSet(), allowRules: DomainRuleSet()),
                configuration: configuration
            )
            XCTFail("Expected an enabled source without catalog or custom metadata to fail explicitly.")
        } catch BlocklistCatalogSyncError.missingEnabledBlocklistSource(let sourceID) {
            XCTAssertEqual(sourceID, "missing-source")
        }
    }

    func testCustomBlocklistRejectsOversizedPayloadBeforeParsing() async throws {
        let sourceURL = URL(string: "https://user.example.com/large.txt")!
        let source = try CustomBlocklistSource(
            id: "custom-large",
            displayName: "Large",
            rawURL: sourceURL.absoluteString
        )
        let oversized = Data(repeating: 0x61, count: BlocklistCatalogSynchronizer.maximumBlocklistBytes + 1)

        do {
            _ = try await BlocklistCatalogSynchronizer(
                cacheDirectoryURL: makeTemporaryCacheDirectory(),
                dataFetcher: { url in
                    if url == sourceURL {
                        return oversized
                    }

                    throw URLError(.unsupportedURL)
                }
            ).syncCustomBlocklists([source])
            XCTFail("Expected oversized custom source to be rejected.")
        } catch BlocklistCatalogSyncError.blocklistTooLarge(let sourceID, let byteSize) {
            XCTAssertEqual(sourceID, source.id)
            XCTAssertEqual(byteSize, oversized.count)
        }
    }

    func testCustomBlocklistStreamingSizeLimitSurfacesNamedError() async throws {
        // The streaming layer (`defaultDataFetcher`) aborts an oversized body before it
        // is fully buffered, throwing `BlocklistDownloadSizeLimitExceeded`. Simulate that
        // by injecting it: the custom-source path must wrap it as the named
        // `customBlocklistUnavailable` (not pass through a generic error), so the user
        // sees which list failed.
        let sourceURL = URL(string: "https://user.example.com/huge.txt")!
        let source = try CustomBlocklistSource(
            id: "custom-huge",
            displayName: "Huge",
            rawURL: sourceURL.absoluteString
        )

        do {
            _ = try await BlocklistCatalogSynchronizer(
                cacheDirectoryURL: makeTemporaryCacheDirectory(),
                dataFetcher: { url in
                    if url == sourceURL {
                        throw BlocklistDownloadSizeLimitExceeded(
                            byteSize: BlocklistCatalogSynchronizer.maximumBlocklistBytes + 1,
                            maximumByteCount: BlocklistCatalogSynchronizer.maximumBlocklistBytes
                        )
                    }

                    throw URLError(.unsupportedURL)
                }
            ).syncCustomBlocklists([source])
            XCTFail("Expected the oversized streamed download to be rejected.")
        } catch BlocklistCatalogSyncError.customBlocklistUnavailable(let displayName, _) {
            XCTAssertEqual(displayName, "Huge")
        }
    }

    func testCustomBlocklistDownloadCancellationPropagatesAsURLError() async throws {
        let source = try CustomBlocklistSource(
            id: "custom-cancel",
            displayName: "Cancelled",
            rawURL: "https://user.example.com/cancelled.txt"
        )

        do {
            _ = try await BlocklistCatalogSynchronizer(
                cacheDirectoryURL: makeTemporaryCacheDirectory(),
                dataFetcher: { _ in throw URLError(.cancelled) }
            ).syncCustomBlocklists([source])
            XCTFail("Expected the cancelled download to propagate.")
        } catch let error as URLError {
            // A cancelled in-flight download (URLError.cancelled) must pass through as
            // cancellation, NOT be wrapped as customBlocklistUnavailable.
            XCTAssertEqual(error.code, .cancelled)
        }
    }

    func testParallelSourceCompilationProducesEveryEnabledRuleSet() async throws {
        let catalogURL = URL(string: "https://api.lavasecurity.app/v1/catalog")!
        let count = 5
        let specs: [(source: CatalogBlocklistSource, url: URL, data: Data)] = (0..<count).map { index in
            let sourceURL = URL(string: "https://upstream.example.com/list-\(index).txt")!
            let rawText = "ads-\(index).example.com\n"
            let hash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(rawText.utf8))
            return (
                makeSource(id: "src-\(index)", sourceURL: sourceURL, sourceHash: hash, normalizedHash: hash),
                sourceURL,
                Data(rawText.utf8)
            )
        }
        let sources = specs.map(\.source)
        let dataByURL = Dictionary(uniqueKeysWithValues: specs.map { ($0.url, $0.data) })
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T010000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: sources,
            guardrails: []
        )
        let catalogData = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)

        let result = try await BlocklistCatalogSynchronizer(
            catalogURL: catalogURL,
            cacheDirectoryURL: try makeTemporaryCacheDirectory(),
            dataFetcher: { url in
                if url == catalogURL {
                    return catalogData
                }
                guard let data = dataByURL[url] else {
                    throw URLError(.unsupportedURL)
                }
                return data
            }
        ).sync(enabledSourceIDs: Set(sources.map(\.id)))

        XCTAssertEqual(result.sourceRuleSets.count, count)
        for index in 0..<count {
            XCTAssertTrue(
                result.sourceRuleSets["src-\(index)"]?.contains("ads-\(index).example.com") == true,
                "Bounded-parallel compile must produce each enabled source's parsed rule set."
            )
        }
    }

    func testParallelSourceCompilationStaysWithinConcurrencyCap() async throws {
        let cap = BlocklistParseResourceBudget.default.maxConcurrentSources
        let catalogURL = URL(string: "https://api.lavasecurity.app/v1/catalog")!
        let count = cap + 2
        let specs: [(source: CatalogBlocklistSource, url: URL, data: Data)] = (0..<count).map { index in
            let sourceURL = URL(string: "https://upstream.example.com/list-\(index).txt")!
            let rawText = "ads-\(index).example.com\n"
            let hash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(rawText.utf8))
            return (
                makeSource(id: "src-\(index)", sourceURL: sourceURL, sourceHash: hash, normalizedHash: hash),
                sourceURL,
                Data(rawText.utf8)
            )
        }
        let sources = specs.map(\.source)
        let dataByURL = Dictionary(uniqueKeysWithValues: specs.map { ($0.url, $0.data) })
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T010000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: sources,
            guardrails: []
        )
        let catalogData = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        let tracker = ConcurrencyTracker()
        let gate = ArrivalGate(threshold: cap)

        let result = try await BlocklistCatalogSynchronizer(
            catalogURL: catalogURL,
            cacheDirectoryURL: try makeTemporaryCacheDirectory(),
            dataFetcher: { url in
                if url == catalogURL {
                    return catalogData
                }
                guard let data = dataByURL[url] else {
                    throw URLError(.unsupportedURL)
                }
                await tracker.enter()
                // Hold the first `cap` concurrent fetchers together so the peak
                // in-flight count is observable; sources beyond the cap pass
                // through once the threshold has already been reached.
                await gate.arriveAndWait()
                await tracker.leave()
                return data
            }
        ).sync(enabledSourceIDs: Set(sources.map(\.id)))

        XCTAssertEqual(result.sourceRuleSets.count, count)
        let peak = await tracker.peak
        XCTAssertEqual(
            peak,
            cap,
            "Bounded parallelism must run exactly the cap concurrently — never more, and more than one (proving it is not serial)."
        )
    }

    func testAlreadyCancelledSyncThrowsBeforeFetchingAnySource() async throws {
        let catalogURL = URL(string: "https://api.lavasecurity.app/v1/catalog")!
        let sourceURL = URL(string: "https://upstream.example.com/a.txt")!
        let rawText = "ads.example.com\n"
        let hash = BlocklistCatalogSynchronizer.sha256Hex(of: Data(rawText.utf8))
        let source = makeSource(id: "src-a", sourceURL: sourceURL, sourceHash: hash, normalizedHash: hash)
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260525T010000Z",
            generatedAt: Date(timeIntervalSince1970: 1_768_386_495),
            sources: [source],
            guardrails: []
        )
        let catalogData = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        let requestLog = RequestLog()
        let taskBox = CancellableSyncTaskBox()

        let synchronizer = BlocklistCatalogSynchronizer(
            catalogURL: catalogURL,
            cacheDirectoryURL: try makeTemporaryCacheDirectory(),
            dataFetcher: { url in
                await requestLog.append(url)
                if url == catalogURL {
                    // Cancel before the source loop begins: the first
                    // checkCancellation must throw before any source is fetched.
                    await taskBox.cancelWhenReady()
                    return catalogData
                }

                return Data(rawText.utf8)
            }
        )

        let task = Task<Void, Error> {
            _ = try await synchronizer.sync(enabledSourceIDs: [source.id])
        }
        await taskBox.register(task)

        do {
            _ = try await task.value
            XCTFail("Expected the cancelled sync to throw CancellationError")
        } catch is CancellationError {
            // Expected.
        }

        let requested = await requestLog.snapshot()
        XCTAssertEqual(
            requested,
            [catalogURL],
            "A cancelled sync must stop at the top of the compile loop, before fetching any source."
        )
    }

    private func makeSource(
        id: String,
        sourceURL: URL = URL(string: "https://example.com/source")!,
        licenseName: String = "Test",
        sourceHash: String = String(repeating: "0", count: 64),
        acceptedSourceHashes: [CatalogAcceptedSourceHash]? = nil,
        normalizedHash: String = String(repeating: "1", count: 64),
        redistributionMode: String = "source_url_only",
        parseFormat: CatalogParseFormat = .plainDomains
    ) -> CatalogBlocklistSource {
        CatalogBlocklistSource(
            id: id,
            name: id,
            category: "security",
            riskLevel: "normal",
            defaultEnabled: true,
            licenseName: licenseName,
            attribution: "Test",
            projectURL: URL(string: "https://example.com/project")!,
            sourceURL: sourceURL,
            versionID: "\(id)-20260516T042929Z",
            entryCount: 1,
            byteSize: 16,
            sourceHash: sourceHash,
            acceptedSourceHashes: acceptedSourceHashes ?? (
                sourceHash.isEmpty ? [] : [
                    CatalogAcceptedSourceHash(
                        sha256: sourceHash,
                        byteSize: 16,
                        entryCount: 1,
                        reviewedAt: Date(timeIntervalSince1970: 1_768_385_371)
                    )
                ]
            ),
            normalizedHash: normalizedHash,
            publishedAt: Date(timeIntervalSince1970: 1_768_385_371),
            redistributionMode: redistributionMode,
            parseFormat: parseFormat,
            licenseTextURL: nil,
            noticeURL: nil
        )
    }

    private func makeTemporaryCacheDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCatalog(_ catalog: BlocklistCatalog, to cacheURL: URL) throws {
        let catalogDirectoryURL = cacheURL.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDirectoryURL, withIntermediateDirectories: true)
        let data = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        try data.write(to: catalogDirectoryURL.appendingPathComponent("latest.json"))
    }

    private func writeLatestBlocklist(_ text: String, sourceID: String, to cacheURL: URL) throws {
        let sourceDirectoryURL = cacheURL
            .appendingPathComponent("blocklists", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: sourceDirectoryURL.appendingPathComponent("latest.txt"))
    }

    private func writeLatestCustomBlocklist(_ text: String, sourceID: String, to cacheURL: URL) throws {
        let sourceDirectoryURL = cacheURL
            .appendingPathComponent("custom-blocklists", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: sourceDirectoryURL.appendingPathComponent("latest.txt"))
    }

    private func writeVersionedBlocklist(
        _ text: String,
        source: CatalogBlocklistSource,
        checksumSHA256: String,
        to cacheURL: URL
    ) throws {
        let sourceDirectoryURL = cacheURL
            .appendingPathComponent("blocklists", isDirectory: true)
            .appendingPathComponent(source.id, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        let hashPrefix = String(checksumSHA256.prefix(12))
        let fileURL = sourceDirectoryURL.appendingPathComponent("\(source.versionID)-\(hashPrefix).txt")
        try Data(text.utf8).write(to: fileURL)
    }
}

private actor RequestLog {
    private(set) var urls: [URL] = []

    func append(_ url: URL) {
        urls.append(url)
    }

    func snapshot() -> [URL] {
        urls
    }
}

/// Lets a fetcher cancel the very sync task it runs inside, without racing the
/// `register` call from the test thread: `cancelWhenReady` waits until the task
/// has been registered, then cancels it, so the next `Task.checkCancellation()`
/// in the compile loop deterministically throws.
private actor CancellableSyncTaskBox {
    private var task: Task<Void, Error>?
    private var isRegistered = false
    private var registrationContinuation: CheckedContinuation<Void, Never>?

    func register(_ task: Task<Void, Error>) {
        self.task = task
        isRegistered = true
        registrationContinuation?.resume()
        registrationContinuation = nil
    }

    func cancelWhenReady() async {
        if !isRegistered {
            await withCheckedContinuation { continuation in
                registrationContinuation = continuation
            }
        }

        task?.cancel()
    }
}

/// Records the peak number of fetchers running concurrently.
private actor ConcurrencyTracker {
    private(set) var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}

/// Releases all waiters once `threshold` have arrived; arrivals past the
/// threshold pass straight through. Used to force exactly `threshold` fetchers
/// to overlap so the peak concurrency is deterministically observable.
private actor ArrivalGate {
    private let threshold: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(threshold: Int) {
        self.threshold = threshold
    }

    func arriveAndWait() async {
        arrived += 1
        if arrived >= threshold {
            let resuming = waiters
            waiters.removeAll()
            for waiter in resuming {
                waiter.resume()
            }
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
