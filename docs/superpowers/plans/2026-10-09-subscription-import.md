# Subscription Import Implementation Plan

> **For agentic workers:** Execute tasks in order. Steps use checkbox (`- [ ]`) syntax for tracking. Commit once at the end of every task.

**Goal:** Let users scan or paste an HTTP(S) subscription, preview its VMess/VLESS nodes, select rows, and import them while updating matching local nodes.

**Architecture:** Keep share-link parsing centralized in `LinkParser`. Add pure modules for subscription decoding, input classification/URL validation, and batch merging; none of them import `@kit.NetworkKit`. A thin HTTP service fetches the payload, a transient in-memory session hands parsed profiles to a dedicated selection page, and `ServerStore` performs a single final write.

**Tech Stack:** ArkTS, HarmonyOS ArkUI, `@kit.NetworkKit` `http`, `@kit.ArkTS` Base64/text utilities, Preferences, Hypium, Hvigor. See `docs/tech-stack-with-versions.md`.

**Spec:** `docs/subscription-import-design.md`

**Commands (run from `D:\Project\OhosXray`):**

- Hvigor: `& "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat"` (referred to below as `hvigorw`). Set `$env:DEVECO_SDK_HOME="C:\Program Files\Huawei\DevEco Studio\sdk"` first.
- Local unit tests: `hvigorw --mode module -p module=entry@default -p product=default test --no-daemon`.
- Device test HAP: `hvigorw --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug assembleHap --no-daemon`.
- Debug HAP: `hvigorw --mode module -p module=entry@default -p product=default assembleHap --no-daemon`.

**Test placement (verified in Task 0):** the local test runtime auto-mocks system APIs (`url.URL` throws `URLSearchParams is not defined`). Cases that need `@kit.ArkTS` `util`/`url` (share-link parsing, Base64, URL validation) live in `entry/src/ohosTest/ets/test/` and run on a device; system-API-free cases (input classification, merge with an injected id generator, session) stay in `entry/src/test/LocalUnit.test.ets`. Without an attached device, ohosTest cases are compiled but reported as not executed.

## Global Constraints

- Existing direct `vmess://` and `vless://` imports continue to work unchanged.
- Subscription responses may be plain text or standard/URL-safe Base64 with omitted padding.
- Only VMess and VLESS entries are importable; one malformed entry must not reject valid siblings.
- Fetch only after explicit user action, with finite timeouts and a 2 MiB response-size limit.
- Never log or surface full subscription URLs, query strings, response bodies, UUIDs, or share links.
- Do not persist subscription URLs or add scheduled/background refresh.
- Pure logic files must not import `@kit.NetworkKit`.
- New code uses JSDoc comments, matching the user's rules.
- Preserve the unrelated working-tree change in `entry/oh-package-lock.json5`; never stage it.

## Review Focus

- `@ohos.net.http` cannot report the final URL after redirects; the plan limits redirects (`maxRedirects: 3` on API 23+) and documents the limitation instead of claiming final-URL validation.
- A Base64-looking plain-text response must fall back to plain-text parsing when decoding yields no usable links.
- Duplicate links (exact text or same endpoint identity) inside one subscription must appear/import once.
- Two nodes with the same name but different endpoints or UUIDs must remain separate.
- Re-importing a moved endpoint with the same protocol, UUID, and remark must update the single matching record while retaining its local `id` and `createdAt`.
- Parsed entries with an empty address/UUID or an invalid port count as invalid.

---

### Task 0: Confirm the test runtime

**Files:**
- Modify: `entry/src/test/LocalUnit.test.ets`

- [ ] **Step 1: Add a smoke test**

Add one case that calls `parseShareLink` on a synthetic `vless://` link (fake UUID such as `00000000-0000-4000-8000-000000000000`, host `example.com`) and asserts protocol, address, and port. This exercises `util` and `url` from `@kit.ArkTS`.

- [ ] **Step 2: Run the local unit tests**

Expected: PASS. If the local runtime cannot load `@kit.ArkTS` `util`/`url`, move all tests in this plan to `entry/src/ohosTest/ets/test/` (registered in its `List.test.ets`), run them on a device, and replace `entry/src/test/LocalUnit.test.ets` with the ohosTest path in every later task.

- [ ] **Step 3: Commit**

