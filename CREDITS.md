# Credits

Web builds on work from these projects and their contributors.

| Project | Used for | License |
| --- | --- | --- |
| [MLX](https://github.com/ml-explore/mlx) and [MLX Swift](https://github.com/ml-explore/mlx-swift) | Local inference on Apple Silicon | MIT |
| [MLX Swift Examples](https://github.com/ml-explore/mlx-swift-examples) | The pinned `MLXLLM` and `MLXLMCommon` libraries | MIT |
| [Hugging Face Swift Transformers](https://github.com/huggingface/swift-transformers) | Model downloads and tokenization through MLX | Apache 2.0 |
| [Jinja](https://github.com/johnmai-dev/Jinja) | Chat templates through Swift Transformers | MIT |
| [Swift Numerics](https://github.com/apple/swift-numerics) and [Swift Collections](https://github.com/apple/swift-collections) | Math and ordered collections used by those libraries | Apache 2.0 with Swift runtime exception |

Apple's SwiftUI, AppKit and WebKit provide the native interface and browser engine. Exact package revisions are in [Package.resolved](Web.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved). Bundled components and their license texts are in [ThirdPartyNotices.txt](Web/Resources/ThirdPartyNotices.txt).

Models download separately. The default [Gemma 3 model](https://huggingface.co/mlx-community/gemma-3-1b-it-qat-4bit) comes from Google and the MLX community; its model card links the applicable terms.

## Design references

Thanks to [@Jakubantalik](https://github.com/Jakubantalik) for [Libraries.dev](https://libraries.dev/) and [Transitions.dev](https://transitions.dev/). Border Beam and Thinking Orbs informed Web's new-tab light and assistant globe. The transition examples helped with state changes. Web implements these effects with original SwiftUI drawing; it does not bundle code or assets from either project.

[Browser references](docs/browser-references.md) records the other interaction research. These acknowledgments describe dependencies and inspiration, not affiliation or endorsement.
