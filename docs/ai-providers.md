# AI providers

Web supports local MLX inference, OpenAI, Anthropic, Google, and a custom OpenAI-compatible API. The local provider remains the default. Saving a key does not switch providers or generate a paid test completion. Select the provider explicitly in Settings.

## Model catalog

The catalog was checked against official documentation on September 13, 2026. These are documented API identifiers; availability still depends on the account. Selection persists per provider. Web never silently substitutes a different model after an error.

| Provider | Default | Other choices |
| --- | --- | --- |
| OpenAI | `gpt-5.6-luna` | `gpt-5.6-terra`, `gpt-5.6-sol`, `gpt-6-astra` |
| Anthropic | `claude-sonnet-5` | `claude-haiku-4-5-20251001`, `claude-opus-5`, `claude-fable-5-1` |
| Google | `gemini-3.8-flash` | `gemini-3.5-flash-lite` |

Sources: [OpenAI models](https://developers.openai.com/api/docs/models), [Claude models](https://platform.claude.com/docs/en/models/overview), [Gemini models](https://ai.google.dev/gemini-api/docs/models).

The OpenAI adapter uses text-only Chat Completions with low reasoning, a bounded completion budget, no sampling overrides, and `store: false`. GPT-6 supports that endpoint for text; its tool calling requires Responses. This release exposes no model tools. See the [OpenAI migration guide](https://developers.openai.com/api/docs/guides/latest-model#update-api-and-model-parameters).

Cloud catalog refresh is a maintained source update. It does not infer capabilities or prices from model names. Local MLX model discovery remains available for downloaded models. The default is `mlx-community/gemma-3-1b-it-qat-4bit`, a 733 MB text model present in the pinned MLXLLM registry. Its visible name, download and inference route use the same identity. See the [model card](https://huggingface.co/mlx-community/gemma-3-1b-it-qat-4bit), [Google's Gemma 3 specifications](https://ai.google.dev/gemma/docs/core/model_card_3), and the [pinned MLX registry](https://github.com/ml-explore/mlx-swift-examples/blob/6a5d1dfa29f27f67f1fd59c9b78d2eac069c9abf/Libraries/MLXLLM/LLMModelFactory.swift). The current app build requires Apple Silicon.

## Custom API

In Settings → AI, choose **Connect** beside **Custom API**. Enter the API base URL, including its version path, and the exact model ID. Web adds `/chat/completions`. Remote servers require HTTPS and an API key. A loopback server can use HTTP and omit the key.

Saving a connection makes no network request. Choose **Use** to select it. The configured endpoint appears beside page-sharing controls. Sharing starts off, including for a loopback server, and private pages remain excluded. Changing the connection cancels its requests and resets consent.

Keys belong to the normalized endpoint, including its port and base path. They never fall back to an OpenAI key or another server's key. Redirects are rejected. Requests and responses have size limits. This adapter supports text Chat Completions and streaming; it does not discover models, estimate prices or expose tools. Server compatibility still needs testing beyond the local transport checks.

## Assistant

Opening the assistant loads the selected model. Local download progress comes from the MLX loader; failures remain visible with a retry. Closing the panel keeps the conversation in its browser window. Stop cancels each streaming wrapper down to the MLX token loop and preserves any partial reply. Concurrent local initialization shares one awaited model load. The pinned runtime applies the chat template; Web supplies plain instructions and quoted source data. The model menu uses the provider's available models; provider and key changes live in Settings. Browsing history is excluded from sidebar requests.

## Page privacy

Page sharing starts off for every cloud provider, including existing installations. Enabling **Share page** authorizes sending page text with questions and summaries to that provider. Private tabs are excluded. Disabling sharing clears the conversation because earlier replies may quote page text. Changing providers also clears the conversation. Requests capture their provider before page extraction and are invalidated if provider selection or page consent changes while extraction is in flight.

Your typed question is sent to the selected cloud provider even when page sharing is off. Provider policies still apply. `store: false` is an API request setting, not a promise of zero provider retention.

Page text is read on request in an isolated WebKit content world. Extraction excludes forms, editable drafts and hidden content. It does not scroll the page, install observers or retain a URL-based page cache. Text is bounded to 24,000 characters and sent as quoted user data, separate from the system instruction. This reduces prompt-injection exposure; it does not guarantee that models will ignore every malicious page. Page automation is withheld in this release. Agent entrypoints, navigation, clicks, typing, selection, and automatic cookie acceptance are blocked. Restoring automation requires action-specific review, page-state binding, sensitive-field exclusions, and adversarial tests.

Keys remain in the macOS Keychain. Replacing a key uses an update instead of deleting the previous key first. API requests use ephemeral networking without browser cookies or caches, reject redirects, and put credentials in headers. Failed requests do not log response bodies. Named-provider credential checks use model-list endpoints and generate no completions. Custom API validates its configuration locally.

## Subscriptions

A chat subscription is not an API key. Web currently supports provider API billing only.

OpenAI documents a local [Codex App Server](https://learn.chatgpt.com/docs/app-server) for custom clients, including its own authentication flow and streamed turns. A future optional Codex integration should use that public protocol and let Codex own sign-in, approvals, and account state. It is not implemented here, and Web never reads Codex token files.

Anthropic's [credential-use rules](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use) distinguish native subscription use from third-party products. Web uses Claude Console API keys; it does not offer Claude.ai login or route browser requests through subscription credentials. No CLI credential scraping or subscription proxy is included.

## Costs and validation

Prices shown for OpenAI and Anthropic are dated estimates from their official catalogs. Gemini prices are left unknown rather than filled with placeholders. Provider invoices are authoritative. OpenAI streaming captures provider-reported usage; Claude and Gemini streaming currently retain only approximate output token counts, with cost unknown. Local spending reminders can miss charges, interrupted requests, and concurrent requests. Set hard limits with the provider.

Automated tests cover consent, private-page exclusion, provider isolation, prompt boundaries, local chat templating, streaming cancellation, generation errors and request parameters. Local MLX text generation is verified in a locally signed build without `allow-jit`; response quality remains under review. Wider streaming and Stop checks remain necessary. Cloud completions and billing reconciliation remain unverified. No credentials were copied or printed. See [release validation](validation.md).