```bash
git add entry/src/test/LocalUnit.test.ets
git commit -m "test: smoke-test share link parsing"
```

### Task 1: Pure subscription payload parser

**Files:**
- Create: `entry/src/main/ets/model/SubscriptionParser.ets`
- Modify: `entry/src/test/LocalUnit.test.ets`

**Interfaces:**
- Consumes: `parseShareLink(link: string): ServerProfile` from `LinkParser.ets`.
- Produces:
  - `isUsableProfile(profile: ServerProfile): boolean` — non-empty address and UUID, integer port in 1–65535.
  - `endpointKey(profile: ServerProfile): string` — protocol + UUID + lower-cased address + port.
  - `parseSubscriptionPayload(payload: string): SubscriptionParseResult`, where `SubscriptionParseResult` contains `profiles: ServerProfile[]`, `invalidCount: number`, and `duplicateCount: number`.

- [ ] **Step 1: Write failing parser tests**

Add Hypium cases for plain LF/CRLF text, blank lines, standard Base64, URL-safe Base64 without padding, mixed valid and invalid lines, unsupported schemes counted as invalid, profiles failing `isUsableProfile` counted as invalid, exact duplicate links, different links with the same endpoint key, same remark with different endpoints kept separate, empty input, unsupported-only input, and Base64-looking plain text fallback. Use synthetic UUIDs only; assert profile fields and counts without logging raw input.

- [ ] **Step 2: Run the unit tests and confirm the new cases fail**

Expected: FAIL because `SubscriptionParser.ets` and its exports do not exist.

- [ ] **Step 3: Implement the parser**

Normalize line endings, try Base64 decoding (standard and URL-safe, padding restored) and use the decoded text only when it yields at least one supported link; otherwise parse the original text. For each non-blank line: skip exact duplicates, parse VMess/VLESS through `parseShareLink`, count parse failures and unusable profiles as invalid, skip repeated endpoint keys as duplicates, and set `originalLink` to the trimmed line. Throw category-only errors (`empty`, `no-supported-nodes`) that never contain payload text.

- [ ] **Step 4: Run the parser tests**

Expected: all Task 1 cases PASS.

- [ ] **Step 5: Commit**

```bash
git add entry/src/main/ets/model/SubscriptionParser.ets entry/src/test/LocalUnit.test.ets
git commit -m "feat: parse subscription payloads"
```

### Task 2: Input classification, URL validation, and HTTP fetch

**Files:**
- Create: `entry/src/main/ets/model/ImportInput.ets` (pure)
- Create: `entry/src/main/ets/common/SubscriptionService.ets` (HTTP)
- Modify: `entry/src/test/LocalUnit.test.ets`

**Interfaces:**
- `ImportInput.ets` produces:
  - `classifyImportInput(raw: string): 'direct' | 'subscription' | 'unsupported'` — trims, case-insensitive scheme check.
  - `validateSubscriptionUrl(urlText: string): string` — returns the trimmed URL or throws a category-only error.
  - `SUBSCRIPTION_MAX_BYTES = 2 * 1024 * 1024`, `SUBSCRIPTION_CONNECT_TIMEOUT_MS = 12000`, `SUBSCRIPTION_READ_TIMEOUT_MS = 30000`, `SUBSCRIPTION_MAX_REDIRECTS = 3`.
  - `subscriptionErrorMessage(category: string): string` — Chinese user-facing text per category (invalid URL, timeout, HTTP status, oversized, decode failure, no supported nodes, network).
- `SubscriptionService.ets` produces `SubscriptionService.fetch(urlText: string): Promise<SubscriptionParseResult>`.

- [ ] **Step 1: Write failing tests for the pure module**

Cover: `vmess://`/`vless://` (any case, surrounding whitespace) → `direct`; `http://`/`https://` (any case) → `subscription`; other schemes and plain text → `unsupported`; URL validation accepting HTTP/HTTPS and rejecting missing scheme, non-HTTP schemes, empty host, and embedded credentials; every error message free of the original URL, its query string, and UUID-like values; pinned constant values.

- [ ] **Step 2: Run tests and confirm failure**

Expected: FAIL because the exports do not exist.

- [ ] **Step 3: Implement `ImportInput.ets`**

