# Foreman Pre-Commit Reviewer Memory

## Project Overview
- Monorepo: mobile app (React Native/Expo) + Node.js relay daemon + shared types
- Package manager: pnpm 9 with workspaces (shared, relay, app)
- Node engine: >=22 (enforced in root package.json and .nvmrc)
- Auth model: single bearer token stored in ~/.foreman/token, printed in plaintext during setup summary

## Key File Paths
- `/Users/ryanmartin/repos/foreman/shared/src/types.ts` — Zod schemas + TS types (the API contract)
- `/Users/ryanmartin/repos/foreman/shared/src/index.ts` — re-exports everything from types.ts
- `/Users/ryanmartin/repos/foreman/scripts/server-setup.sh` — server setup (token gen, config, hooks, launchd)
- `/Users/ryanmartin/repos/foreman/tsconfig.base.json` — base TS config (strict, NodeNext, ES2022)
- `/Users/ryanmartin/repos/foreman/app/tsconfig.json` — extends expo/tsconfig.base (NOT tsconfig.base.json)

## Architecture Notes
- `AuthMessageSchema` is intentionally excluded from `ClientRequestSchema` — auth is a connection-level handshake, not a request. This is correct.
- WebSocket message flow: client sends auth first, then ClientRequest messages; server sends ServerMessage (event | response)
- Hooks port (7822) is hardcoded in script and must match RelayConfigSchema default
- `RelayConfigSchema` is in shared/types.ts but `bindHost` field is written to config.json by the setup script — this field is MISSING from RelayConfigSchema (schema/config mismatch)

## Known Issues Found (Phase 0 Review)
1. [CRITICAL] `scripts/server-setup.sh:117` — `$NTFY_TOPIC` injected directly into heredoc JSON without escaping. A topic name with `"` or `\` breaks JSON and could inject arbitrary config values.
2. [CRITICAL] `scripts/server-setup.sh:100` — user-supplied directory paths injected into heredoc JSON without JSON escaping. Paths with `"` or `\` produce malformed JSON.
3. [CRITICAL] `scripts/server-setup.sh:214` — bearer token printed to terminal in plaintext in the final summary block. Anyone with screen access or terminal scrollback sees the secret.
4. [MAJOR] `shared/src/types.ts:173-179` — `RelayConfigSchema` missing `bindHost` field that is written by setup script and presumably read by relay daemon.
5. [MAJOR] `shared/src/types.ts:142` — `.optional().default(100)` ordering: in Zod, this means the *output* type is `number` but the *input* type still accepts `undefined`. Works at runtime but the TypeScript inferred input type may surprise callers. Prefer `.default(100)` only (drop `.optional()`).
6. [MAJOR] `relay/package.json` — `zod` listed as a direct dependency when it is already provided by `@foreman/shared`. Creates a risk of two Zod instances causing `instanceof` / parse failures.
7. [MINOR] `app/tsconfig.json` — extends `expo/tsconfig.base` instead of the monorepo `../tsconfig.base.json`, so `exactOptionalPropertyTypes` and `noUncheckedIndexedAccess` are silently absent in app code.
8. [MINOR] `scripts/server-setup.sh:70` — `chmod 700` applied only to `$FOREMAN_DIR`, not to subdirectories created by the same `mkdir -p` call.
9. [MINOR] `shared/src/types.ts` — `TranscriptEntrySchema` uses `ts` (short) while `SessionSchema` uses `createdAt`/`lastActiveAt` (verbose). Inconsistent timestamp field naming.
10. [MINOR] `relay/package.json` `dev` script runs `node --watch dist/main.js` before a build step, so it watches a file that may not exist yet.

## Conventions Observed
- Zod discriminated unions used consistently for all message types
- All request messages carry a correlation `id: z.string()` for request/response matching
- `ServerResponse` always pairs `ok: boolean` with optional `result`/`error`
- File permissions: 700 for dirs, 600 for secret files — good pattern, watch for gaps
- The setup script is intentionally idempotent (guards all writes with `[ ! -f ... ]`)
