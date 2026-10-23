import XCTest
import MLX
@testable import VectaMLX

/// Model-free GigaAM checks: word grouping, window policy and a tiny synthetic
/// Conformer + RNN-T / CTC checkpoint run end to end. No real weights are used.
final class GigaAMTests: XCTestCase {
    func testSentencePieceWordsKeepPunctuationAndTiming() {
        let vocabulary = ["<unk>", "▁при", "вет", ",", "▁мир", ".", "<0xD0>", "<0x96>", "▁"]
        let tokens = [(1, 2), (2, 3), (3, 4), (4, 10), (5, 12), (8, 13), (6, 15), (7, 16)]
        let words = GigaAMModel.words(tokens: tokens, vocabulary: vocabulary, sentencePiece: true, controlTokens: [], frameSeconds: 0.04)
        XCTAssertEqual(words.map(\.text), [" привет,", " мир.", " Ж"])
        XCTAssertEqual(words[0].start, 0.08, accuracy: 1e-9)
        XCTAssertEqual(words[0].end, 0.2, accuracy: 1e-9)
        XCTAssertEqual(words[1].start, 0.4, accuracy: 1e-9)
        XCTAssertEqual(words[2].end, 0.68, accuracy: 1e-9)
    }

    func testCharacterVocabularyAndControlTokens() {
        let vocabulary = [" ", "а", "б"]
        let words = GigaAMModel.words(tokens: [(1, 0), (2, 1), (0, 2), (2, 3), (1, 9)], vocabulary: vocabulary, sentencePiece: false, controlTokens: [], frameSeconds: 0.1)
        XCTAssertEqual(words.map(\.text), [" аб", " ба"])
        XCTAssertEqual(GigaAMModel.words(tokens: [(0, 0)], vocabulary: ["<s>", "▁a"], sentencePiece: true, controlTokens: [0], frameSeconds: 0.04).map(\.text), [])
    }

    func testWindowsMatchTheSpeechWorkerPolicy() throws {
        let windows = try GigaAMSpeech.windows(duration: 45, chunk: 20, overlap: 2)
        XCTAssertEqual(windows.count, 3)
        XCTAssertEqual(windows[0].start, 0); XCTAssertEqual(windows[0].end, 22)
        XCTAssertEqual(windows[1].coreStart, 20); XCTAssertEqual(windows[1].start, 18)
        XCTAssertEqual(windows[2].coreEnd, 45); XCTAssertEqual(windows[2].end, 45)
        XCTAssertThrowsError(try GigaAMSpeech.windows(duration: 45, chunk: 10, overlap: 2))
    }

    // MARK: Synthetic checkpoint

