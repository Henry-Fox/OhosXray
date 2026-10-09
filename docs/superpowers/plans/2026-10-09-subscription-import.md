# Subscription Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users scan or paste an HTTP(S) subscription, preview its VMess/VLESS nodes, select rows, and import them while updating matching local nodes.

**Architecture:** Keep share-link parsing centralized in `LinkParser`, add a pure subscription decoder and a small HTTP fetch service, then hand parsed profiles to a dedicated selection page through transient in-memory state. Put deterministic matching in a pure batch-merge helper and let `ServerStore` perform a single final write.

**Tech Stack:** ArkTS, HarmonyOS ArkUI, `@kit.NetworkKit` HTTP, `@kit.ArkTS` Base64/text utilities, Preferences, Hypium, Hvigor.

**Spec:** `docs/subscription-import-design.md`

## Global Constraints

- Existing direct `vmess://` and `vless://` imports continue to work unchanged.
- Subscription responses may be plain text or standard/URL-safe Base64 with omitted padding.
- Only VMess and VLESS entries are importable; one malformed entry must not reject valid siblings.
- Fetch only after explicit user action, with finite timeouts and a conservative response-size limit.
- Never log or surface full subscription URLs, query strings, response bodies, UUIDs, or share links.
- Do not persist subscription URLs or add scheduled/background refresh.
- Preserve the unrelated working-tree change in `entry/oh-package-lock.json5`.

## Review Focus

- An HTTP 3xx response whose final URL is not HTTP(S) must fail without exposing either URL.
- A Base64-looking plain-text response must fall back to plain-text parsing when decoding yields no usable links.
- Duplicate links inside one subscription must appear/import once.
- Two nodes with the same name but different UUIDs must remain separate.
- Re-importing a renamed endpoint with the same protocol, UUID, and remark must update the existing record while retaining its local ID.

---

### Task 1: Pure subscription payload parser

**Files:**
- Create: `entry/src/main/ets/model/SubscriptionParser.ets`
- Modify: `entry/src/test/LocalUnit.test.ets`

**Interfaces:**
- Consumes: `parseShareLink(link: string): ServerProfile` from `LinkParser.ets`.
- Produces: `parseSubscriptionPayload(payload: string): SubscriptionParseResult`, where `SubscriptionParseResult` contains `profiles: ServerProfile[]`, `invalidCount: number`, and `duplicateCount: number`.

- [ ] **Step 1: Write failing parser tests**

Add Hypium cases for plain LF/CRLF text, standard Base64, URL-safe Base64 without padding, mixed valid and invalid lines, duplicate links, empty input, unsupported-only input, and Base64-looking plain text fallback. Assert profile fields and counts without logging raw input.

- [ ] **Step 2: Run the entry unit tests and confirm the new cases fail**

Run: DevEco/Hvigor entry unit-test task available in the installed SDK; if CLI test discovery is unavailable, run the tests from DevEco and record that limitation.

Expected: FAIL because `SubscriptionParser.ets` and its exports do not exist.

- [ ] **Step 3: Implement the parser**

Implement `parseSubscriptionPayload(payload: string): SubscriptionParseResult` plus private normalization, Base64-candidate decoding, supported-line extraction, and exact-link deduplication. Try decoded text first only when decoding succeeds; fall back to the original text when decoded text contains no supported links. Throw category-only errors for empty and unsupported-only payloads.

- [ ] **Step 4: Run the parser tests**

