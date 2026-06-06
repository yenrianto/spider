# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased] — Modular Architecture

### Breaking Changes

- `spider migrate` CLI command removed → use `spider migrate` (new implementation) or `./myapp migrate`
- MySQL and SQLite skeleton drivers removed (will return as proper modules)
- `DriverType` enum removed from `Database` interface

### New Features

#### Modular Modules

- `spider-pg` — PostgreSQL support, opt-in with `-Dpg=true`
- `spider-sqlite` — SQLite support, opt-in with `-Dsqlite=true`, zero config, **default for new projects**
- `spider-r2` — Cloudflare R2 storage, opt-in with `-Dr2=true`

#### CLI

- `spider new myapp` — SQLite by default, server runs immediately without configuration
- `spider new myapp --pg` — PostgreSQL project
- `spider new myapp --api` — no database, no frontend assets
- `spider new myapp --no-db` — no database, with frontend assets
- `spider install` — download frontend assets on demand (spider new is now instant)
- `spider generate feature` — auto-detects database (pg or sqlite) and generates correct SQL syntax
- `spider migrate` — new implementation, supports both SQLite and PostgreSQL

#### Framework

- `sseInterval(ms, callback)` — timer-based SSE broadcasts, Spider manages the thread
- `./myapp migrate` — app binary subcommand for running migrations

### Bug Fixes

- Fixed `intervalLoop` use-after-free (critical) — detached threads accessing freed hub memory
- Fixed `Hub.deinit()` not closing active WebSocket/SSE connections on shutdown
- Fixed `Io.Threaded` handle leak in `app()` and `appWithConfig()`
- Fixed `buildIndex()` error path leaking allocated strings
- Fixed `dupeSentinel` usage for null-terminated strings (Zig 0.17)
- Fixed migration SQL compatibility: SQLite uses `TEXT`/`datetime('now')`/`?1`, PostgreSQL uses `TIMESTAMPTZ`/`NOW()`/`$1`
- Fixed `.env` template: `PG_DATABASE` → `PG_DB`

### Internal

- Memory audit: all confirmed leaks resolved
- `spider-pg`, `spider-sqlite`, `spider-r2` use monorepo structure under `modules/`
- Lazy dependencies via `build.zig.zon` — modules not compiled unless requested
- Test coverage: 13 pg tests, 8 sqlite tests

## [Unreleased]

### Added
- Live reload — WebSocket auto-inject in dev mode
- Runtime mode fully working — includes, layout, HTMX identical to embed mode
- Auto-detect markdown via `--doc` signature in `c.view()`
- Template AST parser rewrite with component support (PascalCase lookup)
- Named slots (`slot_header`, `slot_sidebar`, etc.) and context clone
- Interpolate slot content from parent context
- Struct object support in for loops with dot notation
- Support newlines in component props, `evalBool` for strings
- `array()` helper function for PostgreSQL `ANY()` optimization
- `else if` support in conditionals
- Comparison operators (`==`, `!=`, `<`, `<=`, `>`, `>=`) in templates
- Coalescing operator (`??`) in templates
- Support string slice iteration and dot notation in `evalBool`
- `c.render()` method to render template string directly

### Fixed
- WebSocket RFC 6455 compliance — `std.Io`, endianness, ping/pong, close handshake, hub broadcast
- Skip script tags in templates, support quoted strings in conditionals, handle nested structs
- Support int/float types, literal props, nested components, and parsed slot
- Parse if/for blocks in `parseTextNodes` and support dot notation in `evalBool`
- Prevent `extends` from leaking into rendered output
- `generate_templates` use parent dir inside views/ for field name prefix
- Silence `ReadFailed` logs, use `std.log` for middleware
- Remove `extends` handling from `view()` — engine handles it internally

### Changed
- **BREAKING**: PostgreSQL driver rewritten — pure Zig wire protocol (no libpq dependency)
- Reorganize PostgreSQL driver structure
- Remove legacy Spider files — `pipeline.zig`, `server.zig`, `web.zig`, stubs

### Removed
- `libpq` dependency (PostgreSQL driver is now pure Zig)
- Legacy `src/web.zig`, `src/core/pipeline.zig`

## [0.1.0] - 2026-04-24

### Added
- HTTP server with graceful shutdown (SIGINT/SIGTERM)
- Trie-based router with dynamic params (`/users/:id`), wildcards
- Template engine with blocks, variables, loops, conditionals, includes
- HTMX-aware rendering (partial content for HX-Request)
- WebSocket support + hub broadcasting
- PostgreSQL client with struct mapping, connection pooling, retry logic
- Authentication system (JWT, cookies, Google OAuth)
- HTTP client for external HTTPS API requests
- FormData parsing (arrays, dot notation, URL decoding)
- Structured JSON logging
- Metrics collection with built-in dashboard
- Connection & buffer pooling
- Middleware system (chain functions via `server.use(fn)`)
- Static file serving
- Environment configuration (.env file support)
- Group routes (`.groupGet` / `.group` for route prefixes)
- Docker support with official Zig image
- Zig 0.16+ compatibility
