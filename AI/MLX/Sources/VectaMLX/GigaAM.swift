import Foundation
import Accelerate
import MLX

/// Local MLX runtime for Sber GigaAM v3 (Conformer encoder with CTC or RNN-T head).
/// It reads the MLX conversion layout: `config.json` plus one `model.safetensors`
/// whose Conv1d weights are `[out, kernel, in]` and whose LSTM bias is `ih + hh`.
/// Behaviour follows the upstream PyTorch reference (salute-developers/GigaAM):
/// RoPE is applied to the normalized input before the Q/K projections and its base
/// is `pos_emb_max_len`. No network access and no tokenizer package are needed.
enum GigaAMError: Error {
    case invalidConfiguration(String)
    case missingWeight(String)
    case invalidAudio
}

struct GigaAMConfiguration {
    let sampleRate: Int
    let features: Int
    let winLength: Int
    let hopLength: Int
    let nFFT: Int
    let center: Bool
    let layers: Int
    let dModel: Int
    let heads: Int
    let subsamplingKernel: Int
    let subsamplingFactor: Int
    let ropeBase: Double
    let convKernel: Int
    let convNorm: String
    let headType: String
    let predHidden: Int
    let jointHidden: Int
    let vocabulary: [String]
    let sentencePiece: Bool
    let controlTokens: Set<Int>
    var blank: Int { vocabulary.count }
    var classes: Int { vocabulary.count + 1 }

    static func load(_ directory: URL) throws -> Self {
        let url = directory.appendingPathComponent("config.json")
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) < 4_000_000,
              let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw GigaAMError.invalidConfiguration("config")
        }
        let pre = root["preprocessor"] as? [String: Any] ?? [:]
        let enc = root["encoder"] as? [String: Any] ?? [:]
        let head = root["head"] as? [String: Any] ?? [:]
        func int(_ object: [String: Any], _ key: String, _ fallback: Int) -> Int { (object[key] as? NSNumber)?.intValue ?? fallback }
        let headType = root["head_type"] as? String ?? "ctc"
        let decoder = head["decoder"] as? [String: Any] ?? [:]
        let joint = head["joint"] as? [String: Any] ?? [:]
        guard let vocabulary = root["vocabulary"] as? [String], !vocabulary.isEmpty, vocabulary.count < 100_000 else {
            throw GigaAMError.invalidConfiguration("vocabulary")
        }
        let configuration = Self(
            sampleRate: int(root, "sample_rate", 16000), features: int(pre, "features", 64),
            winLength: int(pre, "win_length", 320), hopLength: int(pre, "hop_length", 160), nFFT: int(pre, "n_fft", 320),
            center: pre["center"] as? Bool ?? false,
            layers: int(enc, "n_layers", 16), dModel: int(enc, "d_model", 768), heads: int(enc, "n_heads", 16),
            subsamplingKernel: int(enc, "subs_kernel_size", 5), subsamplingFactor: int(enc, "subsampling_factor", 4),
            ropeBase: Double(int(enc, "pos_emb_max_len", 5000)), convKernel: int(enc, "conv_kernel_size", 5),
            convNorm: enc["conv_norm_type"] as? String ?? "layer_norm", headType: headType,
            predHidden: int(decoder, "pred_hidden", 320), jointHidden: int(joint, "joint_hidden", 320),
            vocabulary: vocabulary, sentencePiece: root["tokenizer_type"] as? String == "sentencepiece",
            controlTokens: Set((root["tokenizer_control_token_ids"] as? [NSNumber] ?? []).map(\.intValue)))
        guard configuration.sampleRate == 16000, configuration.features > 0, configuration.hopLength > 0,
              configuration.winLength > 0, configuration.nFFT >= configuration.winLength,
              configuration.dModel > 0, configuration.heads > 0, configuration.dModel % configuration.heads == 0,
              (configuration.dModel / configuration.heads) % 2 == 0, (1...64).contains(configuration.layers),
              configuration.subsamplingFactor > 1, configuration.subsamplingFactor & (configuration.subsamplingFactor - 1) == 0,
              configuration.convKernel % 2 == 1, configuration.subsamplingKernel % 2 == 1,
              enc["subsampling"] as? String ?? "conv1d" == "conv1d",
              enc["self_attention_model"] as? String ?? "rotary" == "rotary",
              ["layer_norm", "batch_norm"].contains(configuration.convNorm),
              ["ctc", "rnnt"].contains(headType) else {
            throw GigaAMError.invalidConfiguration("architecture")
        }
        if headType == "rnnt" {
            guard int(decoder, "pred_rnn_layers", 1) == 1, int(decoder, "num_classes", configuration.classes) == configuration.classes,
                  int(joint, "num_classes", configuration.classes) == configuration.classes else {
                throw GigaAMError.invalidConfiguration("rnnt")
            }
        } else if let classes = (head["num_classes"] as? NSNumber)?.intValue, classes != configuration.classes {
            throw GigaAMError.invalidConfiguration("ctc")
        }
        return configuration
    }
}

