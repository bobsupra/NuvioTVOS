import Foundation
import XCTest
@testable import NuvioTV

final class PlaybackBackendPolicyTests: XCTestCase {

    func testMPVHTTPHeaderOptionsExtractAndEscapeHeaders() {
        let options = MPVHTTPHeaderOptions(headers: [
            "uSeR-aGeNt": "TrailerClient/1.0",
            "ReFeReR": "https://example.test/embed",
            "X-Trailer": "one,two\\three",
            "Empty": ""
        ])

        XCTAssertEqual(options.userAgent, "TrailerClient/1.0")
        XCTAssertEqual(options.referrer, "https://example.test/embed")
        XCTAssertEqual(options.headerFields, "X-Trailer: one\\,two\\three")
    }

    func testMPVHTTPHeaderOptionsResetMissingValues() {
        let options = MPVHTTPHeaderOptions(headers: [
            "Referer": "",
            "User-Agent": "",
            "Authorization": "Bearer token"
        ])

        XCTAssertEqual(options.userAgent, "libmpv")
        XCTAssertEqual(options.referrer, "")
        XCTAssertEqual(options.headerFields, "Authorization: Bearer token")
    }

    func testAISubtitleSettingsMigratesRetiredModelToSupportedDefault() {
        XCTAssertEqual(
            AISubtitleTranslationSettings.normalizedModel("gemini-2.0-flash"),
            AISubtitleTranslationSettings.defaultModel
        )
        XCTAssertEqual(
            AISubtitleTranslationSettings.normalizedModel("gemini-3.5-flash-lite"),
            "gemini-3.5-flash-lite"
        )
        XCTAssertEqual(
            AISubtitleTranslationSettings.normalizedModel("gemma-4-26b-a4b-it"),
            "gemma-4-26b-a4b-it"
        )
        XCTAssertEqual(
            AISubtitleTranslationSettings.normalizedModel("gemma-3-27b-it"),
            AISubtitleTranslationSettings.defaultModel
        )
    }

    func testGeminiTranslatorSendsKeyInHeaderRatherThanURL() async throws {
        GeminiURLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-api-key")
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertTrue(components.queryItems?.isEmpty ?? true)
            XCTAssertEqual(request.httpMethod, "POST")
            let requestBody = try XCTUnwrap(GeminiURLProtocolStub.body(from: request))
            let requestJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
            )
            let generationConfig = try XCTUnwrap(requestJSON["generationConfig"] as? [String: Any])
            let thinkingConfig = try XCTUnwrap(generationConfig["thinkingConfig"] as? [String: Any])
            XCTAssertEqual(thinkingConfig["thinkingLevel"] as? String, "minimal")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(#"{"candidates":[{"content":{"parts":[{"text":"Hei"}]}}]}"#.utf8))
        }
        defer { GeminiURLProtocolStub.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiURLProtocolStub.self]
        let translated = try await GeminiSubtitleTranslator.translate(
            "Hello",
            to: "Norwegian",
            model: AISubtitleTranslationSettings.defaultModel,
            apiKey: "test-api-key",
            session: URLSession(configuration: configuration)
        )

