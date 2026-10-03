import XCTest

final class VoiceModelStoreTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/fixture/models")

    func testCompleteWhenEveryRequiredFileExists() {
        XCTAssertEqual(VoiceModelStore.missing(in: root, fileExists: { _ in true }), [])
    }

    func testMissingListsRelativePathsInOrder() {
        let present: Set<String> = Set(VoiceModelStore.requiredFiles.dropLast(2).map {
            root.appendingPathComponent($0).path
        })
        let missing = VoiceModelStore.missing(in: root, fileExists: { present.contains($0) })
        XCTAssertEqual(missing, Array(VoiceModelStore.requiredFiles.suffix(2)))
        XCTAssertEqual(missing.last, "kokoro-82m-coreml/ANE/bm_fable.bin")
    }

    func testRequiredFilesCoverBothEnginesAndTheVoicePack() {
        let files = VoiceModelStore.requiredFiles
        XCTAssertTrue(files.contains("argmaxinc/whisperkit-coreml/openai_whisper-base/AudioEncoder.mlmodelc"))
        XCTAssertTrue(files.contains("openai/whisper-base/tokenizer.json"))
        XCTAssertTrue(files.contains("kokoro-82m-coreml/ANE/KokoroVocoder.mlmodelc"))
        XCTAssertTrue(files.contains("kokoro-82m-coreml/ANE/bm_fable.bin"))
        XCTAssertEqual(Set(files).count, files.count, "no duplicates")
    }

    func testDirectoryIsUnderApplicationSupport() {
        XCTAssertTrue(VoiceModelStore.directory.path.hasSuffix("/Library/Application Support/MuxMaestro/models"))
        XCTAssertEqual(VoiceModelStore.directory.deletingLastPathComponent(), VoiceModelStore.supportDirectory)
    }

    func testVoicePackIsVendored() {
        let pack = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("app/MuxMaestro/Resources/voice/\(VoiceModelStore.voicePackFile)")
        let size = (try? FileManager.default.attributesOfItem(atPath: pack.path)[.size] as? Int) ?? 0
        // A Kokoro voice pack is a [510, 256] float32 matrix.
        XCTAssertEqual(size, 510 * 256 * 4, pack.path)
    }

    func testLabels() {
        XCTAssertEqual(VoiceModelStore.label(for: .checking), "…")
        XCTAssertEqual(VoiceModelStore.label(for: .downloading(stage: "Whisper", fraction: 0.419)), "Whisper 41%")
        XCTAssertEqual(VoiceModelStore.label(for: .downloading(stage: "Kokoro", fraction: 1)), "Kokoro 100%")
        XCTAssertEqual(VoiceModelStore.label(for: .compiling), "Compiling")
        XCTAssertEqual(VoiceModelStore.label(for: .ready), "Ready")
        XCTAssertEqual(VoiceModelStore.label(for: .failed("offline")), "Failed")
    }
}