struct GigaAMWord: Equatable {
    let text: String
    let start: Double
    let end: Double
}

final class GigaAMModel {
    let configuration: GigaAMConfiguration
    private let weights: [String: MLXArray]
    private let melFilterbank: MLXArray
    private let window: [Float]
    private let rnnt: RNNTDecoder?

    init(directory: URL) throws {
        let c = try GigaAMConfiguration.load(directory)
        let url = directory.appendingPathComponent("model.safetensors")
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw GigaAMError.missingWeight("model.safetensors") }
        var loaded = try loadArrays(url: url)
        guard let filterbank = loaded.removeValue(forKey: "mel_filterbank") else { throw GigaAMError.missingWeight("mel_filterbank") }
        guard filterbank.ndim == 2, filterbank.dim(0) == c.nFFT / 2 + 1, filterbank.dim(1) == c.features else {
            throw GigaAMError.invalidConfiguration("mel_filterbank")
        }
        let analysisWindow: [Float]
        if let stored = loaded.removeValue(forKey: "stft_window") {
            guard stored.ndim == 1, stored.dim(0) == c.winLength else { throw GigaAMError.invalidConfiguration("stft_window") }
            analysisWindow = stored.asType(.float32).asArray(Float.self)
        } else {
            // torch.hann_window(periodic=True), the torchaudio default.
            analysisWindow = (0..<c.winLength).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(c.winLength)) }
        }
        // Activations stay float32 like the upstream CPU path; upcast once.
        var converted: [String: MLXArray] = [:]
        for (key, value) in loaded { converted[key] = value.asType(.float32) }
        configuration = c
        melFilterbank = filterbank.asType(.float32)
        window = analysisWindow
        weights = converted
        if c.headType == "rnnt" { rnnt = try RNNTDecoder(weights: converted, configuration: c) } else { rnnt = nil }
        try validateEncoderWeights()
        eval(Array(weights.values) + [melFilterbank])
    }

    private func weight(_ key: String) throws -> MLXArray {
        guard let value = weights[key] else { throw GigaAMError.missingWeight(key) }
        return value
    }

    private func validateEncoderWeights() throws {
        let c = configuration
        let first = try weight("encoder.pre_encode.conv.0.weight")
        guard first.shape == [c.dModel, c.subsamplingKernel, c.features] else { throw GigaAMError.invalidConfiguration("pre_encode") }
        for layer in 0..<c.layers {
            let prefix = "encoder.layers.\(layer)."
            for name in ["norm_feed_forward1", "norm_self_att", "norm_conv", "norm_feed_forward2", "norm_out",
                         "feed_forward1.linear1", "feed_forward1.linear2", "feed_forward2.linear1", "feed_forward2.linear2",
                         "self_attn.linear_q", "self_attn.linear_k", "self_attn.linear_v", "self_attn.linear_out",
                         "conv.pointwise_conv1", "conv.depthwise_conv", "conv.pointwise_conv2", "conv.batch_norm"] {
                _ = try weight(prefix + name + ".weight")
            }
        }
        let depthwise = try weight("encoder.layers.0.conv.depthwise_conv.weight")
        guard depthwise.shape == [c.dModel, c.convKernel, 1] else { throw GigaAMError.invalidConfiguration("depthwise") }
        if c.headType == "ctc" {
            guard try weight("head.decoder_layers.0.weight").shape == [c.classes, 1, c.dModel] else { throw GigaAMError.invalidConfiguration("ctc_head") }
        }
    }

    // MARK: Features

    /// Log-mel spectrogram matching torchaudio MelSpectrogram(power: 2) + log(clamp(1e-9, 1e9)).
    func features(_ samples: [Float]) throws -> MLXArray {
        let c = configuration
        var signal = samples
        if c.center {
            let pad = c.nFFT / 2
            guard signal.count > pad else { throw GigaAMError.invalidAudio }
            let left = (1...pad).map { signal[$0] }.reversed()
            let right = (1...pad).map { signal[signal.count - 1 - $0] }
            signal = Array(left) + signal + right
        }
        guard signal.count >= c.winLength else { throw GigaAMError.invalidAudio }
        let frames = 1 + (signal.count - c.winLength) / c.hopLength
        var framed = [Float](repeating: 0, count: frames * c.nFFT)
        let offset = (c.nFFT - c.winLength) / 2 // torch centers a shorter window inside n_fft
        signal.withUnsafeBufferPointer { source in
            framed.withUnsafeMutableBufferPointer { target in
                for frame in 0..<frames {
                    let base = frame * c.hopLength
                    for index in 0..<c.winLength {
                        target[frame * c.nFFT + offset + index] = source[base + index] * window[index]
                    }
                }
            }
        }
        let spectrum = rfft(MLXArray(framed, [frames, c.nFFT]), n: c.nFFT, axis: -1, stream: .cpu)
        let power = square(abs(spectrum, stream: .cpu), stream: .cpu)
        let mel = matmul(power, melFilterbank)
        return log(clip(mel, min: Float(1e-9), max: Float(1e9))).expandedDimensions(axis: 0)
    }

    // MARK: Encoder

    private func linear(_ x: MLXArray, _ prefix: String, bias: Bool = true) throws -> MLXArray {
        let y = matmul(x, try weight(prefix + ".weight").transposed())
        return bias ? y + (try weight(prefix + ".bias")) : y
    }

    private func conv(_ x: MLXArray, _ prefix: String, stride: Int = 1, padding: Int = 0, groups: Int = 1) throws -> MLXArray {
        conv1d(x, try weight(prefix + ".weight"), stride: stride, padding: padding, groups: groups) + (try weight(prefix + ".bias"))
    }

    private func norm(_ x: MLXArray, _ prefix: String) throws -> MLXArray {
        layerNorm(x, weight: try weight(prefix + ".weight"), bias: try weight(prefix + ".bias"), eps: 1e-5)
    }

    private static func silu(_ x: MLXArray) -> MLXArray { x * sigmoid(x) }

    private static func rotateHalf(_ x: MLXArray) -> MLXArray {
        let parts = split(x, parts: 2, axis: -1)
        return concatenated([-parts[1], parts[0]], axis: -1)
    }

    /// Returns encoder output `[T, d_model]`.
    func encode(_ features: MLXArray) throws -> MLXArray {
        let c = configuration
        var x = features
        let stages = Int(log2(Double(c.subsamplingFactor)))
        let padding = (c.subsamplingKernel - 1) / 2
        for stage in 0..<stages {
            x = maximum(try conv(x, "encoder.pre_encode.conv.\(stage * 2)", stride: 2, padding: padding), Float(0))
        }
        let time = x.dim(1), headDim = c.dModel / c.heads
        let inverse = MLXArray(stride(from: 0, to: headDim, by: 2).map { Float(1 / pow(c.ropeBase, Double($0) / Double(headDim))) })
        let positions = MLXArray((0..<time).map { Float($0) })
        let frequencies = matmul(positions.reshaped([time, 1]), inverse.reshaped([1, headDim / 2]))
        let angles = concatenated([frequencies, frequencies], axis: -1).reshaped([1, time, 1, headDim])
        let cosine = cos(angles), sine = sin(angles)
        let scale = Float(1 / sqrt(Double(headDim)))
        for layer in 0..<c.layers {
            let p = "encoder.layers.\(layer)."
            var residual = x
            var h = try linear(Self.silu(try linear(try norm(residual, p + "norm_feed_forward1"), p + "feed_forward1.linear1")), p + "feed_forward1.linear2")
            residual = residual + h * Float(0.5)

            h = try norm(residual, p + "norm_self_att")
            let heads = h.reshaped([1, time, c.heads, headDim])
            let rotated = (heads * cosine + Self.rotateHalf(heads) * sine).reshaped([1, time, c.dModel])
            let q = try linear(rotated, p + "self_attn.linear_q").reshaped([1, time, c.heads, headDim]).transposed(0, 2, 1, 3)
            let k = try linear(rotated, p + "self_attn.linear_k").reshaped([1, time, c.heads, headDim]).transposed(0, 2, 1, 3)
            let v = try linear(h, p + "self_attn.linear_v").reshaped([1, time, c.heads, headDim]).transposed(0, 2, 1, 3)
            let attention = softmax(matmul(q * scale, k.transposed(0, 1, 3, 2)), axis: -1, precise: true)
            h = matmul(attention, v).transposed(0, 2, 1, 3).reshaped([1, time, c.dModel])
            residual = residual + (try linear(h, p + "self_attn.linear_out"))

            h = try norm(residual, p + "norm_conv")
            h = try conv(h, p + "conv.pointwise_conv1")
            let gates = split(h, parts: 2, axis: -1)
            h = gates[0] * sigmoid(gates[1])
            h = try conv(h, p + "conv.depthwise_conv", padding: (c.convKernel - 1) / 2, groups: c.dModel)
            if c.convNorm == "layer_norm" {
                h = try norm(h, p + "conv.batch_norm")
            } else {
                let mean = try weight(p + "conv.batch_norm.running_mean"), variance = try weight(p + "conv.batch_norm.running_var")
                h = (h - mean) * rsqrt(variance + Float(1e-5)) * (try weight(p + "conv.batch_norm.weight")) + (try weight(p + "conv.batch_norm.bias"))
            }
            h = try conv(Self.silu(h), p + "conv.pointwise_conv2")
            residual = residual + h

            h = try linear(Self.silu(try linear(try norm(residual, p + "norm_feed_forward2"), p + "feed_forward2.linear1")), p + "feed_forward2.linear2")
            residual = residual + h * Float(0.5)
            x = try norm(residual, p + "norm_out")
            // Bound the lazy graph: one evaluated layer at a time.
            eval(x)
        }
        return x[0]
    }

    // MARK: Decoding

    /// Greedy decoding to `(token, frame)` pairs.
    func decode(_ encoded: MLXArray) throws -> [(Int, Int)] {
        if let rnnt {
            let projected = (try linear(encoded, "head.joint.enc")).asType(.float32)
            eval(projected)
            return try rnnt.greedy(projectedEncoder: projected.asArray(Float.self), frames: encoded.dim(0))
        }
        let logits = matmul(encoded, try weight("head.decoder_layers.0.weight").squeezed(axis: 1).transposed()) + (try weight("head.decoder_layers.0.bias"))
        let labels = argMax(logits, axis: -1).asArray(Int32.self).map { Int($0) }
        var result: [(Int, Int)] = []
        var previous = -1
        for (frame, label) in labels.enumerated() {
            if label != configuration.blank && label != previous { result.append((label, frame)) }
            previous = label
        }
        return result
    }

    /// Word timestamps follow upstream `frames_to_words`: a SentencePiece `▁` (or a
    /// char-wise space) starts a word; start = first frame, end = last frame + 1.
    static func words(tokens: [(Int, Int)], vocabulary: [String], sentencePiece: Bool, controlTokens: Set<Int>, frameSeconds: Double) -> [GigaAMWord] {
        var words: [GigaAMWord] = []
        var bytes: [UInt8] = [], first = -1, last = -1
        func commit() {
            defer { bytes.removeAll(); first = -1; last = -1 }
            let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, first >= 0 else { return }
            words.append(GigaAMWord(text: " " + text, start: Double(first) * frameSeconds, end: Double(last + 1) * frameSeconds))
        }
        for (token, frame) in tokens {
            guard token >= 0, token < vocabulary.count, !controlTokens.contains(token) else { continue }
            var piece = vocabulary[token]
            if !sentencePiece {
                if piece == " " { commit(); continue }
            } else if piece == "<unk>" {
                piece = "\u{2047}"
            } else if piece.count == 6, piece.hasPrefix("<0x"), piece.hasSuffix(">"), let byte = UInt8(piece.dropFirst(3).prefix(2), radix: 16) {
                if first < 0 { first = frame }
                bytes.append(byte); last = frame
                continue
            }
            if piece.hasPrefix("\u{2581}") {
                commit()
                piece.removeFirst()
            }
            piece = piece.replacingOccurrences(of: "\u{2581}", with: " ")
            if first < 0 { first = frame }
            bytes.append(contentsOf: Array(piece.utf8)); last = frame
        }
        commit()
        return words
    }

    /// One bounded window of 16 kHz mono PCM to timed words (window-relative seconds).
    func transcribe(_ samples: [Float]) throws -> [GigaAMWord] {
        let encoded = try encode(try self.features(samples))
        let frames = encoded.dim(0)
        guard frames > 0 else { return [] }
        let tokens = try decode(encoded)
        let duration = Double(samples.count) / Double(configuration.sampleRate)
        let c = configuration
        return Self.words(tokens: tokens, vocabulary: c.vocabulary, sentencePiece: c.sentencePiece, controlTokens: c.controlTokens,
                          frameSeconds: duration / Double(frames)).map {
            GigaAMWord(text: $0.text, start: min($0.start, duration), end: min(max($0.end, $0.start), duration))
        }
    }
}