        XCTAssertEqual(translated, "Hei")
    }

    func testGeminiBatchTranslatorPreservesCueIDs() async throws {
        GeminiURLProtocolStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "test-api-key")
            let requestBody = try XCTUnwrap(GeminiURLProtocolStub.body(from: request))
            let requestJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
            )
            let generationConfig = try XCTUnwrap(requestJSON["generationConfig"] as? [String: Any])
            let thinkingConfig = try XCTUnwrap(generationConfig["thinkingConfig"] as? [String: Any])
            XCTAssertEqual(thinkingConfig["thinkingLevel"] as? String, "minimal")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = #"{"candidates":[{"content":{"parts":[{"text":"[{\"id\":7,\"text\":\"Hei\"},{\"id\":9,\"text\":\"Ha det\"}]"}]}}]}"#
            return (response, Data(payload.utf8))
        }
        defer { GeminiURLProtocolStub.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiURLProtocolStub.self]
        let translated = try await GeminiSubtitleTranslator.translateBatch(
            [
                .init(id: 7, text: "Hello"),
                .init(id: 9, text: "Goodbye"),
            ],
            to: "Norwegian",
            model: AISubtitleTranslationSettings.defaultModel,
            apiKey: "test-api-key",
            session: URLSession(configuration: configuration)
        )

        XCTAssertEqual(translated, [7: "Hei", 9: "Ha det"])
    }

    func testGemma4BatchAvoidsUnsupportedStructuredOutputAndFiltersThoughts() async throws {
        GeminiURLProtocolStub.handler = { request in
            XCTAssertTrue(request.url?.absoluteString.contains("gemma-4-26b-a4b-it:generateContent") == true)
            let requestBody = try XCTUnwrap(GeminiURLProtocolStub.body(from: request))
            let requestJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
            )
            let generationConfig = try XCTUnwrap(requestJSON["generationConfig"] as? [String: Any])
            XCTAssertNil(generationConfig["responseMimeType"])
            XCTAssertEqual(generationConfig["temperature"] as? Double, 1.0)
            XCTAssertEqual(generationConfig["topP"] as? Double, 0.95)
            XCTAssertEqual(generationConfig["topK"] as? Int, 64)
            let thinkingConfig = try XCTUnwrap(generationConfig["thinkingConfig"] as? [String: Any])
            XCTAssertEqual(thinkingConfig["thinkingLevel"] as? String, "minimal")

            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = #"{"candidates":[{"content":{"parts":[{"thought":true,"text":"internal"},{"text":"```json\n[{\"id\":7,\"text\":\"Hei\"}]\n```"}]}}]}"#
            return (response, Data(payload.utf8))
        }
        defer { GeminiURLProtocolStub.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiURLProtocolStub.self]
        let translated = try await GeminiSubtitleTranslator.translateBatch(
            [.init(id: 7, text: "Hello")],
            to: "Norwegian",
            model: "gemma-4-26b-a4b-it",
            apiKey: "test-api-key",
            session: URLSession(configuration: configuration)
        )

        XCTAssertEqual(translated, [7: "Hei"])
    }

    func testOpenRouterBatchTranslatorDisablesReasoningForEveryModelAndPreservesCueIDs() async throws {
        GeminiURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-api-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
            XCTAssertEqual(request.httpMethod, "POST")
            let requestBody = try XCTUnwrap(GeminiURLProtocolStub.body(from: request))
            let requestJSON = try XCTUnwrap(
                JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
            )
            let reasoning = try XCTUnwrap(requestJSON["reasoning"] as? [String: Any])
            XCTAssertEqual(reasoning["enabled"] as? Bool, false)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let payload = #"{"choices":[{"message":{"content":"```json\n[{\"id\":7,\"text\":\"Hei\"},{\"id\":9,\"text\":\"Ha det\"}]\n```"}}]}"#
            return (response, Data(payload.utf8))
        }
        defer { GeminiURLProtocolStub.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiURLProtocolStub.self]
        XCTAssertEqual(
            OpenRouterSubtitleTranslator.batchOutputTokenLimit(
                for: [.init(id: 7, text: "Hello"), .init(id: 9, text: "Goodbye")]
            ),
            512
        )
        for model in [
            "qwen/qwen3.7-flash",
            "google/gemini-2.5-flash",
            "anthropic/claude-haiku-4.5",
        ] {
            let translated = try await OpenRouterSubtitleTranslator.translateBatch(
                [
                    .init(id: 7, text: "Hello"),
                    .init(id: 9, text: "Goodbye"),
                ],
                to: "Norwegian",
                model: model,
                apiKey: "test-api-key",
                session: URLSession(configuration: configuration)
            )

            XCTAssertEqual(translated, [7: "Hei", 9: "Ha det"])
        }
    }

    func testAISubtitleCachePersistsAndSeparatesTranslationSettings() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-subtitle-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = AISubtitleTranslationCache(directory: directory)
        await writer.store(
            "Hei",
            for: "Hello",
            targetLanguage: "Norwegian",
            model: "Gemini:gemini-3.6-flash",
            stripHearingImpaired: true,
            profileScope: "profile-a"
        )

        let reader = AISubtitleTranslationCache(directory: directory)
        let cached = await reader.translation(
            for: "Hello",
            targetLanguage: "Norwegian",
            model: "Gemini:gemini-3.6-flash",
            stripHearingImpaired: true,
            profileScope: "profile-a"
        )
        let otherLanguage = await reader.translation(
            for: "Hello",
            targetLanguage: "German",
            model: "Gemini:gemini-3.6-flash",
            stripHearingImpaired: true,
            profileScope: "profile-a"
        )
        let otherProfile = await reader.translation(
            for: "Hello",
            targetLanguage: "Norwegian",
            model: "Gemini:gemini-3.6-flash",
            stripHearingImpaired: true,
            profileScope: "profile-b"
        )
        let otherProvider = await reader.translation(
            for: "Hello",
            targetLanguage: "Norwegian",
            model: "OpenRouter:gemini-3.6-flash",
            stripHearingImpaired: true,
            profileScope: "profile-a"
        )

        XCTAssertEqual(cached, "Hei")
        XCTAssertNil(otherLanguage)
        XCTAssertNil(otherProfile)
        XCTAssertNil(otherProvider)
    }

    func testAISubtitleCachePersistsACompletedBatch() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-subtitle-batch-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = AISubtitleTranslationCache(directory: directory)
        await writer.store(
            [
                .init(translatedText: "Hei", source: "Hello"),
                .init(translatedText: "Ha det", source: "Goodbye"),
            ],
            targetLanguage: "Norwegian",
            model: "Gemini:gemini-3.6-flash",
            stripHearingImpaired: true,
            profileScope: "profile-a"
        )

        let reader = AISubtitleTranslationCache(directory: directory)
        let hello = await reader.translation(
            for: "Hello",
            targetLanguage: "Norwegian",
            model: "Gemini:gemini-3.6-flash",
            stripHearingImpaired: true,
            profileScope: "profile-a"
        )
        let goodbye = await reader.translation(
            for: "Goodbye",
            targetLanguage: "Norwegian",
            model: "Gemini:gemini-3.6-flash",
            stripHearingImpaired: true,
            profileScope: "profile-a"
        )

        XCTAssertEqual(hello, "Hei")
        XCTAssertEqual(goodbye, "Ha det")
    }

    @MainActor
    func testAISubtitleCleaningPreservesDialogue() {
        XCTAssertEqual(
            AISubtitleTranslationState.cleaned(
                "[MUSIC] Hello (door closes) ♪",
                stripHearingImpaired: true
            ),
            "Hello"
        )
    }

    @MainActor
    func testAISubtitleNormalizedSourceIgnoresCueLayoutChangesAfterSeek() {
        XCTAssertEqual(
            AISubtitleTranslationState.normalizedSource("Welcome,\n  home!"),
            AISubtitleTranslationState.normalizedSource("Welcome, home!")
        )
    }

    func testAISubtitleBatchesRespectCueCountBudgetAndCueOrder() {
        let countLimited = (1...41).map { AISubtitleTranslationItem(id: $0, text: "Hi") }
        let byteLimited = [
            AISubtitleTranslationItem(id: 101, text: String(repeating: "a", count: 5_000)),
            AISubtitleTranslationItem(id: 102, text: String(repeating: "b", count: 5_000)),
            AISubtitleTranslationItem(id: 103, text: "After long cues"),
        ]

        let countBatches = AISubtitleBatching.batches(countLimited)
        let byteBatches = AISubtitleBatching.batches(byteLimited)

        XCTAssertEqual(countBatches.map(\.count), [40, 1])
        XCTAssertEqual(countBatches.flatMap { $0.map(\.id) }, countLimited.map(\.id))
        XCTAssertEqual(byteBatches.map { $0.map(\.id) }, [[101], [102, 103]])
        XCTAssertTrue(AISubtitleBatching.estimatedRequestBytes(for: byteLimited) > AISubtitleBatching.maximumEstimatedRequestBytes)
    }

    func testAISubtitleAdaptiveBufferRefillsAtLowWatermarkAndStopsAtHighWatermark() {
        XCTAssertFalse(
            AISubtitleAdaptiveBuffer.shouldRefill(
                nextUntranslatedStart: 121,
                sourceTime: 100
            )
        )
        XCTAssertTrue(
            AISubtitleAdaptiveBuffer.shouldRefill(
                nextUntranslatedStart: 120,
                sourceTime: 100
            )
        )
        XCTAssertTrue(
            AISubtitleAdaptiveBuffer.shouldRefill(
                nextUntranslatedStart: 95,
                sourceTime: 100
            )
        )
        XCTAssertTrue(
            AISubtitleAdaptiveBuffer.isInsideRefillWindow(
                cueStart: 160,
                sourceTime: 100
            )
        )
        XCTAssertFalse(
            AISubtitleAdaptiveBuffer.isInsideRefillWindow(
                cueStart: 160.01,
                sourceTime: 100
            )
        )
    }

    func testBatchResponseValidationRejectsMissingDuplicateAndMalformedIDs() async {
        let invalidResponses = [
            #"[{"id":7,"text":"Hei"}]"#,
            #"[{"id":7,"text":"Hei"},{"id":7,"text":"Hei igjen"}]"#,
            #"[{"id":99,"text":"Hei"},{"id":9,"text":"Ha det"}]"#,
            "not JSON",
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiURLProtocolStub.self]
        defer { GeminiURLProtocolStub.handler = nil }

        for responseText in invalidResponses {
            GeminiURLProtocolStub.handler = { request in
                let response = HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                let payload: [String: Any] = [
                    "candidates": [["content": ["parts": [["text": responseText]]]]]
                ]
                return (response, try JSONSerialization.data(withJSONObject: payload))
            }

            do {
                _ = try await GeminiSubtitleTranslator.translateBatch(
                    [.init(id: 7, text: "Hello"), .init(id: 9, text: "Goodbye")],
                    to: "Norwegian",
                    model: AISubtitleTranslationSettings.defaultModel,
                    apiKey: "test-api-key",
                    session: URLSession(configuration: configuration)
                )
                XCTFail("Expected invalid batch response to be rejected")
            } catch let error as AISubtitleTranslationError {
                guard case .invalidResponse = error else {
                    return XCTFail("Unexpected translation error: \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRetryPolicyHonorsRetryAfterAndStopsAfterFiveAttempts() {
        let throttled = AISubtitleTranslationError.service(
            statusCode: 429,
            message: "Too many requests",
            retryAfter: 17
        )
        let temporary = AISubtitleTranslationError.service(
            statusCode: 503,
            message: "Service unavailable",
            retryAfter: nil
        )

        XCTAssertEqual(AISubtitleRetryPolicy.retryAfter(from: "17"), 17)
        XCTAssertEqual(AISubtitleRetryPolicy.delay(for: throttled, completedAttempts: 1), 17)
        XCTAssertEqual(
            AISubtitleRetryPolicy.delay(
                for: temporary,
                completedAttempts: 1,
                jitterMultiplier: 1
            ),
            4
        )
        XCTAssertEqual(
            AISubtitleRetryPolicy.delay(
                for: temporary,
                completedAttempts: 1,
                jitterMultiplier: 0.85
            ),
            3.4
        )
        XCTAssertNotNil(AISubtitleRetryPolicy.delay(for: temporary, completedAttempts: 4))
        XCTAssertNil(AISubtitleRetryPolicy.delay(for: temporary, completedAttempts: 5))
    }

    func testTranslatorHonorsRetryAfterAndStopsAfterFiveTemporaryFailures() async {
        let attempts = RequestCounter()
        GeminiURLProtocolStub.handler = { request in
            attempts.increment()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 503,
                httpVersion: nil,
                headerFields: ["Retry-After": "0"]
            )!
            return (response, Data(#"{"error":{"message":"temporary outage"}}"#.utf8))
        }
        defer { GeminiURLProtocolStub.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiURLProtocolStub.self]
        do {
            _ = try await AISubtitleTranslator.translate(
                "Hello",
                settings: aiSettings(model: "retry-test"),
                session: URLSession(configuration: configuration),
                pacer: AISubtitleRequestPacer(minimumSpacing: 0)
            )
            XCTFail("Expected retry exhaustion")
        } catch let error as AISubtitleTranslationError {
            guard case .service(let statusCode, _, _) = error else {
                return XCTFail("Unexpected translation error: \(error)")
            }
            XCTAssertEqual(statusCode, 503)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(attempts.value, AISubtitleRetryPolicy.maximumAttempts)
    }

    func testRetryPolicyDoesNotRetryQuotaBillingOrDailyLimitErrors() {
        for message in ["quota exhausted", "billing account inactive", "daily limit reached"] {
            let error = AISubtitleTranslationError.service(
                statusCode: 429,
                message: message,
                retryAfter: nil
            )
            XCTAssertFalse(error.isRetryable)
            XCTAssertNil(AISubtitleRetryPolicy.delay(for: error, completedAttempts: 1))
            XCTAssertTrue(error.localizedDescription.contains("Original subtitles will remain visible"))
        }
    }

    func testTemporaryQuotaThrottleWithRetryAfterRemainsRetryable() {
        let error = AISubtitleTranslationError.service(
            statusCode: 429,
            message: "Quota exceeded for requests per minute",
            retryAfter: 12
        )

        XCTAssertTrue(error.isRetryable)
        XCTAssertFalse(error.isPermanentLimitError)
        XCTAssertEqual(AISubtitleRetryPolicy.delay(for: error, completedAttempts: 1), 12)
    }

    func testTranslatorDoesNotRetryPermanentQuotaErrors() async {
        let attempts = RequestCounter()
        GeminiURLProtocolStub.handler = { request in
            attempts.increment()
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 429,
                httpVersion: nil,
                headerFields: [:]
            )!
            return (response, Data(#"{"error":{"message":"daily quota exceeded"}}"#.utf8))
        }
        defer { GeminiURLProtocolStub.handler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GeminiURLProtocolStub.self]
        do {
            _ = try await AISubtitleTranslator.translate(
                "Hello",
                settings: aiSettings(model: "quota-test"),
                session: URLSession(configuration: configuration),
                pacer: AISubtitleRequestPacer(minimumSpacing: 0)
            )
            XCTFail("Expected quota failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Original subtitles will remain visible"))
        }
        XCTAssertEqual(attempts.value, 1)
    }

    func testOversizedBatchSplitsAtCueBoundariesAndRecovers() async throws {
        let items = (1...4).map { AISubtitleTranslationItem(id: $0, text: "Cue \($0)") }
        let recorder = BatchAttemptRecorder()

        let translations = try await AISubtitleBatchRecovery.translate(items) { batch in
            await recorder.record(batch.map(\.id))
            if batch.count > 1 {
                throw AISubtitleTranslationError.service(
                    statusCode: 413,
                    message: "Request too large",
                    retryAfter: nil
                )
            }
            return Dictionary(uniqueKeysWithValues: batch.map { ($0.id, "T\($0.id)") })
        }

        XCTAssertEqual(translations, [1: "T1", 2: "T2", 3: "T3", 4: "T4"])
        let attempts = await recorder.calls()
        XCTAssertEqual(attempts, [[1, 2, 3, 4], [1, 2], [1], [2], [3, 4], [3], [4]])
    }

    func testMalformedBatchResponseSplittingIsBounded() async {
        let items = (1...8).map { AISubtitleTranslationItem(id: $0, text: "Cue \($0)") }
        let recorder = BatchAttemptRecorder()

        do {
            _ = try await AISubtitleBatchRecovery.translate(items) { batch in
                await recorder.record(batch.map(\.id))
                throw AISubtitleTranslationError.invalidResponse
            }
            XCTFail("Expected malformed responses to exhaust the split budget")
        } catch let error as AISubtitleTranslationError {
            guard case .invalidResponse = error else {
                return XCTFail("Unexpected translation error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let attempts = await recorder.calls()
        XCTAssertEqual(attempts, [[1, 2, 3, 4, 5, 6, 7, 8], [1, 2, 3, 4], [1, 2]])
    }

    @MainActor
    func testMPVCancellationAndSettingsChangesRejectStaleResults() async throws {
        let pacer = AISubtitleRequestPacer(minimumSpacing: 0)
        let state = MPVSubtitleTranslationState(requestPacer: pacer) { source, _, _ in
            if source == "Old" || source == "Before settings" {
                try await Task.sleep(nanoseconds: 40_000_000)
                return "stale"
            }
            return "fresh"
        }
        let initial = aiSettings(model: "test-model-a")
        let changed = aiSettings(model: "test-model-b")

        state.update(sourceText: "Old", settings: initial)
        state.cancelPendingTranslations()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNil(state.translatedText)
        XCTAssertEqual(state.sourceText, "Old")

        state.update(sourceText: "Before settings", settings: initial)
        state.update(sourceText: "New", settings: changed)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(state.sourceText, "New")
        XCTAssertEqual(state.translatedText, "fresh")
    }

    @MainActor
    func testMPVRequestsUseTheSharedProviderModelLimiter() async throws {
        let model = "mpv-limiter-\(UUID().uuidString)"
        let settings = aiSettings(model: model)
        let before = await AISubtitleRequestPacer.shared.acquisitionCount(
            provider: settings.provider.rawValue,
            model: model
        )
        let state = MPVSubtitleTranslationState { _, requestSettings, pacer in
            try await pacer.acquire(
                provider: requestSettings.provider.rawValue,
                model: requestSettings.model
            )
            return "translated"
        }
        XCTAssertTrue(state.requestPacer === AISubtitleRequestPacer.shared)

        state.update(sourceText: "Limiter \(UUID().uuidString)", settings: settings)
        try await Task.sleep(nanoseconds: 500_000_000)

        let after = await AISubtitleRequestPacer.shared.acquisitionCount(
            provider: settings.provider.rawValue,
            model: model
        )
        XCTAssertEqual(after, before + 1)
    }

    @MainActor
    func testMPVReportsFirstSuccessAndFirstLaterFailure() async throws {
        let state = MPVSubtitleTranslationState(
            requestPacer: AISubtitleRequestPacer(minimumSpacing: 0)
        ) { source, _, _ in
            if source == "First" { return "Første" }
            throw AISubtitleTranslationError.service(
                statusCode: 429,
                message: "daily quota exceeded",
                retryAfter: nil
            )
        }
        var outcomes: [String] = []
        state.onFirstOutcome = { outcome in
            switch outcome {
            case .success: outcomes.append("success")
            case .failure: outcomes.append("failure")
            }
        }

        state.update(sourceText: "First", settings: aiSettings(model: "outcome-test"))
        await waitForWhile { outcomes.count >= 1 }
        state.update(sourceText: "Second", settings: aiSettings(model: "outcome-test"))
        await waitForWhile { outcomes.count >= 2 }

        XCTAssertEqual(outcomes, ["success", "failure"])
    }

    @MainActor
    func testMPVEmptySubtitleDoesNotReportMissingAPIKey() {
        let state = MPVSubtitleTranslationState()
        var outcomeCount = 0
        state.onFirstOutcome = { _ in outcomeCount += 1 }
        let settings = AISubtitleTranslationSettings(
            isEnabled: true,
            provider: .gemini,
            apiKey: "",
            model: "empty-cue-test",
            targetLanguage: "Norwegian",
            autoSelect: true,
            stripHearingImpaired: true
        )

        state.update(sourceText: "", settings: settings)

        XCTAssertEqual(outcomeCount, 0)
        XCTAssertFalse(state.shouldDisplayOverlay)
    }

    @MainActor
    func testAISubtitleOutcomeToastIsSuppressedForTrailersAndLiveStreams() {
        XCTAssertFalse(
            PlayerViewModel.shouldShowAISubtitleOutcome(
                subtitle: PlaybackMarkers.trailerSubtitle,
                isLiveStream: false
            )
        )
        XCTAssertFalse(
            PlayerViewModel.shouldShowAISubtitleOutcome(
                subtitle: "Live channel",
                isLiveStream: true
            )
        )
        XCTAssertTrue(
            PlayerViewModel.shouldShowAISubtitleOutcome(
                subtitle: "Episode 1",
                isLiveStream: false
            )
        )
    }

    private func aiSettings(model: String) -> AISubtitleTranslationSettings {
        AISubtitleTranslationSettings(
            isEnabled: true,
            provider: .gemini,
            apiKey: "test-api-key",
            model: model,
            targetLanguage: "Norwegian",
            autoSelect: true,
            stripHearingImpaired: true
        )
    }

    func testAutoSelectsAetherWithFallback() {
        let result = PlaybackBackendPolicy.resolve(
            .init(
                urlString: "https://cdn.example/movie.mkv",
                separateAudioURL: nil,
                streamName: nil,
                streamDescription: nil,
                filename: nil,
                engineSetting: .auto,
                requiresMPVAudioControls: false,
                assMode: .strip
            )
        )
        XCTAssertEqual(result.backend, .aether)
        XCTAssertTrue(result.allowAutomaticFallback)
    }

    func testForcedMPV() {
        let result = PlaybackBackendPolicy.resolve(
            .init(
                urlString: "https://cdn.example/movie.mkv",
                separateAudioURL: nil,
                streamName: nil,
                streamDescription: nil,
                filename: nil,
                engineSetting: .mpv,
                requiresMPVAudioControls: false,
                assMode: .strip
            )
        )
        XCTAssertEqual(result.backend, .mpv)
        XCTAssertFalse(result.allowAutomaticFallback)
    }

    func testForcedAetherDisablesOrdinaryFallback() {
        let result = PlaybackBackendPolicy.resolve(
            .init(
                urlString: "https://cdn.example/movie.mkv",
                separateAudioURL: nil,
                streamName: nil,
                streamDescription: nil,
                filename: nil,
                engineSetting: .aether,
                requiresMPVAudioControls: false,
                assMode: .strip
            )
        )
        XCTAssertEqual(result.backend, .aether)
        XCTAssertFalse(result.allowAutomaticFallback)
    }

    func testSeparateAudioURLForcesMPV() {
        let result = PlaybackBackendPolicy.resolve(
            .init(
                urlString: "https://cdn.example/video.mp4",
                separateAudioURL: "https://cdn.example/audio.m4a",
                streamName: nil,
                streamDescription: nil,
                filename: nil,
                engineSetting: .auto,
                requiresMPVAudioControls: false,
                assMode: .strip
            )
        )
        XCTAssertEqual(result.backend, .mpv)
        XCTAssertFalse(result.allowAutomaticFallback)
    }

    func testAudioControlsForceMPV() {
        let result = PlaybackBackendPolicy.resolve(
            .init(
                urlString: "https://cdn.example/movie.mkv",
                separateAudioURL: nil,
                streamName: nil,
                streamDescription: nil,
                filename: nil,
                engineSetting: .auto,
                requiresMPVAudioControls: true,
                assMode: .strip
            )
        )
        XCTAssertEqual(result.backend, .mpv)
    }

    func testASSScaleForcesMPV() {
        let result = PlaybackBackendPolicy.resolve(
            .init(
                urlString: "https://cdn.example/anime.mkv",
                separateAudioURL: nil,
                streamName: nil,
                streamDescription: nil,
                filename: nil,
                engineSetting: .auto,
                requiresMPVAudioControls: false,
                assMode: .scale
            )
        )
        XCTAssertEqual(result.backend, .mpv)
    }

    func testSettingsMigration() {
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "Auto"), .auto)
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "AVPlayer"), .auto)
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "MPVKit"), .mpv)
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "mpv"), .mpv)
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "AetherEngine"), .aether)
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "unknown"), .auto)
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "AVPlayer").settingsRawValue, "Auto")
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "AetherEngine").settingsRawValue, "AetherEngine")
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "MPVKit").settingsRawValue, "MPVKit")
    }

    func testMPVFallbackConfigurationPreservesSessionState() throws {
        let videoURL = try XCTUnwrap(URL(string: "https://cdn.example/movie.mkv"))
        let subtitle = NuvioSubtitle(
            url: "https://cdn.example/en.srt",
            language: "eng",
            label: "English"
        )
        let request = PlaybackLoadRequest(
            videoURL: videoURL,
            resumePositionSeconds: 123.456,
            externalSubtitles: [subtitle],
            autoplay: false,
            playbackRate: 1.5,
            subtitleDelaySeconds: -0.25,
            audioDelaySeconds: 0.175,
            audioGainDB: 4
        )

        let configuration = MPVLoadConfiguration(request: request)

        XCTAssertEqual(configuration.resumePositionMs, 123_456)
        XCTAssertEqual(configuration.externalSubtitles, [subtitle])
        XCTAssertEqual(configuration.playbackRate, 1.5)
        XCTAssertEqual(configuration.subtitleDelaySeconds, -0.25)
        XCTAssertEqual(configuration.audioDelaySeconds, 0.175)
        XCTAssertEqual(configuration.audioGainDB, 4)
        XCTAssertFalse(configuration.autoplay)
    }

    func testCacheSegmentMapping() {
        XCTAssertEqual(PlaybackCacheProfile.conservative.aetherForwardBufferSegments, 4)
        XCTAssertEqual(PlaybackCacheProfile.auto.aetherForwardBufferSegments, 10)
        XCTAssertEqual(PlaybackCacheProfile.large.aetherForwardBufferSegments, 30)
        XCTAssertEqual(PlaybackCacheProfile.max.aetherForwardBufferSegments, 60)
    }

    @MainActor
    func testAetherExternalSubtitleIdentityKeepsOrderWhenOneIsRejected() {
        let english = NuvioSubtitle(
            url: "https://cdn.example/en.srt", language: "en", label: "English"
        )
        let norwegian = NuvioSubtitle(
            url: "https://cdn.example/no.srt", language: "no", label: "Norsk"
        )

        let accepted = AetherExternalSubtitleIdentity.accepted(
            [NuvioSubtitle(url: "", language: "", label: nil), english, norwegian]
        )

        XCTAssertEqual(accepted.map(\.subtitle.url), [english.url, norwegian.url])
        XCTAssertEqual(accepted.map(\.url.absoluteString), [english.url, norwegian.url])
    }

    @MainActor
    func testAutomaticSubtitlePreferenceKeepsBackendSelectedPreferredTrack() {
        let full = SubtitleTrack(
            id: "2",
            name: "ENG (Full)",
            language: "eng",
            isSelected: true
        )

        XCTAssertTrue(
            PlayerViewModel.shouldPreserveBackendSubtitleSelection(
                full,
                preferredLanguages: ["English"]
            )
        )
        XCTAssertFalse(
            PlayerViewModel.shouldPreserveBackendSubtitleSelection(
                SubtitleTrack(id: "off", name: "Off", language: "", isSelected: true),
                preferredLanguages: ["English"]
            )
        )
    }

    @MainActor
    func testAetherOverlayStatePublishesClockIndependently() {
        let state = AetherSubtitleOverlayState()
        state.updateSourceTime(12.5)

        XCTAssertEqual(state.sourceTime, 12.5)
    }

    @MainActor
    func testAetherDisplaySizeAppliesAnamorphicPixelAspectRatio() {
        let size = AetherPlaybackController.displayVideoSize(
            codedWidth: 720,
            codedHeight: 576,
            pixelAspectRatio: 64.0 / 45.0
        )

        XCTAssertEqual(size.width, 1024, accuracy: 0.001)
        XCTAssertEqual(size.height, 576, accuracy: 0.001)
    }
}

