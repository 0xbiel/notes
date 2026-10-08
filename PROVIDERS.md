# Provider integration and UI handoff

This work prepares native text transports, not T3 Code's interface. No T3 top bar, navigation, or preferences components are imported. Provider controls are deliberately left to the separate UI worker.

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
- Codex and Antigravity require explicit `accountSendingAllowed` consent before enqueue/send. The UI must disclose external text processing and account pricing/retention terms before setting this flag; never label either route universally free or ZDR. Do not expose account routes through the current OpenRouter-only labels until the UI worker updates those disclosures.
- Each queued batch persists its configuration and model. Later settings changes cannot redirect it; old batches without a configuration still use the OpenCode route. Review/apply/undo remains unchanged.
- Default discovery locates existing T3-managed binaries and a single existing Antigravity profile if unambiguous. This is convenience discovery, not a promise that the discovered version works. No runtime is installed and no token is read or copied.

## Transport boundaries

OpenCode accepts the specifically verified CLI versions 1.3.13 and 1.18.35 and checks its effective model, permissions, MCP, plugins, auxiliary agents, and privacy/price policy before sending. Real-note requests require no training, ZDR, and zero prices; only the exact invented demo permits retention. No policy is relaxed to make a request pass.

Codex uses ephemeral JSON execution in a private empty directory, disables ambient configuration/rules, project instructions, bundled skill instructions, web search, MCP and tool features, and supplies the existing note-proposal response schema. Unexpected tool items, provider errors, or incomplete responses are rejected.

Antigravity uses native ACP, not the desktop GUI executable. It checks global hooks/MCP, disables client filesystem/terminal capabilities, denies server tool/permission requests, and requires an end-turn text result matching the batch schema. Helper cancellation and a 90-second timeout terminate the isolated process group when available, with forced termination fallback. ACP exit synchronization avoids Foundation's cross-thread `waitUntilExit` hang.

Selected spans plus bounded note context are sent; audio and full local note snapshots are not. Proposals never write notes automatically. Account results have unknown cost (`reportedCost == nil`), not an invented zero price.

## zen-ui integration status

`zen-ui` and this worktree still share committed base `5dcd757`; the UI worker's latest changes remain uncommitted, so there is no new branch commit to merge. Following the user's merge-isolation request, all earlier imported UI files and shared README edits were removed from this branch's patch. Existing UI source and UI-worker tests remain at the committed base. The only changed existing file under `Sources/Notes` is the nonvisual `AIController.swift`, which the UI worker has not changed.

The latest preferences, custom theme picker, resources, layout, build script and UI tests were captured read-only in ignored `qa/latest-zen-ui-snapshot/`, with source hashes. A separate ignored `qa/latest-ui-provider-merge-check/` directory combines that snapshot with the provider/backend changes for compile and test verification. This is compatibility testing, not a merge or a write to the UI worker's checkout. Later concurrent UI edits require a fresh snapshot/check.

## Verification boundaries

Installed-runtime diagnostics pass for OpenCode 1.18.35, Codex CLI 0.156.1, and Antigravity ACP `agy_acp_server_1.1.1`. Mock ACP and Codex-event tests verify protocol/response handling, rejected tools, cancellation and note preservation. Controller tests verify settings reload, consent before enqueue, and saved-batch isolation.

The OpenCode 1.18.35 live invented canaries reached sending but failed with incomplete output and a 90-second timeout. Successful live generation on this version is not established. No live Codex or Antigravity account prompt was sent. See `TESTING.md` and `TEST_RESULTS.md` for transcription and notebook coverage.