/// Single-layer LSTM prediction network and joint, run on the CPU with Accelerate.
/// Each step is a few small mat-vecs, cheaper than a GPU round trip per frame.
private final class RNNTDecoder {
    private let hidden: Int
    private let jointHidden: Int
    private let classes: Int
    private let blank: Int
    private let embedding: [Float]
    private let inputWeights: [Float]
    private let hiddenWeights: [Float]
    private let lstmBias: [Float]
    private let predictionWeights: [Float]
    private let predictionBias: [Float]
    private let outputWeights: [Float]
    private let outputBias: [Float]
    private let maximumSymbols = 10
    private let zeroGates: [Float]

    init(weights: [String: MLXArray], configuration c: GigaAMConfiguration) throws {
        func values(_ key: String, _ shape: [Int]) throws -> [Float] {
            guard let value = weights[key] else { throw GigaAMError.missingWeight(key) }
            guard value.shape == shape else { throw GigaAMError.invalidConfiguration(key) }
            return value.asType(.float32).asArray(Float.self)
        }
        hidden = c.predHidden; jointHidden = c.jointHidden; classes = c.classes; blank = c.blank
        zeroGates = [Float](repeating: 0, count: 4 * c.predHidden)
        embedding = try values("head.decoder.embed.weight", [c.classes, c.predHidden])
        inputWeights = try values("head.decoder.lstm.Wx", [4 * c.predHidden, c.predHidden])
        hiddenWeights = try values("head.decoder.lstm.Wh", [4 * c.predHidden, c.predHidden])
        lstmBias = try values("head.decoder.lstm.bias", [4 * c.predHidden])
        predictionWeights = try values("head.joint.pred.weight", [c.jointHidden, c.predHidden])
        predictionBias = try values("head.joint.pred.bias", [c.jointHidden])
        outputWeights = try values("head.joint.joint_net_linear.weight", [c.classes, c.jointHidden])
        outputBias = try values("head.joint.joint_net_linear.bias", [c.classes])
        guard try values("head.joint.enc.weight", [c.jointHidden, c.dModel]).count == c.jointHidden * c.dModel else {
            throw GigaAMError.invalidConfiguration("joint")
        }
    }