    private var seed: UInt64 = 0x9E3779B97F4A7C15
    private func values(_ count: Int, scale: Float = 0.2) -> [Float] {
        (0..<count).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Float(seed >> 40) / Float(1 << 24) - 0.5) * 2 * scale
        }
    }
    private func array(_ shape: [Int], scale: Float = 0.2) -> MLXArray {
        MLXArray(values(shape.reduce(1, *), scale: scale), shape).asType(.float16)
    }

    private func writeSyntheticModel(head: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gigaam-synthetic-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let d = 8, features = 4, kernel = 5, vocabulary = ["▁a", "b", "."], classes = 4, pred = 6, joint = 5
        var weights: [String: MLXArray] = [
            "mel_filterbank": MLXArray(values(161 * features, scale: 1).map { abs($0) }, [161, features]),
            "stft_window": MLXArray((0..<320).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / 320) }),
            "encoder.pre_encode.conv.0.weight": array([d, kernel, features]), "encoder.pre_encode.conv.0.bias": array([d]),
            "encoder.pre_encode.conv.2.weight": array([d, kernel, d]), "encoder.pre_encode.conv.2.bias": array([d]),
        ]
        let p = "encoder.layers.0."
        for norm in ["norm_feed_forward1", "norm_self_att", "norm_conv", "norm_feed_forward2", "norm_out", "conv.batch_norm"] {
            weights[p + norm + ".weight"] = MLXArray([Float](repeating: 1, count: d)).asType(.float16)
            weights[p + norm + ".bias"] = array([d])
        }
        for ff in ["feed_forward1", "feed_forward2"] {
            weights[p + ff + ".linear1.weight"] = array([4 * d, d]); weights[p + ff + ".linear1.bias"] = array([4 * d])
            weights[p + ff + ".linear2.weight"] = array([d, 4 * d]); weights[p + ff + ".linear2.bias"] = array([d])
        }
        for projection in ["linear_q", "linear_k", "linear_v", "linear_out"] {
            weights[p + "self_attn." + projection + ".weight"] = array([d, d]); weights[p + "self_attn." + projection + ".bias"] = array([d])
        }
        weights[p + "conv.pointwise_conv1.weight"] = array([2 * d, 1, d]); weights[p + "conv.pointwise_conv1.bias"] = array([2 * d])
        weights[p + "conv.depthwise_conv.weight"] = array([d, kernel, 1]); weights[p + "conv.depthwise_conv.bias"] = array([d])
        weights[p + "conv.pointwise_conv2.weight"] = array([d, 1, d]); weights[p + "conv.pointwise_conv2.bias"] = array([d])
        var configuration: [String: Any] = [
            "model_type": "gigaam", "sample_rate": 16000,
            "preprocessor": ["sample_rate": 16000, "features": features, "win_length": 320, "hop_length": 160, "n_fft": 320, "center": false],
            "encoder": ["feat_in": features, "n_layers": 1, "d_model": d, "subsampling": "conv1d", "subs_kernel_size": kernel, "subsampling_factor": 4,
                        "ff_expansion_factor": 4, "self_attention_model": "rotary", "pos_emb_max_len": 5000, "n_heads": 2, "conv_kernel_size": kernel, "conv_norm_type": "layer_norm"],
            "head_type": head, "vocabulary": vocabulary, "tokenizer_type": "sentencepiece", "tokenizer_control_token_ids": [Int](),
        ]
        if head == "rnnt" {
            configuration["head"] = ["decoder": ["pred_hidden": pred, "pred_rnn_layers": 1, "num_classes": classes],
                                     "joint": ["enc_hidden": d, "pred_hidden": pred, "joint_hidden": joint, "num_classes": classes]]
            weights["head.decoder.embed.weight"] = array([classes, pred])
            weights["head.decoder.lstm.Wx"] = array([4 * pred, pred]); weights["head.decoder.lstm.Wh"] = array([4 * pred, pred])
            weights["head.decoder.lstm.bias"] = array([4 * pred])
            weights["head.joint.enc.weight"] = array([joint, d]); weights["head.joint.enc.bias"] = array([joint])
            weights["head.joint.pred.weight"] = array([joint, pred]); weights["head.joint.pred.bias"] = array([joint])
            weights["head.joint.joint_net_linear.weight"] = array([classes, joint], scale: 2); weights["head.joint.joint_net_linear.bias"] = array([classes])
        } else {
            configuration["head"] = ["feat_in": d, "num_classes": classes]
            weights["head.decoder_layers.0.weight"] = array([classes, 1, d], scale: 2); weights["head.decoder_layers.0.bias"] = array([classes])
        }
        try save(arrays: weights, url: directory.appendingPathComponent("model.safetensors"))
        try JSONSerialization.data(withJSONObject: configuration).write(to: directory.appendingPathComponent("config.json"))
        return directory
    }

    private func checkSyntheticRun(head: String) throws {
        let directory = try writeSyntheticModel(head: head)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try GigaAMModel(directory: directory)
        let samples = values(16000 * 3, scale: 0.3)
        let features = try model.features(samples)
        XCTAssertEqual(features.shape, [1, 1 + (samples.count - 320) / 160, 4])
        let encoded = try model.encode(features)
        XCTAssertEqual(encoded.shape, [75, 8])
        XCTAssertTrue(encoded.asArray(Float.self).allSatisfy(\.isFinite))
        let words = try model.transcribe(samples)
        for word in words {
            XCTAssertTrue(word.text.hasPrefix(" "))
            XCTAssertTrue(word.start >= 0 && word.end >= word.start && word.end <= 3)
        }
    }

    func testSyntheticRNNTCheckpointRunsEndToEnd() throws { try checkSyntheticRun(head: "rnnt") }
    func testSyntheticCTCCheckpointRunsEndToEnd() throws { try checkSyntheticRun(head: "ctc") }

    func testMismatchedCheckpointIsRejected() throws {
        let directory = try writeSyntheticModel(head: "ctc")
        defer { try? FileManager.default.removeItem(at: directory) }
        var configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as! [String: Any]
        configuration["vocabulary"] = ["▁a"]
        try JSONSerialization.data(withJSONObject: configuration).write(to: directory.appendingPathComponent("config.json"))
        XCTAssertThrowsError(try GigaAMModel(directory: directory))
    }
}