Expected: all Task 1 cases PASS.

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/model/SubscriptionParser.ets entry/src/test/LocalUnit.test.ets
git commit -m "feat: parse subscription payloads"
```

### Task 2: Subscription network service and redacted failures

**Files:**
- Create: `entry/src/main/ets/common/SubscriptionService.ets`
- Modify: `entry/src/test/LocalUnit.test.ets`

**Interfaces:**
- Consumes: `parseSubscriptionPayload(payload: string): SubscriptionParseResult`.
- Produces: `SubscriptionService.fetch(urlText: string): Promise<SubscriptionParseResult>` and pure `validateSubscriptionUrl(urlText: string): string`.

- [ ] **Step 1: Write failing URL and error-redaction tests**

Cover HTTP/HTTPS acceptance; rejection of missing schemes, credentials, and non-HTTP schemes; and category-only messages that do not contain query strings, UUID-like values, or the original URL. Pin the response limit to 2 MiB, connect timeout to 12 seconds, and read timeout to 30 seconds.

- [ ] **Step 2: Run tests and confirm failure**

Expected: FAIL because the service exports do not exist.

- [ ] **Step 3: Implement URL validation and HTTP fetching**

Use `http.createHttp()` with `ARRAY_BUFFER`, validate the initial and final response URL as HTTP(S), reject non-2xx status and payloads over 2 MiB, decode UTF-8, call the pure parser, and destroy the request in `finally`. Log only failure categories and response codes.

- [ ] **Step 4: Run tests and an invalid-URL manual check**

Expected: unit tests PASS; an invalid URL produces a safe Chinese error without echoing its secret parts.

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/common/SubscriptionService.ets entry/src/test/LocalUnit.test.ets
git commit -m "feat: fetch subscriptions safely"
```

### Task 3: Deterministic batch merge and one-write persistence

**Files:**
- Create: `entry/src/main/ets/model/ServerBatchMerge.ets`
- Modify: `entry/src/main/ets/common/ServerStore.ets`
- Modify: `entry/src/test/LocalUnit.test.ets`

**Interfaces:**
- Consumes: `ServerProfile[]` existing records and selected imports.
- Produces: `mergeImportedServers(existing: ServerProfile[], imported: ServerProfile[]): BatchMergeResult` and `ServerStore.upsertServers(profiles: ServerProfile[]): Promise<BatchImportSummary>`; summaries contain `added` and `updated` counts.

- [ ] **Step 1: Write failing merge tests**

Cover inserting a new node, exact endpoint re-import, changed endpoint with the same protocol + UUID + remark, same-name/different-UUID separation, local-ID retention, unique IDs for additions, and multiple imported duplicates collapsing to one result.

- [ ] **Step 2: Run tests and confirm failure**

Expected: FAIL because merge exports do not exist.

- [ ] **Step 3: Implement the pure merge helper**

Match in order: protocol + UUID + normalized remark, then protocol + UUID + address + port. Retain the matched record's `id` and `createdAt`; replace its imported connection fields. Never match on remark alone.

- [ ] **Step 4: Add one-write store integration**

Implement `upsertServers` by loading once, calling the helper, saving the resulting array once, and returning its summary. Keep existing `upsertServer` behavior intact.

- [ ] **Step 5: Run merge tests**

Expected: all Task 3 cases PASS.

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/ets/model/ServerBatchMerge.ets entry/src/main/ets/common/ServerStore.ets entry/src/test/LocalUnit.test.ets
git commit -m "feat: batch update imported nodes"
```

### Task 4: Transient preview handoff and selection page

**Files:**
- Create: `entry/src/main/ets/common/SubscriptionImportSession.ets`
- Create: `entry/src/main/ets/pages/SubscriptionImport.ets`
- Modify: `entry/src/main/resources/base/profile/main_pages.json`
- Modify: `entry/src/test/LocalUnit.test.ets`

**Interfaces:**
- Consumes: `SubscriptionParseResult` and `serverStore.upsertServers(profiles)`.
- Produces: transient `SubscriptionImportSession.set/take/clear`, and the `pages/SubscriptionImport` UI.

- [ ] **Step 1: Write failing transient-state tests**

Verify `take()` returns the current parsed result once and then clears it, `clear()` removes it, and no subscription URL is part of the stored state.

- [ ] **Step 2: Run tests and confirm failure**

Expected: FAIL because the session does not exist.

- [ ] **Step 3: Implement the transient session**

Store only parsed profiles and counts in process memory; clone arrays on set/take and never store the source URL.

- [ ] **Step 4: Build the preview page**

On appearance, consume session data or return with an error if absent. Render all nodes selected by default, each with checkbox, remark, protocol, host, and port; add select-all/clear, selected `X/Y`, and disabled confirmation when `X = 0`. Confirm through `upsertServers`, show added/updated counts, then return to the server list.

- [ ] **Step 5: Register the page and run tests/build**

Add `pages/SubscriptionImport` to `main_pages.json`.

Expected: session tests PASS and ArkTS page compilation succeeds.

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/ets/common/SubscriptionImportSession.ets entry/src/main/ets/pages/SubscriptionImport.ets entry/src/main/resources/base/profile/main_pages.json entry/src/test/LocalUnit.test.ets
git commit -m "feat: add subscription selection page"
```

