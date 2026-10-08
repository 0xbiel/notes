# Provider integration and UI handoff

Notes includes native provider setup, provider logos, live model catalogs, favorites, visibility controls, and reasoning selection within its existing preferences layout. The Notes sidebar, top bar, themes, and navigation retain their own styling.

## Reference reviewed

Read-only T3 Code source checkout: `pingdotgg/t3code`, commit `d6f47ff9725f0902b526f854519cb7e92dcee52f` on October 8, 2026. Relevant source:

- `apps/server/src/textGeneration/CodexTextGeneration.ts`: disposable read-only `codex exec`, structured output.
- `apps/server/src/textGeneration/OpenCodeTextGeneration.ts`: isolated session, deny-all permissions, failure/empty-output handling.
- `apps/server/src/textGeneration/AntigravityTextGeneration.ts`: disposable directory, global-hook/MCP checks, denied filesystem/terminal/permission requests, text-only completion.
- `apps/server/src/provider/antigravityAuthSupport.ts`: native ACP executable, profile and harness environment, existing personal-account authentication.
- `packages/effect-acp/test/fixtures/antigravity-initialize.json`: ACP version and agent identity.

Notes adapts these transport patterns to Swift; it does not import T3's SDK, UI, account configuration, or credentials. OpenCode retains Notes' existing CLI adapter and free-router policy rather than adopting T3's SDK transport.

## Settings contract for the UI worker

- `AIProviderSettings` holds `selectedProvider` and separate `openCode`, `codexCLI`, and `antigravity` configurations. `selected` reads or updates the selected configuration.
- Configuration fields: `executablePath`, `model`, `homePath`, `harnessPath`, `accountSendingAllowed`. Paths are absolute, and models are identifiers, not shell arguments. `default` leaves the account provider's model selection to its runtime.
- `AIController.providerSettings` exposes the local settings. Save through `saveProviderSettings(_:)`, which validates and refuses changes during a running request. Persistence is workspace-local `session-storage/ai-provider-settings.json` with no credential fields.
- `NotesProviderTransport.diagnose(_:)` is asynchronous and read-only: effective-config verification for OpenCode, version/help for Codex, ACP initialize for Antigravity. It does not authenticate, send a prompt, install, or open a browser. A passing diagnostic does not prove login, quota, model availability, or generation.
- All providers default to enabled in new settings and can be disabled individually in Providers. Existing saved opt-outs are preserved. `accountSendingAllowed` gates every provider, including OpenCode; current settings are checked before queued sends. Account providers retain their own pricing and retention terms.
- Each queued batch persists its configuration and model. Later settings changes cannot redirect it; old batches without a configuration still use the OpenCode route. Review/apply/undo remains unchanged.
- Default discovery locates existing T3-managed binaries and a single existing Antigravity profile if unambiguous. This is convenience discovery, not a promise that the discovered version works. No runtime is installed and no token is read or copied.

## Transport boundaries

OpenCode accepts the specifically verified CLI versions 1.3.13 and 1.18.35 and checks its effective model, permissions, MCP, plugins, auxiliary agents, and privacy/price policy before sending. Real-note requests require no training, ZDR, and zero prices; only the exact invented demo permits retention. No policy is relaxed to make a request pass.

Codex uses ephemeral JSON execution in a private empty directory, disables ambient configuration/rules, project instructions, bundled skill instructions, web search, MCP and tool features, and supplies the existing note-proposal response schema. Unexpected tool items, provider errors, or incomplete responses are rejected.

Antigravity uses native ACP, not the desktop GUI executable. It checks global hooks/MCP, disables client filesystem/terminal capabilities, denies server tool/permission requests, and requires an end-turn text result matching the batch schema. Helper cancellation and a 90-second timeout terminate the isolated process group when available, with forced termination fallback. ACP exit synchronization avoids Foundation's cross-thread `waitUntilExit` hang.

Selected spans plus bounded note context are sent; audio and full local note snapshots are not. Proposals default to review before application. General preferences can authorize additions only or additions/corrections/retractions in the linked note. Unknown or legacy permissions remain review-only; each queued batch snapshots its permission and also obeys the current, potentially more restrictive permission. Uncertain proposals, ASR overlaps, dirty drafts and stale notes are not automatically applied. Automatic changes use the existing journal and undo history. Account results have unknown cost (`reportedCost == nil`), not an invented zero price.

## zen-ui integration status

The prepared UI and provider work are committed together through a merge of both branch histories. Provider preferences extend the prepared settings layout. Codex includes `gpt-6.1-sol` with the same reasoning levels as `gpt-6-sol`.

## Verification boundaries

Installed-runtime diagnostics pass for OpenCode 1.18.35, Codex CLI 0.156.1, and Antigravity ACP `agy_acp_server_1.1.1`. Mock ACP and Codex-event tests verify protocol/response handling, rejected tools, cancellation and note preservation. Controller tests verify settings reload, consent before enqueue, and saved-batch isolation.

The OpenCode 1.18.35 live invented canaries reached sending but failed with incomplete output and a 90-second timeout. Successful live generation on this version is not established. Historical account-generation results and current merge validation are distinguished in `TEST_RESULTS.md`. See `TESTING.md` and `TEST_RESULTS.md` for transcription and notebook coverage.

Codex fast mode is an optional persisted `fastMode` setting (missing values retain the previous behavior). Preferences exposes the toggle with a credit-usage disclosure. Enabled requests pass `service_tier="fast"` explicitly because ambient user configuration is ignored. Model reasoning effort remains a separate setting. Reference: https://developers.openai.com/codex/config-reference (`service_tier`).

General preferences includes a compact model popover based on the supplied visual reference: provider icon rail, searchable model names with provider subtitles, favorites across providers, and selected-row highlighting. Thinking levels come from the Codex catalog; fast mode is shown only for models advertising it through `serviceTiers` or `additionalSpeedTiers`. Switching models clears the previous model's reasoning and fast overrides. The Providers section remains available for installation details, provider enablement, custom models and catalog management. Valid settings changes save automatically; browsing a provider filter alone does not switch the active provider.

General's **Test connection** sends a fixed 46-byte connection prompt and requires only `{"ok":true}` through the draft provider/model/reasoning/speed configuration. It uses a disposable workspace without creating notes or an outbox. Codex uses minimal probe instructions and skips the separate version/help calls; tool rejection and completion validation remain enabled. It never reads user notes, applies proposals, persists sending consent or activates automatic sending. OpenRouter retains its existing synthetic privacy/zero-price checks. Results are tied to the tested configuration and disappear when it changes. Cancellation and provider errors are surfaced. Installation/catalog refresh remains a separate read-only check.

Thinking, speed, editing autonomy and language use the same compact titled popover with selected/hovered rows. The reasoning Default badge comes from the model catalog's `defaultReasoningEffort`, rather than a hardcoded assumption.

## Text notebook requests

`NotesProviderTransport.sendNotebook` uses the existing selected account and a separate `NotebookTextRequest` / `NotebookAssistantResponse` protocol. Read requests and BOE article queries are structured data processed by Notes; provider shell, filesystem, browser and MCP tools remain disabled. Only notebook-relative paths and selected text context are sent. The local controller enforces notebook ownership, loaded-file anchors, source markers, cancellation, and unchanged draft/disk snapshots before committing.

Codex receives the notebook JSON output schema. Antigravity uses its existing isolated text generation connection. OpenCode verifies a notebook-specific system prompt and 12,000-token output ceiling while retaining its existing privacy/zero-price policy. The transcription prompt, schema and output ceiling remain separate. Successful text edits produce one local checkpoint; provider errors never trigger account or model fallback.