    /// y = W x + b, W row-major [rows, columns].
    private func affine(_ w: [Float], _ x: [Float], _ b: [Float], rows: Int, columns: Int) -> [Float] {
        var y = [Float](repeating: 0, count: rows)
        vDSP_mmul(w, 1, x, 1, &y, 1, vDSP_Length(rows), 1, vDSP_Length(columns))
        return vDSP.add(y, b)
    }

    private static func sigmoid(_ x: Float) -> Float { 1 / (1 + exp(-x)) }

    /// PyTorch gate order i, f, g, o. A nil label is the zero "start" input.
    private func step(_ label: Int?, _ state: (h: [Float], c: [Float])) -> (output: [Float], state: (h: [Float], c: [Float])) {
        let input = label.map { Array(embedding[($0 * hidden)..<(($0 + 1) * hidden)]) } ?? [Float](repeating: 0, count: hidden)
        let gates = vDSP.add(affine(inputWeights, input, lstmBias, rows: 4 * hidden, columns: hidden),
                             affine(hiddenWeights, state.h, zeroGates, rows: 4 * hidden, columns: hidden))
        var h = [Float](repeating: 0, count: hidden), c = [Float](repeating: 0, count: hidden)
        for j in 0..<hidden {
            let i = Self.sigmoid(gates[j]), f = Self.sigmoid(gates[hidden + j])
            let g = tanh(gates[2 * hidden + j]), o = Self.sigmoid(gates[3 * hidden + j])
            c[j] = f * state.c[j] + i * g
            h[j] = o * tanh(c[j])
        }
        return (h, (h, c))
    }