Use `url.URL` from `@kit.ArkTS` for validation. Errors carry only a category code.

- [ ] **Step 4: Implement `SubscriptionService.fetch`**

Validate the URL, then `http.createHttp().request` with `GET`, `expectDataType: ARRAY_BUFFER`, `usingCache: false`, the timeout constants, and `maxLimit: SUBSCRIPTION_MAX_BYTES`. Set `maxRedirects: SUBSCRIPTION_MAX_REDIRECTS` only when `deviceInfo.sdkApiVersion >= 23`. Reject non-2xx status codes and bodies at or above the limit (`maxLimit` already caps the download, so no separate `Content-Length` pre-check). Decode UTF-8 with `util.TextDecoder`, call `parseSubscriptionPayload`, and map every failure to a category. Destroy the request in `finally`. Log only categories and response codes.

- [ ] **Step 5: Run tests and an invalid-URL manual check**

Expected: unit tests PASS; the service compiles; an invalid URL yields a Chinese error without echoing any part of the URL.

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/ets/model/ImportInput.ets entry/src/main/ets/common/SubscriptionService.ets entry/src/test/LocalUnit.test.ets
git commit -m "feat: validate and fetch subscriptions safely"
```

### Task 3: Deterministic batch merge and one-write persistence

**Files:**
- Create: `entry/src/main/ets/model/ServerBatchMerge.ets`
- Modify: `entry/src/main/ets/common/ServerStore.ets`
- Modify: `entry/src/test/LocalUnit.test.ets`

**Interfaces:**
- Consumes: existing `ServerProfile[]`, selected imported `ServerProfile[]`, `endpointKey` from Task 1.
- Produces: `mergeImportedServers(existing: ServerProfile[], imported: ServerProfile[]): BatchMergeResult` (`servers`, `added`, `updated`, `skipped`) and `ServerStore.upsertServers(profiles: ServerProfile[]): Promise<BatchImportSummary>` (`added`, `updated`, `skipped`).

- [ ] **Step 1: Write failing merge tests**

Cover: new node inserted with a fresh unique `id`; exact endpoint re-import updates in place; moved endpoint with the same protocol + UUID + remark updates the single matching record; the remark fallback is not used when two existing records share that key; same remark with a different UUID stays separate; retained `id` and `createdAt`; two imports resolving to one existing record → first updates, second counted as skipped; existing records not in the import are untouched and keep their order.

- [ ] **Step 2: Run tests and confirm failure**

Expected: FAIL because merge exports do not exist.

- [ ] **Step 3: Implement the pure merge helper**

Match in two passes so input order cannot steal a record: first every import by endpoint key; then, for still-unmatched imports, protocol + UUID + trimmed remark only when exactly one existing record and exactly one unmatched import share that key and the record is not already matched. Track matched existing ids so each record is updated at most once. On match, copy imported connection fields and keep the existing `id`/`createdAt`; on no match, append with `util.generateRandomUUID()` and `Date.now()`. Never match on remark alone.

- [ ] **Step 4: Add one-write store integration**

Implement `upsertServers` by calling `listServers` once, the helper, and `saveServers` once. Keep `upsertServer` unchanged.

- [ ] **Step 5: Run merge tests**

Expected: all Task 3 cases PASS.

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/ets/model/ServerBatchMerge.ets entry/src/main/ets/common/ServerStore.ets entry/src/test/LocalUnit.test.ets
git commit -m "feat: batch update imported nodes"
```

### Task 4: Transient preview handoff and selection page

> **Gate:** do not start Step 4 until the user has confirmed the layout in the spec section "Preview page layout".

**Files:**
- Create: `entry/src/main/ets/common/SubscriptionImportSession.ets`
- Create: `entry/src/main/ets/pages/SubscriptionImport.ets`
- Modify: `entry/src/main/resources/base/profile/main_pages.json`
- Modify: `entry/src/test/LocalUnit.test.ets`

**Interfaces:**
- Consumes: `SubscriptionParseResult` and `serverStore.upsertServers(profiles)`.
- Produces: transient `SubscriptionImportSession.set/take/clear`, and the `pages/SubscriptionImport` UI.

- [ ] **Step 1: Write failing transient-state tests**

Verify `take()` returns the parsed result once and then returns `null`, `clear()` removes it, returned arrays are copies, and the stored type has no URL field.