### Task 5: Route scan and paste inputs into direct-link or subscription flows

**Files:**
- Modify: `entry/src/main/ets/pages/ServerEdit.ets`
- Modify: `entry/src/main/ets/common/ScanImportHelper.ets`
- Modify: `entry/src/test/LocalUnit.test.ets`

**Interfaces:**
- Consumes: `SubscriptionService.fetch`, `SubscriptionImportSession.set`, existing `parseShareLink`, and existing single-node persistence.
- Produces: one shared input classifier used by scan, paste/parse, and direct-link handling.

- [ ] **Step 1: Write failing input-classification tests**

Assert case-insensitive HTTP/HTTPS classification after trimming, direct VMess/VLESS classification, unsupported input rejection, and that secret input is absent from error text.

- [ ] **Step 2: Run tests and confirm failure**

Expected: FAIL because shared classification/routing is absent.

- [ ] **Step 3: Implement shared classification**

Add a pure `classifyImportInput(raw: string): 'direct' | 'subscription'` adjacent to the import helper. Preserve the existing direct-link save/edit behavior.

- [ ] **Step 4: Update scan and parse actions**

For subscription input, show a loading state, fetch and parse, place only parsed data in the transient session, and navigate to `pages/SubscriptionImport`. For direct links, retain preview/save and scan-success feedback. Update labels and placeholder text to mention subscription URLs.

- [ ] **Step 5: Run focused tests and compile**

Expected: classification tests PASS; ServerEdit and ScanImportHelper compile without changing direct-link behavior.

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/ets/pages/ServerEdit.ets entry/src/main/ets/common/ScanImportHelper.ets entry/src/test/LocalUnit.test.ets
git commit -m "feat: route subscription imports"
```

### Task 6: End-to-end verification and user documentation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: completed import workflow.
- Produces: documented behavior and verification evidence.

- [ ] **Step 1: Document the supported import flow**

State that QR/paste accepts VMess, VLESS, and HTTP(S) subscriptions; subscriptions are fetched on demand, previewed, selectively imported, and not retained for automatic refresh.

- [ ] **Step 2: Run the full unit-test suite**

Run the installed DevEco/Hvigor unit-test task.

Expected: all entry unit tests PASS.

- [ ] **Step 3: Run a debug HAP build**

Run the installed DevEco/Hvigor assemble-HAP task for the default debug product.

Expected: exit code 0 and a debug HAP under `entry/build/default/outputs/default/`.

- [ ] **Step 4: Perform device/emulator smoke checks when a target is available**

Check: direct VLESS import, 3X-UI subscription QR, selection changes, zero-selection guard, first import counts, second import updates without duplicates, and no full subscription URL in logs. If no target is attached, report these as not executed rather than claiming success.

- [ ] **Step 5: Review the final diff and working tree**

Confirm no credentials or subscription secrets were introduced and `entry/oh-package-lock.json5` remains the user's unrelated modification.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: explain subscription imports"
```
