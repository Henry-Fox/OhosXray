# Subscription Import Design

## Goal

Extend OhosXray so that a user can scan or paste an HTTP(S) subscription URL, preview the VMess and VLESS nodes returned by that subscription, select the nodes to import, and update matching local nodes instead of creating duplicates.

Existing direct `vmess://` and `vless://` imports must continue to work unchanged.

## User experience

1. The user scans a QR code or pastes text on the server import screen.
2. Direct VMess/VLESS links keep the existing single-node flow.
3. An HTTP(S) value is treated as a subscription URL and is fetched only after the user explicitly requests parsing. While editing an existing node, subscription URLs are rejected; editing accepts only a single direct link.
4. The app opens a subscription preview page containing every valid supported node.
5. All nodes are selected initially. The user may select individual rows, select all, or clear the selection.
6. The page shows the current selection count and imports only the selected rows.
7. A result summary reports how many nodes were added, updated, skipped, or invalid.

Each preview row shows the node name, protocol, host, and port. Unsupported or malformed lines are excluded from the selectable list and included in the result summary.

### Preview page layout (pending user confirmation)

Styled with the existing `UiTheme` tokens, matching `ServerEdit`:

1. Top bar: title「订阅导入」on the left, the existing pill「返回」button on the right.
2. Summary line: `共 N 个节点 · 已选 X/N`, followed by `无效 M 条 · 重复 K 条` when either is non-zero (muted text).
3. Action row: two secondary buttons「全选」and「清空」.
4. Scrollable list: one card per node with a checkbox on the left; remark on line 1 (single line, ellipsis); `VLESS · host:port` on line 2 (monospace, muted).
5. Fixed bottom primary button「导入所选（X）」, disabled with reduced opacity when X = 0.
6. After import: toast `新增 a · 更新 u · 跳过 s · 无效 m`, then return directly to the server list with `router.back({ url: 'pages/Index' })`.

## Input classification and decoding

The import entry point trims surrounding whitespace and classifies the input by scheme:

- `vmess://` and `vless://`: parse as one direct share link.
- `http://` and `https://`: fetch as a subscription.
- Anything else: reject with a clear supported-format message.

Subscription responses support both common representations:

- Plain text containing one share link per line.
- A Base64-encoded text payload whose decoded value contains one share link per line.

The decoder normalizes CRLF/LF line endings, ignores blank lines, and attempts to parse only VMess and VLESS entries. It must handle conventional and URL-safe Base64 variants with missing padding. A response is rejected if it is empty or contains no valid supported nodes.

A parsed entry counts as valid only when it has a non-empty address, a non-empty UUID, and an integer port in 1–65535. The existing share-link parsers do not enforce this, so the subscription decoder validates each parsed profile; direct-link behavior stays unchanged.

Duplicate entries inside one subscription are removed by exact trimmed link text, plus by endpoint identity (protocol + UUID + lower-cased address + port), keeping the first occurrence. Entries with the same name but different endpoints are never collapsed.

## Architecture

### Subscription service

Add a small service responsible for:

- Validating the subscription URL.
- Performing the HTTP request with a finite timeout.
- Enforcing a response-size limit before parsing.
- Decoding Base64 or plain-text responses.
- Returning parsed profiles plus non-sensitive warnings.

The service reuses `LinkParser` for individual share links so protocol behavior remains centralized. Network request objects are always destroyed after completion.

### Preview state and navigation

Add a dedicated subscription preview page rather than placing a long selectable list inside the existing edit page. The import entry point passes parsed preview data through a bounded in-memory handoff or the application's existing pending-data pattern; subscription secrets are not placed in navigation URLs.

The preview page owns only transient selection state. It does not save anything until the user confirms the import.

### Batch persistence

Extend `ServerStore` with a batch upsert operation that loads the server list once, applies all selected profiles, and saves once. It returns counts for added, updated, and skipped records; the preview page adds the parser's invalid count to the final summary.

VMess/VLESS share links carry no stable server-side identity, so matching against existing local records follows this order:

1. Endpoint identity: protocol + UUID + lower-cased address + port.
2. Otherwise, protocol + UUID + trimmed remark, only when exactly one existing record has that key. This covers a node whose address or port changed on the server.

Each existing record can be matched by at most one imported profile per batch; a second import resolving to an already-matched record is counted as skipped. When a match is found, the existing local `id` and `createdAt` are retained and the imported connection fields replace the old values. A display-name collision alone never causes an overwrite. Nodes without a match receive new local IDs.

The first version does not persist the subscription URL and does not implement scheduled or background refresh.

## Network and privacy rules

- A subscription is fetched only through a direct user action.
- Only HTTP and HTTPS URLs are accepted, and URLs with embedded credentials (`user:pass@`) are rejected.
- Redirects: `@ohos.net.http` follows redirects automatically and exposes neither the final URL nor a way to disable redirects. On API 23+ the request sets `maxRedirects: 3`; on older systems the platform default applies. Validating the final URL is a known limitation of this version and is not attempted. Moving to RCP (`@kit.RemoteCommunicationKit`) would lift it but adds a new dependency.
- Requests use a 12 s connect timeout, a 30 s read timeout, and a 2 MiB response limit (`maxLimit`, plus a `Content-Length` pre-check when the header is present).
- Full subscription URLs, query strings, credentials, response bodies, UUIDs, and share links are never written to normal logs or displayed in raw error messages.
- User-facing errors name the failure category, such as timeout, HTTP status, oversized response, invalid encoding, or no supported nodes.

## Error handling

Failures before preview leave existing server data untouched. Failures while parsing one line do not prevent other valid lines from being previewed. Confirming with no rows selected is blocked with a local prompt.

Batch persistence is treated as one logical operation: the final server list is written once, so the UI cannot observe a partially imported subscription.

## Testing

Add unit coverage for:

- Existing direct VMess/VLESS parsing behavior.
- Plain-text subscription responses.
- Standard and URL-safe Base64 payloads, including missing padding.
- CRLF, blank lines, and mixed valid/invalid entries.
- Empty, malformed, oversized, and unsupported-only responses.
- Selection filtering.
- New-node insertion and matched-node update while retaining the local ID.
- Same-name nodes with different identities remaining separate.
- Redaction of subscription secrets from surfaced errors and logs.

Pure logic (decoding, validation, input classification, merging) lives in files that do not import `@kit.NetworkKit`, so tests do not load the HTTP module. Before writing feature tests, a smoke test confirms that the local test runtime (`entry/src/test`) can load `@kit.ArkTS` `util`/`url`; if it cannot, the tests move to `entry/src/ohosTest` and run on a device.

Run the project's unit tests and debug build after implementation. The existing `entry/oh-package-lock.json5` working-tree modification is unrelated and must not be altered by this work.

## Out of scope

- Persisting subscription URLs.
- Automatic or scheduled subscription updates.
- Subscription groups or subscription deletion UI.
- Protocols other than VMess and VLESS.
- Parsing arbitrary HTML pages as subscriptions.
