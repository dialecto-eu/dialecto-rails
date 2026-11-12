# AGENTS.md — dialecto-rails

Instructions for AI coding agents working in this package. It is self-contained: it will live in its own repository.
Spec: `ddd-plan/engineering/spec-0023-rails-sdk.md`. The usage-record contract is spec-0022 §6 and its fixture files
in `test/contract/`, which are the only contract: never edit them from here.

## What this is

A Ruby gem with three parts: a scanner CLI and GitHub Action that send a Rails app's locale files to Dialecto, a
static usage scan of Ruby and ERB call sites, and a development-only in-context editor (Railtie and Rack
middleware). Client-side, public, MIT.

## Layout

| Path | Role |
| --- | --- |
| `exe/dialecto-rails` | The CLI. The only place that requires the scan and usage code. |
| `lib/dialecto-rails.rb`, `lib/dialecto_rails.rb` | What `Bundler.require` loads: the version and, inside Rails, the Railtie stub. Never Prism or Herb. |
| `lib/dialecto_rails/config.rb` | Settings: option over environment over default. |
| `lib/dialecto_rails/scan/` | `git` reading, catalog path matching, the envelope, the HTTP client, the CLI. |
| `lib/dialecto_rails/in_context/` | The Railtie and what it installs (development only). |
| `action.yml` | The composite GitHub Action. |
| `test/unit`, `test/integration` | Minitest suites. `test/support/fake_dialecto.rb` answers the scan contract; `git_fixture.rb` builds repositories. |

## Build and test

```sh
rake test
```

Run it before claiming a change works, and add a test for every behavior you change. No sleeps: inject the clock
or the sleeper.

## Invariants

- **Read boundary.** Locale files only, from the committed state at a sha (`git ls-tree`, `git cat-file`), never
  the working tree. Call-site anchors leave the machine only when the usage scan is switched on, and only the
  anchor, at most 2,000 bytes, never a file.
- **The token** comes from the environment only. It is never printed, logged, put in an error, an option or a
  file, and never sent over plain HTTP to a non-loopback host.
- **Dev only (development mode).** The dev Railtie acts only when `::Rails.env.development?`, serves only a loopback *peer*
  (`REMOTE_ADDR`; the `Host` header is the client's to choose; never `X-Forwarded-For`), and leaves nothing in other
  environments.
- **Live mode (`config.dialecto.mode = :live`).** A visitor's request reaches the app untouched, and the session
  is not read for them (loading it makes the session store write a cookie). None of the development machinery
  exists in `:live`: the loopback checks guard `:dev` only, because behind a proxy on the same host anyone can send
  `Host: localhost`; there are no `/context`, `/overrides` or `/marking` endpoints and no `Store`. Marking is a flag
  in `ActiveSupport::IsolatedExecutionState`, never global; only `GET`/`HEAD` with `Sec-Fetch-Dest` `document` or
  `iframe` (or a same-origin `empty` fetch that accepts HTML, as Turbo makes) are marked. Fragment caching is off
  while the flag is on, and the session is never touched. The origin comes from configuration, never from a request header. The overlay is a copy
  under `in_context/assets/`; refresh it with `rake overlay:refresh`.
- **Never break the host app.** Everything in the Railtie rescues `StandardError` and falls back to the unmarked
  result.
- `::Rails` always with the leading colons; the namespace is `DialectoRails`.
- Dependencies: Prism and Herb only. HTTP is `Net::HTTP`; no shell, `Open3` with argument arrays.
- Comments say why, never history. Write "machine translation" in full, never "MT". Use the editor tools, not shell
  text tools.
