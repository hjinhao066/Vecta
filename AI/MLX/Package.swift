// swift-tools-version: 6.2
import PackageDescription
let package = Package(name:"VectaMLX",platforms:[.macOS(.v15)],products:[.executable(name:"VectaMLX",targets:["VectaMLX"]),.executable(name:"VectaSummaryBench",targets:["VectaSummaryBench"])],dependencies:[
    .package(url:"https://github.com/ml-explore/mlx-swift-lm",revision:"7eb77efa4e8fb56183b905904d122e66ebdb422e"),
    .package(url:"https://github.com/huggingface/swift-huggingface",from:"0.9.0"),
    .package(url:"https://github.com/huggingface/swift-transformers",from:"1.3.0")
],targets:[.executableTarget(name:"VectaMLX",dependencies:[.product(name:"MLXLLM",package:"mlx-swift-lm"),.product(name:"MLXLMCommon",package:"mlx-swift-lm"),.product(name:"MLXHuggingFace",package:"mlx-swift-lm"),.product(name:"HuggingFace",package:"swift-huggingface"),.product(name:"Tokenizers",package:"swift-transformers")]),.executableTarget(name:"VectaSummaryBench",dependencies:[.product(name:"MLXLLM",package:"mlx-swift-lm"),.product(name:"MLXLMCommon",package:"mlx-swift-lm"),.product(name:"MLXHuggingFace",package:"mlx-swift-lm"),.product(name:"HuggingFace",package:"swift-huggingface"),.product(name:"Tokenizers",package:"swift-transformers")]),.testTarget(name:"VectaMLXTests",dependencies:["VectaMLX"])],swiftLanguageModes:[.v5])