private final class GeminiURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func body(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor BatchAttemptRecorder {
    private var attempts: [[Int]] = []

    func record(_ ids: [Int]) {
        attempts.append(ids)
    }

    func calls() -> [[Int]] {
        attempts
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Waits up to 5 seconds for `condition`, yielding to the main actor so the
/// async work under test can complete. The outcome tests used fixed sleeps,
/// which flaked under full-suite load; polling until a condition is
/// deterministic instead.
@MainActor
private func waitForWhile(_ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline {
        await Task.yield()
    }
}

final class CatalogWatchedPolicyTests: XCTestCase {
    func testSeriesIsWatchedWhenEveryAiredRegularEpisodeIsWatched() {
        let videos = [
            episode(season: 0, episode: 1, released: "2000-01-01"),
            episode(season: 1, episode: 1, released: "2000-01-01"),
            episode(season: 1, episode: 2, released: "2000-01-02"),
            episode(season: 1, episode: 3, released: "2999-01-01"),
        ]

        XCTAssertTrue(
            CatalogWatchedPolicy.hasWatchedAllAiredEpisodes(
                videos: videos,
                watchedEpisodeKeys: ["1:1", "1:2"]
            )
        )
    }

    func testSeriesIsNotWatchedWhenAnAiredEpisodeIsMissing() {
        let videos = [
            episode(season: 1, episode: 1, released: "2000-01-01"),
            episode(season: 1, episode: 2, released: "2000-01-02"),
        ]

        XCTAssertFalse(
            CatalogWatchedPolicy.hasWatchedAllAiredEpisodes(
                videos: videos,
                watchedEpisodeKeys: ["1:1"]
            )
        )
    }

    private func episode(season: Int, episode: Int, released: String) -> NuvioVideo {
        NuvioVideo(
            id: "test:\(season):\(episode)",
            title: "Episode \(episode)",
            season: season,
            episode: episode,
            thumbnail: nil,
            overview: nil,
            released: released,
            rating: nil
        )
    }
}

final class WholeSeriesWatchedTests: XCTestCase {
    private let profileId = "whole-series-watched-tests"

    override func setUp() {
        super.setUp()
        WatchedStore.setActiveProfile(profileId)
        WatchedStore.eraseProfile(profileId)
    }

    override func tearDown() {
        WatchedStore.eraseProfile(profileId)
        super.tearDown()
    }

    func testMarkingSeriesMarksOnlyAiredRegularEpisodes() {
        let meta = NuvioMeta(
            id: "tt-whole-series",
            name: "Whole Series",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt-whole-series",
            tmdbId: nil,
            type: "series",
            year: 2020,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            videos: [
                episode(season: 0, episode: 1, released: "2000-01-01"),
                episode(season: 1, episode: 1, released: "2000-01-01"),
                episode(season: 1, episode: 2, released: "2999-01-01"),
                episode(season: 2, episode: 1, released: "2000-01-01")
            ]
        )

        XCTAssertTrue(WatchedStore.markWatched(meta, season: 0, episode: 1))
        XCTAssertTrue(WatchedStore.markWatched(meta, season: 1, episode: 2))
        XCTAssertTrue(WatchedStore.toggle(meta: meta))

        let rows = WatchedStore.items().filter { WatchedStore.sameContent($0.meta, meta) }
        let keys = Set(rows.map { row in
            guard let season = row.season, let episode = row.episode else { return "title" }
            return "\(season):\(episode)"
        })
        XCTAssertEqual(keys, ["title", "0:1", "1:1", "1:2", "2:1"])

        XCTAssertFalse(WatchedStore.toggle(meta: meta))
        let remainingRows = WatchedStore.items().filter { WatchedStore.sameContent($0.meta, meta) }
        let remainingKeys = Set(remainingRows.map { row in
            guard let season = row.season, let episode = row.episode else { return "title" }
            return "\(season):\(episode)"
        })
        XCTAssertEqual(remainingKeys, ["0:1", "1:2"])
    }

    func testMarkingFinalSeasonCreatesPortraitSeriesMarker() {
        let meta = NuvioMeta(
            id: "tt-season-marker",
            name: "Season Marker Series",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt-season-marker",
            tmdbId: nil,
            type: "series",
            year: 2020,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            videos: [
                episode(season: 0, episode: 1, released: "2000-01-01"),
                episode(season: 1, episode: 1, released: "2000-01-01"),
                episode(season: 1, episode: 2, released: "2000-01-02"),
                episode(season: 1, episode: 3, released: "2999-01-01")
            ]
        )

        XCTAssertTrue(
            WatchedStore.setSeasonWatched(
                meta: meta,
                season: 1,
                episodes: [1, 2],
                isWatched: true
            )
        )
        XCTAssertTrue(WatchedStore.containsCatalogTitle(meta: meta))

        XCTAssertTrue(
            WatchedStore.setSeasonWatched(
                meta: meta,
                season: 1,
                episodes: [1],
                isWatched: false
            )
        )
        XCTAssertFalse(WatchedStore.containsCatalogTitle(meta: meta))
    }

    private func episode(season: Int, episode: Int, released: String) -> NuvioVideo {
        NuvioVideo(
            id: "test:\(season):\(episode)",
            title: "Episode \(episode)",
            season: season,
            episode: episode,
            thumbnail: nil,
            overview: nil,
            released: released,
            rating: nil
        )
    }
}

final class WatchedIdentityPolicyTests: XCTestCase {
    /// A mark belongs to the backend that was selected when it was made, and
    /// only that backend confirms it on a pull. Switching the selected source
    /// used to keep showing it, because every read saw the shared local union —
    /// a title watched only in Nuvio Sync kept its checkmark under Simkl, which
    /// neither account agreed with.
    func testAMarkIsOnlyVisibleUnderTheSourceThatHasIt() {
        let movie = makeMeta(id: "tt15047880", imdbId: "tt15047880", tmdbId: nil)
        let nuvioOnly = WatchedStoreItem(
            meta: movie,
            watchedAt: Date(),
            sources: [TraktWatchProgressSource.nuvioSync.rawValue]
        )

        XCTAssertTrue(nuvioOnly.isVisible(under: .nuvioSync))
        XCTAssertFalse(nuvioOnly.isVisible(under: .simkl))
        XCTAssertFalse(nuvioOnly.isVisible(under: .trakt))
    }

    /// The same title can genuinely be watched in two places, so attribution is
    /// a set — and collapsing duplicates has to union it rather than let the
    /// newer row's attribution erase the older one's.
    func testAttributionAccumulatesAcrossBackends() {
        let movie = makeMeta(id: "tt0816692", imdbId: "tt0816692", tmdbId: nil)
        let older = WatchedStoreItem(
            meta: movie,
            watchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sources: [TraktWatchProgressSource.nuvioSync.rawValue]
        )
        let newer = WatchedStoreItem(
            meta: movie,
            watchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            sources: [TraktWatchProgressSource.simkl.rawValue]
        )

        let merged = WatchedStore.mergedByIdentity([older, newer])

        XCTAssertEqual(merged.count, 1)
        let row = try? XCTUnwrap(merged.first)
        XCTAssertEqual(row?.watchedAt, newer.watchedAt, "newest row still wins on timing")
        XCTAssertTrue(row?.isVisible(under: .nuvioSync) ?? false)
        XCTAssertTrue(row?.isVisible(under: .simkl) ?? false)
    }

    /// Rows written before attribution existed carry an empty set. They stay
    /// visible everywhere until the migration backfills them, so an upgrade
    /// never blanks a user's checkmarks.
    func testUnattributedLegacyRowsStayVisibleUnderEverySource() {
        let legacy = WatchedStoreItem(
            meta: makeMeta(id: "tt0110912", imdbId: "tt0110912", tmdbId: nil),
            watchedAt: Date()
        )

        XCTAssertTrue(legacy.sources.isEmpty)
        for source in [TraktWatchProgressSource.nuvioSync, .simkl, .trakt] {
            XCTAssertTrue(legacy.isVisible(under: source))
        }
    }

    func testMatchesCatalogAndTraktItemsAcrossIMDbAndTMDBAliases() {
        let catalog = makeMeta(id: "tmdb:94997", imdbId: "tt11198330", tmdbId: 94997)
        let trakt = makeMeta(id: "tt11198330", imdbId: "tt11198330", tmdbId: 94997)

        XCTAssertTrue(WatchedStore.sameContent(catalog, trakt))
    }

    func testCatalogSeriesTitleFallbackMatchesProviderLocalAndCanonicalIDs() {
        let catalog = makeMeta(
            id: "provider:reacher", imdbId: nil, tmdbId: nil, name: "Reacher", year: 2022
        )
        let history = makeMeta(
            id: "tt9288030", imdbId: "tt9288030", tmdbId: 108978, name: "Reacher", year: 2022
        )

        XCTAssertTrue(WatchedStore.sameCatalogSeriesTitle(catalog, history))
    }

    func testCatalogSeriesTitleFallbackRejectsDifferentReleaseYears() {
        let original = makeMeta(
            id: "provider:show", imdbId: nil, tmdbId: nil, name: "The Show", year: 1999
        )
        let remake = makeMeta(
            id: "tt-remake", imdbId: "tt-remake", tmdbId: nil, name: "The Show", year: 2024
        )

        XCTAssertFalse(WatchedStore.sameCatalogSeriesTitle(original, remake))
    }

    func testDoesNotMatchDifferentTitlesThatShareAType() {
        let first = makeMeta(id: "tmdb:1", imdbId: nil, tmdbId: 1)
        let second = makeMeta(id: "tmdb:2", imdbId: nil, tmdbId: 2)

        XCTAssertFalse(WatchedStore.sameContent(first, second))
    }

    func testTraktSnapshotDoesNotDeleteWholeSeriesMarker() {
        let series = makeMeta(id: "tt11198330", imdbId: "tt11198330", tmdbId: 94997)
        let wholeSeries = WatchedStoreItem(meta: series, watchedAt: Date())
        let episode = WatchedStoreItem(meta: series, watchedAt: Date(), season: 3, episode: 4)
        let movie = WatchedStoreItem(
            meta: makeMeta(id: "tt0133093", imdbId: "tt0133093", tmdbId: 603, type: "movie"),
            watchedAt: Date()
        )

        XCTAssertFalse(WatchedStore.isRepresentedByTraktSnapshot(wholeSeries))
        XCTAssertTrue(WatchedStore.isRepresentedByTraktSnapshot(episode))
        XCTAssertTrue(WatchedStore.isRepresentedByTraktSnapshot(movie))
    }

    func testLargeHistoryMergeCompletesWithinWatchdogBudget() {
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var items = (0..<10_000).map { index in
            WatchedStoreItem(
                meta: makeMeta(id: "tmdb:\(index)", imdbId: nil, tmdbId: index, type: "movie"),
                watchedAt: baseDate.addingTimeInterval(Double(index))
            )
        }
        let replacementDate = baseDate.addingTimeInterval(20_000)
        items.append(
            WatchedStoreItem(
                meta: makeMeta(id: "tt0133093", imdbId: "tt0133093", tmdbId: 603, type: "movie"),
                watchedAt: replacementDate
            )
        )

        let startedAt = Date()
        let merged = WatchedStore.mergedByIdentity(items)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(merged.count, 10_000)
        XCTAssertEqual(merged.first?.watchedAt, replacementDate)
        XCTAssertLessThan(elapsed, 5, "History merge must stay below tvOS's 10-second watchdog window")
    }

    private func makeMeta(
        id: String,
        imdbId: String?,
        tmdbId: Int?,
        type: String = "series",
        name: String = "Test",
        year: Int? = nil
    ) -> NuvioMeta {
        NuvioMeta(
            id: id,
            name: name,
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: imdbId,
            tmdbId: tmdbId,
            type: type,
            year: year,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }
}

final class WatchedSourceReconciliationTests: XCTestCase {
    private let profileId = "watched-source-reconciliation-tests"

    override func setUp() {
        super.setUp()
        WatchedStore.setActiveProfile(profileId)
        WatchedStore.eraseProfile(profileId)
    }

    override func tearDown() {
        WatchedStore.eraseProfile(profileId)
        super.tearDown()
    }

    func testTraktAbsencePreservesTheSameEpisodeOwnedByNuvioSync() {
        let item = watchedEpisode(sources: [.nuvioSync, .trakt])
        XCTAssertTrue(WatchedStore.mergeRemote([item], confirmsTombstoneDeletions: false))

        XCTAssertTrue(
            WatchedStore.reconcileTraktSnapshot([], syncStartedAt: Date().addingTimeInterval(1))
        )

        XCTAssertEqual(
            WatchedStore.items().first?.sources,
            Set([TraktWatchProgressSource.nuvioSync.rawValue])
        )
    }

    func testTraktAbsenceRemovesAnEpisodeOwnedOnlyByTrakt() {
        let item = watchedEpisode(sources: [.trakt])
        XCTAssertTrue(WatchedStore.mergeRemote([item], confirmsTombstoneDeletions: false))

        XCTAssertTrue(
            WatchedStore.reconcileTraktSnapshot([], syncStartedAt: Date().addingTimeInterval(1))
        )

        XCTAssertTrue(WatchedStore.items().isEmpty)
        XCTAssertTrue(WatchedStore.tombstones().isEmpty)
    }

    func testSimklAbsencePreservesTheSameEpisodeOwnedByNuvioSync() {
        let merged = watchedEpisode(sources: [.nuvioSync, .simkl])
        let previousSimkl = watchedEpisode(sources: [.simkl])
        XCTAssertTrue(WatchedStore.mergeRemote([merged], confirmsTombstoneDeletions: false))

        XCTAssertTrue(
            WatchedStore.reconcileSimklSnapshot(
                [],
                previousRemoteItems: [previousSimkl],
                syncStartedAt: Date().addingTimeInterval(1)
            )
        )

        XCTAssertEqual(
            WatchedStore.items().first?.sources,
            Set([TraktWatchProgressSource.nuvioSync.rawValue])
        )
    }

    private func watchedEpisode(
        sources: Set<TraktWatchProgressSource>
    ) -> WatchedStoreItem {
        WatchedStoreItem(
            meta: NuvioMeta(
                id: "tt9288030",
                name: "Reacher",
                description: nil,
                posterUrl: nil,
                backgroundUrl: nil,
                logoUrl: nil,
                imdbId: "tt9288030",
                tmdbId: 108978,
                type: "series",
                year: 2022,
                genres: nil,
                rating: nil,
                releaseInfo: "2022",
                runtime: nil,
                cast: nil,
                director: nil,
                writer: nil,
                certification: nil,
                country: nil,
                released: nil
            ),
            watchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            season: 1,
            episode: 1,
            sources: Set(sources.map(\.rawValue))
        )
    }
}

final class EpisodeResumeIsolationTests: XCTestCase {
    private let profileId = "episode-resume-isolation-tests"

    override func setUp() {
        super.setUp()
        ContinueWatchingStore.setActiveProfile(profileId)
        WatchedStore.setActiveProfile(profileId)
        // Scoped: these suites run inside the app's own container, so a
        // directory-wide erase would take a real install's history with it.
        ContinueWatchingStore.eraseProfile(profileId)
        WatchedStore.eraseProfile(profileId)
    }

    override func tearDown() {
        ContinueWatchingStore.eraseProfile(profileId)
        WatchedStore.eraseProfile(profileId)
        super.tearDown()
    }

    @MainActor
    func testManuallyWatchedEpisodeSeedsASeasonRolloverAlert() {
        let meta = makeSeries()
        XCTAssertTrue(WatchedStore.markWatched(meta, season: 1, episode: 2))

        let seed = ContinueWatchingBuilder.watchedHistorySeeds().first
        XCTAssertEqual(seed?.season, 1)
        XCTAssertEqual(seed?.episode, 2)

        let day = Calendar.current.dateComponents(
            in: TimeZone.current,
            from: Date()
        )
        let today = String(
            format: "%04d-%02d-%02d",
            day.year ?? 2026,
            day.month ?? 1,
            day.day ?? 1
        )
        let returning = NuvioMeta(
            id: meta.id,
            name: meta.name,
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: meta.imdbId,
            tmdbId: meta.tmdbId,
            type: "series",
            year: meta.year,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            videos: [
                NuvioVideo(
                    id: "tt-test:2:1",
                    title: "Return",
                    season: 2,
                    episode: 1,
                    thumbnail: nil,
                    overview: nil,
                    released: today,
                    rating: nil
                )
            ]
        )
        let item = ContinueWatchingItem(
            meta: returning,
            streamUrl: "",
            position: 1,
            duration: 1_800,
            lastWatchedAt: seed?.lastWatchedAt ?? Date(),
            season: 2,
            episode: 1,
            released: today,
            isUpNext: true,
            upNextSeedSeason: seed?.season
        )
        XCTAssertEqual(item.upNextBadgeText, "AIRS TODAY")
    }

    func testEachEpisodeKeepsItsOwnResumePoint() {
        let meta = makeSeries()
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e01.mkv",
            position: 360,
            duration: 3_000,
            season: 1,
            episode: 1,
            episodeId: "tt-test:1:1"
        )
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e02.mkv",
            position: 480,
            duration: 3_000,
            season: 1,
            episode: 2,
            episodeId: "tt-test:1:2"
        )

        XCTAssertEqual(
            ContinueWatchingStore.resumePosition(
                for: meta, season: 1, episode: 1, episodeId: "tt-test:1:1"
            ),
            360
        )
        XCTAssertEqual(
            ContinueWatchingStore.resumePosition(
                for: meta, season: 1, episode: 2, episodeId: "tt-test:1:2"
            ),
            480
        )
        XCTAssertNil(
            ContinueWatchingStore.resumePosition(
                for: meta, season: 1, episode: 3, episodeId: "tt-test:1:3"
            )
        )
    }

    func testWatchedEpisodeDoesNotResumeOlderProgress() {
        let meta = makeSeries()
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e01.mkv",
            position: 360,
            duration: 3_000,
            season: 1,
            episode: 1,
            episodeId: "tt-test:1:1"
        )
        XCTAssertTrue(WatchedStore.markWatched(meta, season: 1, episode: 1))

        XCTAssertNil(
            ContinueWatchingStore.resumePosition(
                for: meta, season: 1, episode: 1, episodeId: "tt-test:1:1"
            )
        )
    }

    /// Marking an episode watched by hand has to settle the raw ledger as well
    /// as the rendered row: Continue Watching is rebuilt from the ledger, so a
    /// row left in progress there puts the episode's progress bar straight back
    /// on the next Home load or sync pull.
    func testWatchedEpisodeClearsTheLedgerRowBehindTheProgressBar() throws {
        let meta = makeSeries()
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e01.mkv",
            position: 360,
            duration: 3_000,
            season: 1,
            episode: 1,
            episodeId: "tt-test:1:1"
        )
        XCTAssertEqual(
            WatchProgressLedger.continueWatchingCandidates().first?.progressKey,
            "tt-test_s1e1"
        )

        XCTAssertTrue(WatchedStore.markWatched(meta, season: 1, episode: 1))

        XCTAssertTrue(WatchProgressLedger.continueWatchingCandidates().isEmpty)
        let record = try XCTUnwrap(
            WatchProgressLedger.record(contentId: meta.id, season: 1, episode: 1)
        )
        XCTAssertTrue(WatchProgressLedger.isComplete(record))
        // Completed rather than deleted, so it still seeds the next episode's
        // Next Up card exactly as watching it through would have.
        XCTAssertEqual(WatchProgressLedger.upNextSeeds().first?.progressKey, "tt-test_s1e1")
    }

    /// A mark on one episode must not retire another episode's progress.
    func testWatchedEpisodeLeavesOtherEpisodesInProgress() {
        let meta = makeSeries()
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e02.mkv",
            position: 480,
            duration: 3_000,
            season: 1,
            episode: 2,
            episodeId: "tt-test:1:2"
        )

        XCTAssertTrue(WatchedStore.markWatched(meta, season: 1, episode: 1))

        XCTAssertEqual(
            ContinueWatchingStore.resumePosition(
                for: meta, season: 1, episode: 2, episodeId: "tt-test:1:2"
            ),
            480
        )
        XCTAssertEqual(
            WatchProgressLedger.continueWatchingCandidates().first?.progressKey,
            "tt-test_s1e2"
        )
    }

    func testOlderRemoteProgressCannotOverwriteNewerEpisodeResume() {
        let meta = makeSeries()
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e01.mkv",
            position: 360,
            duration: 3_000,
            season: 1,
            episode: 1,
            episodeId: "tt-test:1:1"
        )
        let staleRemote = WatchProgressRecord(
            progressKey: "tt-test_s1e1",
            contentId: "tt-test",
            contentType: "series",
            videoId: "tt-test:1:1",
            season: 1,
            episode: 1,
            position: 120,
            duration: 3_000,
            lastWatchedAt: Date(timeIntervalSinceNow: -3_600)
        )

        XCTAssertTrue(WatchProgressLedger.mergeRemote([staleRemote]))
        XCTAssertEqual(WatchProgressLedger.record(forKey: "tt-test_s1e1")?.position, 360)
        XCTAssertEqual(
            ContinueWatchingStore.resumePosition(
                for: meta, season: 1, episode: 1, episodeId: "tt-test:1:1"
            ),
            360
        )
    }

    /// A finished episode must stay in the ledger: it is the seed that produces
    /// the next episode's Next Up card here and on every other device.
    func testFinishedEpisodeStaysInLedgerAfterLeavingContinueWatching() {
        let meta = makeSeries()
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e01.mkv",
            position: 2_990,
            duration: 3_000,
            season: 1,
            episode: 1,
            episodeId: "tt-test:1:1"
        )

        XCTAssertTrue(ContinueWatchingStore.items().isEmpty, "a finished episode should not render")
        let record = WatchProgressLedger.record(forKey: "tt-test_s1e1")
        XCTAssertNotNil(record, "a finished episode must remain a Next Up seed")
        XCTAssertEqual(WatchProgressLedger.upNextSeeds().first?.progressKey, "tt-test_s1e1")
    }

    func testUpNextCanFollowFurthestEpisodeOrMostRecentRewatch() {
        let now = Date()
        let furthest = WatchProgressRecord(
            progressKey: "tt-test_s3e5",
            contentId: "tt-test",
            contentType: "series",
            videoId: "tt-test:3:5",
            season: 3,
            episode: 5,
            position: 3_000,
            duration: 3_000,
            lastWatchedAt: now.addingTimeInterval(-86_400)
        )
        let recentRewatch = WatchProgressRecord(
            progressKey: "tt-test_s1e2",
            contentId: "tt-test",
            contentType: "series",
            videoId: "tt-test:1:2",
            season: 1,
            episode: 2,
            position: 3_000,
            duration: 3_000,
            lastWatchedAt: now
        )

        XCTAssertTrue(WatchProgressLedger.mergeRemote([furthest, recentRewatch]))
        XCTAssertEqual(
            WatchProgressLedger.upNextSeeds(preferFurthestEpisode: true).first?.progressKey,
            furthest.progressKey
        )
        XCTAssertEqual(
            WatchProgressLedger.upNextSeeds(preferFurthestEpisode: false).first?.progressKey,
            recentRewatch.progressKey
        )
    }

    /// Rows the phone stores without a runtime used to be discarded here, which
    /// is what made recently watched titles disappear from this device.
    func testRemoteRowWithoutDurationSurvivesAndRendersAsResumable() {
        let remote = WatchProgressRecord(
            progressKey: "tt-no-duration",
            contentId: "tt-no-duration",
            contentType: "movie",
            videoId: "tt-no-duration",
            season: nil,
            episode: nil,
            position: 600,
            duration: 0,
            lastWatchedAt: Date()
        )

        XCTAssertTrue(WatchProgressLedger.mergeRemote([remote]))
        XCTAssertEqual(WatchProgressLedger.records().count, 1)
        XCTAssertFalse(WatchProgressLedger.isComplete(remote))
        XCTAssertEqual(
            WatchProgressLedger.continueWatchingCandidates().first?.progressKey,
            "tt-no-duration"
        )
    }

    /// Completing during the credits must retire the episode, not leave it as
    /// resume progress. The ending marker fires below the 90% the ledger treats
    /// as finished, so recording the literal position left the row showing
    /// "8m left" forever and never produced a Next Up seed.
    func testCompletingDuringCreditsSeedsTheNextEpisode() {
        let meta = makeSeries()
        // Where a user typically is when the ending marker fires: past the story,
        // still short of the completion threshold.
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e02.mkv",
            position: 2_600,
            duration: 3_000,
            season: 1,
            episode: 2,
            episodeId: "tt-test:1:2"
        )
        XCTAssertTrue(
            WatchProgressLedger.upNextSeeds().isEmpty,
            "87% is not finished on its own"
        )

        ContinueWatchingStore.markPlaybackCompleted(
            meta: meta,
            duration: 3_000,
            season: 1,
            episode: 2
        )

        XCTAssertEqual(WatchProgressLedger.upNextSeeds().first?.progressKey, "tt-test_s1e2")
        XCTAssertFalse(
            WatchProgressLedger.continueWatchingCandidates()
                .contains { $0.progressKey == "tt-test_s1e2" },
            "a finished episode must not also be offered as resume progress"
        )
    }

    func testWatchedEpisodeWithPartialProgressSeedsNextUpAndLeavesCandidates() {
        let meta = makeSeries()
        // Save an in-progress playback position (e.g. 70%)
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e05.mkv",
            position: 1_400,
            duration: 2_000,
            season: 1,
            episode: 5,
            episodeId: "tt-test:1:5"
        )
        // Episode is marked watched in WatchedStore
        WatchedStore.markWatched(meta, season: 1, episode: 5)

        // Must NOT appear as an in-progress resume candidate
        XCTAssertFalse(
            WatchProgressLedger.continueWatchingCandidates()
                .contains { $0.progressKey == "tt-test_s1e5" },
            "an episode in WatchedStore must not be treated as an in-progress resume candidate"
        )
        // Must appear in upNextSeeds so Episode 6 can be surfaced
        XCTAssertTrue(
            WatchProgressLedger.upNextSeeds()
                .contains { $0.progressKey == "tt-test_s1e5" },
            "an episode in WatchedStore must be included in upNextSeeds to advance Next Up"
        )
    }

    /// A metadata rebuild can overlap the final playback save. Its old input
    /// must not be allowed to replace the newer display-only Next Up card.
    @MainActor
    func testRebuildRejectsLedgerSnapshotChangedByEpisodeCompletion() {
        let meta = makeSeries()
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e02.mkv",
            position: 2_400,
            duration: 3_000,
            season: 1,
            episode: 2,
            episodeId: "tt-test:1:2"
        )
        let rebuildSnapshot = WatchProgressLedger.records()
        XCTAssertTrue(ContinueWatchingBuilder.rebuildInputIsCurrent(rebuildSnapshot))

        ContinueWatchingStore.markPlaybackCompleted(
            meta: meta,
            duration: 3_000,
            season: 1,
            episode: 2
        )
        ContinueWatchingStore.saveUpNext(
            meta: meta,
            duration: 3_000,
            season: 1,
            episode: 3,
            seedSeason: 1
        )

        XCTAssertFalse(ContinueWatchingBuilder.rebuildInputIsCurrent(rebuildSnapshot))
        XCTAssertTrue(ContinueWatchingStore.item(for: meta.id)?.isUpNextEntry == true)
    }

    /// A just-finished episode must outrank months-old progress when the metadata
    /// budget is handed out, or the newest entries never get looked up and the
    /// row silently omits them.
    func testUpNextSeedsAreNotStarvedByOlderInProgressRows() {
        let now = Date()
        var records: [WatchProgressRecord] = (0..<70).map { index in
            WatchProgressRecord(
                progressKey: "tt-old-\(index)_s1e1",
                contentId: "tt-old-\(index)",
                contentType: "series",
                videoId: "tt-old-\(index):1:1",
                season: 1,
                episode: 1,
                position: 300,
                duration: 3_000,
                lastWatchedAt: now.addingTimeInterval(-86_400 * Double(index + 2))
            )
        }
        // Finished minutes ago, so it must be resolved before any of the above.
        records.append(
            WatchProgressRecord(
                progressKey: "tt-fresh_s1e1",
                contentId: "tt-fresh",
                contentType: "series",
                videoId: "tt-fresh:1:1",
                season: 1,
                episode: 1,
                position: 3_000,
                duration: 3_000,
                lastWatchedAt: now
            )
        )
        XCTAssertTrue(WatchProgressLedger.mergeRemote(records))

        let candidates = WatchProgressLedger.continueWatchingCandidates()
        let seeds = WatchProgressLedger.upNextSeeds()
        XCTAssertEqual(seeds.first?.contentId, "tt-fresh")

        // The builder's ordering: newest first across both kinds.
        let resolutionOrder = (candidates + seeds)
            .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
        let budgeted = resolutionOrder.prefix(64).map(\.contentId)
        XCTAssertTrue(
            budgeted.contains("tt-fresh"),
            "the freshest record must be inside the metadata budget"
        )
        XCTAssertEqual(budgeted.first, "tt-fresh")
    }

    /// The row pages through the whole account newest-first, so the first page a
    /// cold start shows is always the most recent activity — not whatever the
    /// ledger happened to list first.
    @MainActor
    func testRowPlanIsNewestFirstAndPagesTheWholeAccount() {
        let now = Date()
        let candidates: [WatchProgressRecord] = (0..<30).map { index in
            makeRecord(
                id: "tt-progress-\(index)",
                position: 300,
                lastWatchedAt: now.addingTimeInterval(-3_600 * Double(index + 1))
            )
        }
        let seeds: [WatchProgressRecord] = (0..<10).map { index in
            makeRecord(
                id: "tt-seed-\(index)",
                position: 3_000,
                lastWatchedAt: now.addingTimeInterval(-60 * Double(index + 1))
            )
        }

        let plan = ContinueWatchingBuilder.planEntries(candidates: candidates, seeds: seeds)

        XCTAssertEqual(plan.count, 40, "every title must be reachable by paging")
        // Seeds here are minutes old, progress is hours old, so seeds lead.
        XCTAssertEqual(plan.first?.record.contentId, "tt-seed-0")
        XCTAssertTrue(plan.prefix(10).allSatisfy(\.isSeed))
        let timestamps = plan.map(\.record.lastWatchedAt)
        XCTAssertEqual(timestamps, timestamps.sorted(by: >), "plan must be newest-first")
    }

    /// A title that is both in progress and has a finished episode must appear
    /// once, as resume progress — never as a duplicate Next Up card.
    @MainActor
    func testProgressOutranksASeedForTheSameTitle() {
        let now = Date()
        let candidate = makeRecord(id: "tt-same", position: 300, lastWatchedAt: now)
        let seed = makeRecord(
            id: "tt-same",
            position: 3_000,
            lastWatchedAt: now.addingTimeInterval(-600)
        )

        let plan = ContinueWatchingBuilder.planEntries(candidates: [candidate], seeds: [seed])

        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.isSeed, false)
    }

    private func makeRecord(
        id: String,
        position: Double,
        lastWatchedAt: Date
    ) -> WatchProgressRecord {
        WatchProgressRecord(
            progressKey: "\(id)_s1e1",
            contentId: id,
            contentType: "series",
            videoId: "\(id):1:1",
            season: 1,
            episode: 1,
            position: position,
            duration: 3_000,
            lastWatchedAt: lastWatchedAt
        )
    }

    /// The rendered list lives in Caches, which tvOS evicts under storage
    /// pressure — it is the only directory a tvOS app can write to on device.
    /// Losing it must cost the presentation, never the history.
    func testHistorySurvivesLosingTheRenderedList() {
        let meta = makeSeries()
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e01.mkv",
            position: 360,
            duration: 3_000,
            season: 1,
            episode: 1,
            episodeId: "tt-test:1:1"
        )
        XCTAssertFalse(ContinueWatchingStore.items().isEmpty)

        // Simulate the eviction: drop the derived file, keep the ledger.
        ContinueWatchingStore.simulateStorageEvictionForTesting()

        XCTAssertTrue(ContinueWatchingStore.items().isEmpty, "the rendered list is gone")
        XCTAssertEqual(
            WatchProgressLedger.continueWatchingCandidates().first?.progressKey,
            "tt-test_s1e1",
            "the history must still be there for the builder to re-render"
        )
    }

    /// Movie rows the backend discarded were still flagged as synced, so a
    /// corrected payload alone would never resend them. The recovery re-flags
    /// exactly those, and leaves episode rows — which did sync — alone.
    func testMovieRowsAreReflaggedForRepushExactlyOnce() {
        let now = Date()
        let movie = WatchProgressRecord(
            progressKey: "tt-movie",
            contentId: "tt-movie",
            contentType: "movie",
            videoId: "tt-movie",
            season: nil,
            episode: nil,
            position: 600,
            duration: 5_400,
            lastWatchedAt: now
        )
        let episode = WatchProgressRecord(
            progressKey: "tt-show_s1e1",
            contentId: "tt-show",
            contentType: "series",
            videoId: "tt-show:1:1",
            season: 1,
            episode: 1,
            position: 600,
            duration: 3_000,
            lastWatchedAt: now
        )
        XCTAssertTrue(WatchProgressLedger.mergeRemote([movie, episode]))
        XCTAssertEqual(WatchProgressLedger.record(forKey: "tt-movie")?.isPendingPush, false)

        WatchProgressLedger.repushMoviesOnceIfNeeded()

        XCTAssertEqual(
            WatchProgressLedger.record(forKey: "tt-movie")?.isPendingPush,
            true,
            "a movie the server never stored must be resent"
        )
        XCTAssertEqual(
            WatchProgressLedger.record(forKey: "tt-show_s1e1")?.isPendingPush,
            false,
            "episode rows synced fine and must not be re-uploaded"
        )

        // Clearing the flag again after a later successful push must stick —
        // the recovery is one-time, not a permanent re-upload loop.
        WatchProgressLedger.markPushed(keys: ["tt-movie"])
        WatchProgressLedger.repushMoviesOnceIfNeeded()
        XCTAssertEqual(WatchProgressLedger.record(forKey: "tt-movie")?.isPendingPush, false)
    }

    /// A pending local row must not shield stale history from newer server
    /// progress — otherwise a backfill from an older install would roll back
    /// what the user has since watched on their phone.
    func testNewerRemoteProgressWinsOverStalePendingLocalRow() {
        let staleLocal = ContinueWatchingItem(
            meta: makeSeries(),
            streamUrl: "",
            position: 300,
            duration: 3_000,
            lastWatchedAt: Date(timeIntervalSinceNow: -86_400),
            season: 1,
            episode: 1
        )
        WatchProgressLedger.backfillIfEmpty(from: [staleLocal])
        XCTAssertEqual(WatchProgressLedger.record(forKey: "tt-test_s1e1")?.isPendingPush, true)

        let newerRemote = WatchProgressRecord(
            progressKey: "tt-test_s1e1",
            contentId: "tt-test",
            contentType: "series",
            videoId: "tt-test:1:1",
            season: 1,
            episode: 1,
            position: 1_800,
            duration: 3_000,
            lastWatchedAt: Date()
        )

        XCTAssertTrue(WatchProgressLedger.mergeRemote([newerRemote]))
        XCTAssertEqual(WatchProgressLedger.record(forKey: "tt-test_s1e1")?.position, 1_800)
    }

    /// Continue Watching shows one row per series, newest first — matching
    /// `continueWatchingProgressEntries` in the phone app.
    func testCandidatesKeepOnlyTheNewestEpisodePerSeries() {
        let older = WatchProgressRecord(
            progressKey: "tt-test_s1e1",
            contentId: "tt-test",
            contentType: "series",
            videoId: "tt-test:1:1",
            season: 1,
            episode: 1,
            position: 300,
            duration: 3_000,
            lastWatchedAt: Date(timeIntervalSinceNow: -7_200)
        )
        let newer = WatchProgressRecord(
            progressKey: "tt-test_s1e2",
            contentId: "tt-test",
            contentType: "series",
            videoId: "tt-test:1:2",
            season: 1,
            episode: 2,
            position: 300,
            duration: 3_000,
            lastWatchedAt: Date()
        )

        XCTAssertTrue(WatchProgressLedger.mergeRemote([older, newer]))
        let candidates = WatchProgressLedger.continueWatchingCandidates()
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.progressKey, "tt-test_s1e2")
        // Both rows stay stored; only the rendered row is deduplicated.
        XCTAssertEqual(WatchProgressLedger.records().count, 2)
    }

    /// A row deleted on another device reaches this Apple TV only as an absence
    /// from the account snapshot. The union-only merge could not express that,
    /// so the deleted title stayed in Continue Watching here forever.
    func testAccountSnapshotDeletesRowsRemovedOnAnotherDevice() {
        let kept = WatchProgressRecord(
            progressKey: "tt-test_s1e1",
            contentId: "tt-test",
            contentType: "series",
            videoId: "tt-test:1:1",
            season: 1,
            episode: 1,
            position: 300,
            duration: 3_000,
            lastWatchedAt: Date(timeIntervalSinceNow: -7_200)
        )
        let deletedElsewhere = WatchProgressRecord(
            progressKey: "tt-test_s1e2",
            contentId: "tt-test",
            contentType: "series",
            videoId: "tt-test:1:2",
            season: 1,
            episode: 2,
            position: 300,
            duration: 3_000,
            lastWatchedAt: Date(timeIntervalSinceNow: -3_600)
        )
        XCTAssertTrue(WatchProgressLedger.mergeRemote([kept, deletedElsewhere]))
        XCTAssertEqual(WatchProgressLedger.records().count, 2)

        // The next pull no longer mentions the second row.
        let outcome = WatchProgressLedger.reconcileRemote([kept], syncStartedAt: Date())
        XCTAssertTrue(outcome.saved)
        XCTAssertEqual(outcome.removedKeys, ["tt-test_s1e2"])
        XCTAssertNil(WatchProgressLedger.record(forKey: "tt-test_s1e2"))
        XCTAssertNotNil(WatchProgressLedger.record(forKey: "tt-test_s1e1"))
    }

    /// Absence is only evidence of deletion for rows the server has seen. A row
    /// written here and not yet pushed is missing from the snapshot for an
    /// entirely different reason, and discarding it would lose real playback.
    func testAccountSnapshotKeepsRowsThisDeviceHasNotPushedYet() {
        let pending = WatchProgressRecord(
            progressKey: "tt-test_s1e1",
            contentId: "tt-test",
            contentType: "series",
            videoId: "tt-test:1:1",
            season: 1,
            episode: 1,
            position: 300,
            duration: 3_000,
            lastWatchedAt: Date(timeIntervalSinceNow: -60),
            isPendingPush: true
        )
        XCTAssertTrue(WatchProgressLedger.upsert(pending))

        let outcome = WatchProgressLedger.reconcileRemote([], syncStartedAt: Date())
        XCTAssertTrue(outcome.saved)
        XCTAssertTrue(outcome.removedKeys.isEmpty)
        XCTAssertNotNil(
            WatchProgressLedger.record(forKey: "tt-test_s1e1"),
            "an unpushed row must survive a snapshot that cannot know about it yet"
        )
    }

    /// A zero-row response is indistinguishable from a transient backend or
    /// profile-routing failure. Preserve the durable local ledger rather than
    /// making Continue Watching disappear after the delayed account pull.
    func testEmptyAccountSnapshotKeepsServerKnownRows() {
        let synced = WatchProgressRecord(
            progressKey: "tt-test_s1e1",
            contentId: "tt-test",
            contentType: "series",
            videoId: "tt-test:1:1",
            season: 1,
            episode: 1,
            position: 300,
            duration: 3_000,
            lastWatchedAt: Date(timeIntervalSinceNow: -7_200)
        )
        XCTAssertTrue(WatchProgressLedger.mergeRemote([synced]))

        let outcome = WatchProgressLedger.reconcileRemote([], syncStartedAt: Date())
        XCTAssertTrue(outcome.saved)
        XCTAssertTrue(outcome.removedKeys.isEmpty)
        XCTAssertNotNil(WatchProgressLedger.record(forKey: "tt-test_s1e1"))
    }

    private func makeSeries() -> NuvioMeta {
        NuvioMeta(
            id: "tt-test",
            name: "Test Series",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt-test",
            tmdbId: 123,
            type: "series",
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            videos: [
                NuvioVideo(id: "tt-test:1:1", title: "One", season: 1, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil),
                NuvioVideo(id: "tt-test:1:2", title: "Two", season: 1, episode: 2, thumbnail: nil, overview: nil, released: nil, rating: nil),
            ]
        )
    }
}