    /// Upstream RNNTGreedyDecoding: at most ten symbols per frame; the prediction
    /// state advances only on a non-blank symbol.
    func greedy(projectedEncoder: [Float], frames: Int) throws -> [(Int, Int)] {
        guard projectedEncoder.count == frames * jointHidden else { throw GigaAMError.invalidConfiguration("encoder") }
        let zero = [Float](repeating: 0, count: hidden)
        var state = (h: zero, c: zero)
        var label: Int? = nil
        var prediction = step(nil, state)
        var predicted = affine(predictionWeights, prediction.output, predictionBias, rows: jointHidden, columns: hidden)
        var result: [(Int, Int)] = []
        var joint = [Float](repeating: 0, count: jointHidden)
        var logits = [Float](repeating: 0, count: classes)
        for t in 0..<frames {
            if t % 256 == 0 { try Task.checkCancellation() }
            for _ in 0..<maximumSymbols {
                projectedEncoder.withUnsafeBufferPointer { encoder in
                    for j in 0..<jointHidden { joint[j] = max(0, encoder[t * jointHidden + j] + predicted[j]) }
                }
                logits = affine(outputWeights, joint, outputBias, rows: classes, columns: jointHidden)
                var best: Float = 0; var index: vDSP_Length = 0
                vDSP_maxvi(logits, 1, &best, &index, vDSP_Length(classes))
                let symbol = Int(index)
                if symbol == blank { break }
                result.append((symbol, t))
                state = prediction.state
                label = symbol
                prediction = step(label, state)
                predicted = affine(predictionWeights, prediction.output, predictionBias, rows: jointHidden, columns: hidden)
            }
        }
        return result
    }
}