- [ ] **Step 2: Run tests and confirm failure**

Expected: FAIL because the session does not exist.

- [ ] **Step 3: Implement the transient session**

Store only parsed profiles and counts in process memory; clone arrays on `set`/`take`.

- [ ] **Step 4: Build the preview page per the confirmed layout**

In `aboutToAppear`, call `serverStore.init` and `take()`; if nothing is available, toast an error and `router.back()`. All rows start selected. Confirm through `upsertServers`, toast `新增 a · 更新 u · 跳过 s · 无效 m`, then `router.back({ url: 'pages/Index' })`. Disable the confirm button while saving and when no row is selected.

- [ ] **Step 5: Register the page, run tests, and build**

Add `pages/SubscriptionImport` to `main_pages.json`.

Expected: session tests PASS and `assembleHap` succeeds.

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/ets/common/SubscriptionImportSession.ets entry/src/main/ets/pages/SubscriptionImport.ets entry/src/main/resources/base/profile/main_pages.json entry/src/test/LocalUnit.test.ets
git commit -m "feat: add subscription selection page"
```

### Task 5: Route scan and paste inputs into direct-link or subscription flows

**Files:**
- Modify: `entry/src/main/ets/pages/ServerEdit.ets`
- Modify: `entry/src/main/ets/common/ScanImportHelper.ets`

**Interfaces:**
- Consumes: `classifyImportInput`, `SubscriptionService.fetch`, `SubscriptionImportSession.set`, existing `parseShareLink`, and existing single-node persistence.

- [ ] **Step 1: Route the scan action**

In `ServerEdit.onScanQr`, classify the scanned text first. `direct` keeps the existing `ScanImportHelper.saveFromLink` path, success feedback, and `router.back()`. `subscription` goes to the shared subscription flow (Step 3). `unsupported` shows the supported-format message.

- [ ] **Step 2: Route the parse action**

`onParse` keeps its synchronous direct-link preview. For `subscription` input it starts the shared subscription flow instead of calling `parseShareLink`.

- [ ] **Step 3: Implement the shared subscription flow**

If `editingId` is set, show 「编辑节点仅支持单个节点链接」and stop. Otherwise set a `loading` state (parse button shows 「获取中…」and is disabled; scan is blocked), call `SubscriptionService.fetch`, put the result in `SubscriptionImportSession`, and `router.pushUrl({ url: 'pages/SubscriptionImport' })`. On failure show only the category message.

- [ ] **Step 4: Update copy**

Divider text 「或粘贴分享链接 / 订阅地址」; placeholder 「粘贴 vmess:// / vless:// 分享链接或 http(s) 订阅地址」; card label 「分享链接 / 订阅地址」. `ScanImportHelper` error text no longer echoes the raw parse error.

- [ ] **Step 5: Compile and check direct-link behavior**

Expected: `assembleHap` succeeds; the direct-link save/edit path is unchanged in code review.

- [ ] **Step 6: Commit**

```bash
git add entry/src/main/ets/pages/ServerEdit.ets entry/src/main/ets/common/ScanImportHelper.ets
git commit -m "feat: route subscription imports"
```

### Task 6: End-to-end verification and user documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document the supported import flow**

State that QR/paste accepts VMess, VLESS, and HTTP(S) subscriptions; subscriptions are fetched on demand, previewed, selectively imported, matched against existing nodes, and not retained for automatic refresh.

- [ ] **Step 2: Run the full unit-test suite**

Expected: all tests PASS.

- [ ] **Step 3: Run a debug HAP build**

Expected: exit code 0 and a debug HAP under `entry/build/default/outputs/default/`.

- [ ] **Step 4: Perform device smoke checks when a target is available**

Check: direct VLESS import, 3X-UI subscription QR, paste of a subscription URL, selection changes, zero-selection guard, first import counts, second import updates without duplicates, subscription URL rejected in edit mode, and no subscription URL in `hdc hilog` output. If no device is attached, report these as not executed rather than claiming success.

- [ ] **Step 5: Review the final diff and working tree**

Confirm no credentials or subscription secrets were introduced and `entry/oh-package-lock.json5` remains the user's unrelated, unstaged modification.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: explain subscription imports"
```