/// Removing a Continue Watching card has to stick even where the row is owned
/// by a provider that rebuilds it on every refresh — and it must never outlive
/// the user going back to the title.
final class ContinueWatchingDismissStoreTests: XCTestCase {
    private let profileId = "continue-watching-dismiss-tests"

    override func setUp() {
        super.setUp()
        ContinueWatchingStore.setActiveProfile(profileId)
        ContinueWatchingStore.eraseProfile(profileId)
    }

    override func tearDown() {
        ContinueWatchingStore.eraseProfile(profileId)
        super.tearDown()
    }

    func testDismissHidesOnlyTheRemovedEpisode() {
        let meta = makeSeries()
        let episodeOne = makeItem(meta: meta, season: 1, episode: 1)
        let episodeTwo = makeItem(meta: meta, season: 1, episode: 2)

        ContinueWatchingDismissStore.dismiss(episodeOne)

        XCTAssertTrue(ContinueWatchingDismissStore.isDismissed(episodeOne))
        XCTAssertFalse(
            ContinueWatchingDismissStore.isDismissed(episodeTwo),
            "removing one episode must not hide the show's next episode"
        )
    }

    func testDismissedMovieStaysDismissed() {
        let item = makeItem(meta: makeMovie(), season: nil, episode: nil)
        ContinueWatchingDismissStore.dismiss(item)
        XCTAssertTrue(ContinueWatchingDismissStore.isDismissed(item))
    }

    func testFreshProgressRetiresTheRemoval() {
        let meta = makeSeries()
        let item = makeItem(meta: meta, season: 1, episode: 1)
        ContinueWatchingDismissStore.dismiss(item)

        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e01.mkv",
            position: 360,
            duration: 3_000,
            season: 1,
            episode: 1,
            episodeId: "tt-dismiss-series:1:1"
        )

        XCTAssertFalse(
            ContinueWatchingDismissStore.isDismissed(item),
            "watching a removed title again must bring its card back"
        )
    }

    func testRemovalsAreScopedToTheActiveProfile() {
        let item = makeItem(meta: makeSeries(), season: 1, episode: 1)
        ContinueWatchingDismissStore.dismiss(item)

        ContinueWatchingStore.setActiveProfile("\(profileId)-other")
        XCTAssertFalse(ContinueWatchingDismissStore.isDismissed(item))

        ContinueWatchingStore.setActiveProfile(profileId)
        XCTAssertTrue(ContinueWatchingDismissStore.isDismissed(item))
    }

    func testUnreleasedPolicyUsesTheFullDateWithinTheCurrentYear() {
        let future = makeDatedMeta(id: "future", released: "2026-12-01")
        let past = makeDatedMeta(id: "past", released: "2026-01-01")

        XCTAssertTrue(ContentReleasePolicy.isUnreleased(future, today: "2026-07-26"))
        XCTAssertFalse(ContentReleasePolicy.isUnreleased(past, today: "2026-07-26"))
    }

    func testEpisodeAiringTodayUsesTodayLabel() {
        let item = makeUpNextItem(released: isoDay(daysAgo: 0), watchedDaysAgo: 1)

        XCTAssertEqual(item.airDateText, "Today")
        XCTAssertEqual(item.upNextBadgeText, "AIRS TODAY")
    }

    func testEpisodeGuideDateOverridesAStaleStoredAirDate() {
        let today = isoDay(daysAgo: 0)
        let item = ContinueWatchingItem(
            meta: makeMeta(id: "guide-date", type: "series", videos: [
                NuvioVideo(
                    id: "guide-date:1:4",
                    title: "Episode Four",
                    season: 1,
                    episode: 4,
                    thumbnail: nil,
                    overview: nil,
                    released: today,
                    rating: nil
                )
            ]),
            streamUrl: "",
            position: 1,
            duration: 1_800,
            lastWatchedAt: Date().addingTimeInterval(-86_400),
            season: 1,
            episode: 4,
            released: isoDay(daysAgo: 1),
            isUpNext: true
        )

        XCTAssertEqual(item.airDateText, "Today")
        XCTAssertEqual(item.upNextBadgeText, "AIRS TODAY")
    }

    func testEpisodeAiringTodaySurfacesWhenUpcomingEpisodesAreHidden() {
        let settings = ProfileSettings.current
        let previousValue = settings.object(forKey: EpisodeReleasePolicy.showUnairedNextUpKey)
        settings.set(false, forKey: EpisodeReleasePolicy.showUnairedNextUpKey)
        defer {
            if let previousValue {
                settings.set(previousValue, forKey: EpisodeReleasePolicy.showUnairedNextUpKey)
            } else {
                settings.removeObject(forKey: EpisodeReleasePolicy.showUnairedNextUpKey)
            }
        }

        XCTAssertTrue(
            EpisodeReleasePolicy.shouldSurfaceNextEpisode(
                watchedSeason: 1,
                candidateSeason: 1,
                released: isoDay(daysAgo: 0)
            )
        )
    }

    func testContinueWatchingNextUpSortMovesSuggestionsFirst() {
        let now = Date()
        let resume = ContinueWatchingItem(
            meta: makeDatedMeta(id: "resume", released: "2026-01-01"),
            streamUrl: "",
            position: 360,
            duration: 3_000,
            lastWatchedAt: now,
            isUpNext: false
        )
        let nextUp = ContinueWatchingItem(
            meta: makeDatedMeta(id: "next", released: "2025-01-01"),
            streamUrl: "",
            position: 1,
            duration: 3_000,
            lastWatchedAt: now.addingTimeInterval(-3_600),
            isUpNext: true
        )

        let sorted = ContinueWatchingSortPolicy.sorted(
            [resume, nextUp],
            preference: "Next up"
        )

        XCTAssertEqual(sorted.map(\.meta.id), ["next", "resume"])
    }

    /// A drop that landed while the viewer was away is news.
    func testUpNextBadgeReadsNewEpisodeWhenTheDropFollowedTheSeedWatch() {
        let item = makeUpNextItem(released: isoDay(daysAgo: 5), watchedDaysAgo: 30)
        XCTAssertEqual(item.upNextBadgeText, "NEW EPISODE")
    }

    /// The regression: an episode already out when the viewer finished the
    /// previous one is a backlog entry, so it must read "Next Up" even though it
    /// aired inside the release-alert window.
    func testUpNextBadgeReadsNextUpWhenTheEpisodeWasOutBeforeTheSeedWatch() {
        let item = makeUpNextItem(released: isoDay(daysAgo: 40), watchedDaysAgo: 2)
        XCTAssertEqual(item.upNextBadgeText, "NEXT UP")
    }

    /// Outside the window nothing is news, whatever the watch history says.
    func testUpNextBadgeReadsNextUpForAnEpisodeOlderThanTheAlertWindow() {
        let item = makeUpNextItem(
            released: isoDay(daysAgo: EpisodeReleasePolicy.newEpisodeWindowDays + 10),
            watchedDaysAgo: 400
        )
        XCTAssertEqual(item.upNextBadgeText, "NEXT UP")
    }

    /// A drop that opens a later season than the one being watched says so.
    func testUpNextBadgeReadsNewSeasonWhenTheDropCrossesASeason() {
        let item = makeUpNextItem(
            released: isoDay(daysAgo: 5),
            watchedDaysAgo: 30,
            season: 3,
            episode: 1,
            seedSeason: 2
        )
        XCTAssertEqual(item.upNextBadgeText, "NEW SEASON")
    }

    /// Within a season it stays "New Episode" — the premiere claim needs a real
    /// rollover, not just an episode 1.
    func testUpNextBadgeStaysNewEpisodeWithinTheSameSeason() {
        let item = makeUpNextItem(
            released: isoDay(daysAgo: 5),
            watchedDaysAgo: 30,
            season: 3,
            episode: 7,
            seedSeason: 3
        )
        XCTAssertEqual(item.upNextBadgeText, "NEW EPISODE")
    }

    /// A card persisted before the seed season was recorded must not guess at a
    /// rollover; it falls back to the plain drop badge.
    func testUpNextBadgeWithoutASeedSeasonDoesNotClaimANewSeason() {
        let item = makeUpNextItem(released: isoDay(daysAgo: 5), watchedDaysAgo: 30, season: 3, episode: 1)
        XCTAssertEqual(item.upNextBadgeText, "NEW EPISODE")
    }

    /// A rollover outside the alert window is not news at all, so it must not
    /// jump the "New Season" queue either.
    func testUpNextBadgeDoesNotClaimANewSeasonOutsideTheAlertWindow() {
        let item = makeUpNextItem(
            released: isoDay(daysAgo: EpisodeReleasePolicy.newEpisodeWindowDays + 10),
            watchedDaysAgo: 400,
            season: 3,
            episode: 1,
            seedSeason: 2
        )
        XCTAssertEqual(item.upNextBadgeText, "NEXT UP")
    }

    func testContinueWatchingDefaultSortsByRecencyAndPreservesTies() {
        let tieDate = Date(timeIntervalSince1970: 2_000)
        let older = makeSortItem(id: "older", lastWatchedAt: Date(timeIntervalSince1970: 1_000))
        let tieFirst = makeSortItem(id: "tie-first", lastWatchedAt: tieDate)
        let tieSecond = makeSortItem(id: "tie-second", lastWatchedAt: tieDate)
        let newer = makeSortItem(id: "newer", lastWatchedAt: Date(timeIntervalSince1970: 3_000))

        let sorted = ContinueWatchingSortPolicy.sorted(
            [older, tieFirst, newer, tieSecond],
            preference: "Default"
        )

        XCTAssertEqual(sorted.map(\.meta.id), ["newer", "tie-first", "tie-second", "older"])
    }

    func testContinueWatchingStreamingStyleSortsReleasedAndUpcomingGroups() {
        let drop = makeSortItem(
            id: "drop",
            lastWatchedAt: Date().addingTimeInterval(-86_400 * 200),
            released: isoDay(daysAgo: 1),
            isUpNext: true
        )
        let watched = makeSortItem(
            id: "watched",
            lastWatchedAt: Date().addingTimeInterval(-86_400 * 10)
        )
        let upcomingLate = makeSortItem(
            id: "upcoming-late",
            lastWatchedAt: Date().addingTimeInterval(-86_400 * 30),
            released: isoDay(daysFromToday: 5),
            isUpNext: true
        )
        let upcomingSoon = makeSortItem(
            id: "upcoming-soon",
            lastWatchedAt: Date().addingTimeInterval(-86_400 * 40),
            released: isoDay(daysFromToday: 2),
            isUpNext: true
        )

        let sorted = ContinueWatchingSortPolicy.sorted(
            [upcomingLate, watched, upcomingSoon, drop],
            preference: "Streaming Style"
        )

        XCTAssertEqual(sorted.map(\.meta.id), ["drop", "watched", "upcoming-soon", "upcoming-late"])
    }

    func testContinueWatchingSeparateUpcomingRowSplitsAndSortsBothRows() {
        let upcomingLate = makeSortItem(
            id: "upcoming-late",
            lastWatchedAt: Date(timeIntervalSince1970: 1_000),
            released: isoDay(daysFromToday: 6),
            isUpNext: true
        )
        let released = makeSortItem(
            id: "released",
            lastWatchedAt: Date(timeIntervalSince1970: 3_000)
        )
        let upcomingSoon = makeSortItem(
            id: "upcoming-soon",
            lastWatchedAt: Date(timeIntervalSince1970: 2_000),
            released: isoDay(daysFromToday: 1),
            isUpNext: true
        )
        let items = [upcomingLate, released, upcomingSoon]

        XCTAssertEqual(
            ContinueWatchingSortPolicy.sorted(items, preference: "Separate Upcoming Row").map(\.meta.id),
            ["released"]
        )
        XCTAssertEqual(
            ContinueWatchingSortPolicy.upcomingItems(items).map(\.meta.id),
            ["upcoming-soon", "upcoming-late"]
        )
    }

    func testUpcomingSortUsesCorrectedEpisodeGuideDateOverStaleStoredDate() {
        let correctedDate = isoDay(daysFromToday: 4)
        let correctedMeta = makeMeta(id: "corrected", type: "series", videos: [
            NuvioVideo(
                id: "corrected:1:1",
                title: "Episode One",
                season: 1,
                episode: 1,
                thumbnail: nil,
                overview: nil,
                released: correctedDate,
                rating: nil
            )
        ])
        let corrected = ContinueWatchingItem(
            meta: correctedMeta,
            streamUrl: "",
            position: 1,
            duration: 1_000,
            lastWatchedAt: Date(timeIntervalSince1970: 1_000),
            season: 1,
            episode: 1,
            // The persisted value is stale; the episode guide is authoritative.
            released: isoDay(daysAgo: 1),
            isUpNext: true
        )
        let middle = makeSortItem(
            id: "middle",
            lastWatchedAt: Date(timeIntervalSince1970: 2_000),
            released: isoDay(daysFromToday: 2),
            isUpNext: true
        )
        let later = makeSortItem(
            id: "later",
            lastWatchedAt: Date(timeIntervalSince1970: 3_000),
            released: isoDay(daysFromToday: 6),
            isUpNext: true
        )

        XCTAssertEqual(
            ContinueWatchingSortPolicy.upcomingItems([later, corrected, middle]).map(\.meta.id),
            ["middle", "corrected", "later"]
        )
    }

    /// A drop is ordered by its air date, so a show returning today outranks a
    /// title watched yesterday instead of sinking to the seed's age.
    func testNewEpisodeDropSortsByItsAirDateRatherThanTheSeedWatch() {
        let drop = makeUpNextItem(released: isoDay(daysAgo: 1), watchedDaysAgo: 200)
        let recentlyWatched = ContinueWatchingItem(
            meta: makeDatedMeta(id: "resume", released: "2026-01-01"),
            streamUrl: "",
            position: 600,
            duration: 3_000,
            lastWatchedAt: Date().addingTimeInterval(-86_400 * 3)
        )

        let sorted = ContinueWatchingSortPolicy.sorted(
            [recentlyWatched, drop],
            preference: "Recently watched"
        )
        XCTAssertEqual(sorted.map(\.meta.id), ["series", "resume"])
    }

    /// The same promotion applies among suggestions, where the up-next-first rule
    /// cannot be what decides the order.
    func testNewEpisodeDropOutranksAFresherPlainSuggestion() {
        let drop = makeUpNextItem(released: isoDay(daysAgo: 1), watchedDaysAgo: 200)
        let backlog = ContinueWatchingItem(
            meta: makeDatedMeta(id: "backlog", released: isoDay(daysAgo: 90)),
            streamUrl: "",
            position: 1,
            duration: 1_800,
            lastWatchedAt: Date().addingTimeInterval(-86_400 * 3),
            season: 1,
            episode: 4,
            released: isoDay(daysAgo: 90),
            isUpNext: true
        )

        let sorted = ContinueWatchingSortPolicy.sorted([backlog, drop], preference: "Next up")
        XCTAssertEqual(sorted.map(\.meta.id), ["series", "backlog"])
    }

    /// Only a drop is promoted: a plain Next Up still sorts on the watch time, or
    /// every stale suggestion would climb the row on its episode's release date.
    func testPlainNextUpKeepsSortingByWatchTime() {
        let backlog = makeUpNextItem(released: isoDay(daysAgo: 10), watchedDaysAgo: 2)
        XCTAssertEqual(backlog.recencySortDate, backlog.lastWatchedAt)
    }

    private func makeUpNextItem(
        released: String,
        watchedDaysAgo: Int,
        season: Int = 1,
        episode: Int = 4,
        seedSeason: Int? = nil
    ) -> ContinueWatchingItem {
        ContinueWatchingItem(
            meta: makeDatedMeta(id: "series", released: released),
            streamUrl: "",
            position: 1,
            duration: 1_800,
            lastWatchedAt: Date().addingTimeInterval(-86_400 * Double(watchedDaysAgo)),
            season: season,
            episode: episode,
            released: released,
            isUpNext: true,
            upNextSeedSeason: seedSeason
        )
    }

    private func isoDay(daysAgo: Int) -> String {
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let components = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone.current, from: day)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 2026,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    private func isoDay(daysFromToday: Int) -> String {
        let day = Calendar.current.date(byAdding: .day, value: daysFromToday, to: Date()) ?? Date()
        let components = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone.current, from: day)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 2026,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    private func makeSortItem(
        id: String,
        lastWatchedAt: Date,
        released: String? = nil,
        isUpNext: Bool = false
    ) -> ContinueWatchingItem {
        ContinueWatchingItem(
            meta: makeDatedMeta(id: id, released: released ?? "2000-01-01"),
            streamUrl: "",
            position: 100,
            duration: 1_000,
            lastWatchedAt: lastWatchedAt,
            released: released,
            isUpNext: isUpNext
        )
    }

    func testContinueWatchingReleaseSortUsesExactReleaseDate() {
        let older = ContinueWatchingItem(
            meta: makeDatedMeta(id: "older", released: "2026-02-01"),
            streamUrl: "",
            position: 100,
            duration: 1_000,
            lastWatchedAt: Date()
        )
        let newer = ContinueWatchingItem(
            meta: makeDatedMeta(id: "newer", released: "2026-09-01"),
            streamUrl: "",
            position: 100,
            duration: 1_000,
            lastWatchedAt: Date().addingTimeInterval(-86_400)
        )

        let sorted = ContinueWatchingSortPolicy.sorted(
            [older, newer],
            preference: "Release order"
        )

        XCTAssertEqual(sorted.map(\.meta.id), ["newer", "older"])
    }

    private func makeDatedMeta(id: String, released: String) -> NuvioMeta {
        NuvioMeta(
            id: id,
            name: id,
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: nil,
            tmdbId: nil,
            type: "movie",
            year: Int(released.prefix(4)),
            genres: nil,
            rating: nil,
            releaseInfo: released,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: released
        )
    }

    private func makeItem(meta: NuvioMeta, season: Int?, episode: Int?) -> ContinueWatchingItem {
        ContinueWatchingItem(
            meta: meta,
            streamUrl: "",
            position: 360,
            duration: 3_000,
            lastWatchedAt: Date(),
            season: season,
            episode: episode
        )
    }

    private func makeSeries() -> NuvioMeta {
        makeMeta(id: "tt-dismiss-series", type: "series", videos: [
            NuvioVideo(id: "tt-dismiss-series:1:1", title: "One", season: 1, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil),
            NuvioVideo(id: "tt-dismiss-series:1:2", title: "Two", season: 1, episode: 2, thumbnail: nil, overview: nil, released: nil, rating: nil),
        ])
    }

    private func makeMovie() -> NuvioMeta {
        makeMeta(id: "tt-dismiss-movie", type: "movie", videos: nil)
    }

    private func makeMeta(id: String, type: String, videos: [NuvioVideo]?) -> NuvioMeta {
        NuvioMeta(
            id: id,
            name: "Dismiss Test",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: id,
            tmdbId: nil,
            type: type,
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            videos: videos
        )
    }

}
