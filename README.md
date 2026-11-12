# dialecto-rails

Dialecto for Rails: the customer-side half of minimal-diff translation pull requests. Spec:
`ddd-plan/engineering/spec-0023-rails-sdk.md`. MIT.

Three parts, one gem:

| Part | What it does |
| --- | --- |
| Scanner | `dialecto-rails scan` (and a GitHub Action) sends `config/locales/**/*.yml` to Dialecto from CI. |
| Usage scan | Reads where Ruby and ERB code reads each key, so a key rename can rewrite its call sites. Off unless you ask. |
| In-context editing | A development-only Railtie: click a string in your running app, edit it, open a pull request. |

## In-context editing (development only)

```ruby
# Gemfile
group :development do
  gem "dialecto-rails"
end
```

Start `rails server`; an "Edit text" button appears on every page. Dialecto finds the project from your git
remote. The Railtie does nothing outside `development` (not in `test`, `staging` or `production`, even with the
gem forced into the bundle), and its endpoints answer only a loopback peer. Only strings from your own
`config/locales` are marked. Keep a key away from the editor with `config.dialecto.skip_keys = ["routes.*",
/\.slug\z/]`; `DIALECTO_IN_CONTEXT=off` or `config.dialecto.enabled = false` switches it off. Fragment caching
(`rails dev:cache`) serves cached text without markers.

## Editing the live site

The same gem can run in production, inert for visitors and on only for an editor who arrives with a signed launch
link from Dialecto ("Edit on live site"). An edit made this way is an ordinary staged edit in Dialecto; the site
never writes anything itself.

### When to use it

Live-site editing costs visitors nothing: no Dialecto script, no markers, the same bytes. It suits Rails sites,
not only static ones.

- **Do** wrap in `DialectoRails.unmarked { … }` anything that leaves the page during a marked render: a mail sent
  while an editor's request is being handled, text you memoise or put in `Rails.cache`, translated text you write
  to the database, Action Cable or Turbo Stream broadcasts, and job arguments. Markers are invisible characters;
  they would be stored and sent to everyone.
- **Know** that fragment caching is switched off for a marked request: it neither reads nor writes fragments (a
  cold fragment rendered for an editor would be cached with markers and served to every visitor), so an editor's
  pages render fresh and a visitor's cache is untouched.
- **Do** keep the settings below in version control: they are public.
- **Do** serve the site over HTTPS only, and set `origin` to exactly what the browser shows: `www` or the apex,
  and the port. The launch cookie is `Secure`.
- **Do** keep the server clock right (NTP): a launch link must arrive within two minutes of being minted.
- **Don't** put a CDN or page cache in front that stores HTML and ignores cookies. Marked pages are sent
  `Cache-Control: private, no-store` and `Vary: Cookie` (and lose their `ETag` and `Last-Modified`), but a cache
  that disregards them defeats this: leave the site out or do not enable live mode.
- **Don't** expect it on pages served from a cache without reaching Rails (page caching, a static export): there
  is nothing to mark.
- **Don't** compress responses inside the app, below Dialecto's middleware: the loader can't be added to a
  compressed body, and editors get marked pages without the editor. Compress outside the app (the reverse proxy),
  or put `Rack::Deflater` before the Dialecto middleware.
- **Know** that the launch URL, token included, appears in reverse-proxy access logs (Rails filters it from its own
  log). It is worth eight hours of seeing marked pages and no edits. A link to a static file path keeps its token in
  the URL, because `ActionDispatch::Static` answers before the middleware. The editor needs the `Sec-Fetch-Dest`
  header (Safari 16.4 or newer).

### Setup

Move the gem out of `group :development` so it is installed in production, and turn it on in
`config/environments/production.rb` (or an initializer) with the settings from the repo's Dialecto settings page:

```ruby
config.dialecto.mode = :live
config.dialecto.repo = "owner/name"
config.dialecto.origin = "https://www.example.com"
config.dialecto.public_key = "ed25519:…"
```

**How a release gets `:live`:** unset, `mode` is `:dev` in development and `:off` in every other environment, so a
production deploy is inert until its config sets `mode = :live`. In `:live` the Railtie also needs `repo`, `origin`
and `public_key`; without all three it stays off. `origin` is the site's own origin; it is never read from `Host` or
`X-Forwarded-*`, which a proxy can rewrite. The middleware goes in after the session middleware.

Ed25519 verification uses Ruby's OpenSSL bindings: the `openssl` gem 3.2 or later on OpenSSL 1.1.1 or later. Ruby
3.3 and newer ship it. On Ruby 3.2, add `gem "openssl", ">= 3.2"` to the Gemfile; without it, live mode stays off and
the log says why. `ruby -ropenssl -e 'p OpenSSL::VERSION'` shows what you have.

### What happens

- A `GET` with `?dialecto_edit=<token>` is verified inside your app (an Ed25519 signature under the repo's key,
  made for this purpose only, `start_by` within two minutes, the token's origin equal to `origin`). A good one
  becomes the `dialecto_edit` cookie (`HttpOnly; Secure; SameSite=Lax; Path=/`, ending at the token's `exp`, at
  most eight hours), and the answer is `303` to the same URL without the parameter. The session is never touched.
  A bad token is ignored, the parameter is still removed, and the reason (late, expired, bad signature, wrong
  origin, wrong repo) is logged at `info`. Misconfigured live mode logs one warning at boot saying what is missing.
- While the cookie is valid, `GET` and `HEAD` requests for a document or an iframe, and Turbo Drive visits
  (same-origin fetches that ask for HTML), are marked, carry the overlay
  loader, `Cache-Control: private, no-store`, `Vary: Cookie` and `X-Robots-Tag: noindex`, and Dialecto is added to
  the page's CSP `frame-src` (only on those responses). The overlay is served from your own origin at
  `/__dialecto/overlay.js`, never as a script from Dialecto. `POST`, fetches and JSON responses are never marked.
  The flag lives in the rendering thread, so jobs and other threads never inherit it.
- `POST /__dialecto/stop` clears the cookie.
- In `:live` the development endpoints (`/__dialecto/context`, `/overrides`, `/marking`) do not exist and answer
  404, and the development store is never loaded.
- A visitor's request reaches your app untouched, and the session is not even read for them. The launch token is
  filtered from Rails' request log (`filter_parameters`).

A launch token that leaks is worth at most eight hours of seeing marked pages: it does not let anyone change text.
Editing needs Dialecto's own sign-in, scoped to the repo and the site.

### Refreshing the overlay copy

`lib/dialecto_rails/in_context/assets/overlay.js` is a copy of Dialecto's built overlay. Maintainers build it in the
Dialecto repository (`mix esbuild in_context`) and run `rake overlay:refresh` here. A test in the Dialecto repository
fails when the copy differs from a fresh build.

## Scanning from CI

```yaml
- uses: actions/checkout@v4
- uses: dialecto-eu/dialecto-rails@v1
  with:
    project: 12                                  # the number in your project's Dialecto URL /repos/12
    token: ${{ secrets.DIALECTO_SCAN_TOKEN }}
```

The action pins every third-party action it uses by full commit SHA (the tag stays in a comment); a release bumps
them by looking up the latest tag with `gh api repos/<owner>/<repo>/releases/latest` and its commit SHA.

Or without the action: `DIALECTO_SCAN_TOKEN=… DIALECTO_PROJECT=12 dialecto-rails scan`. It sends the files as
committed at `HEAD`, never your working tree. `dialecto-rails doctor` checks the setup and says how to fix each
problem.

## Usage scan

`DIALECTO_USAGES=on` (or `scan --usages`) adds, to the same scan, the places your Ruby, ERB and HAML code reads
a key: `t("a.b")`, `I18n.t`, `translate`, `t!`, lazy keys (`t(".title")` in a view or controller), keys built
from a literal prefix (`t("nav.#{key}")`), and methods that pass their argument on to `t` (wrappers). It sends a
short anchor of the call (never a whole file) so a key rename can rewrite its call sites, and it reads committed
code only. Slim and client-side JavaScript are not scanned: a key they name stays locked. Add your own
translate helpers with `DIALECTO_I18N_FUNCTIONS=my_t,tt` and skip folders with `DIALECTO_USAGES_EXCLUDE`.

Methods called on a constant count too (`Spree.t("foo")`, `::Spree.t`) when they are wrappers: defined with
`def self.t`, under `class << self`, with `module_function` or `extend self`, or aliased. A method that comes from
a gem, or adds a scope the scan can't read, is declared: `wrappers: [{call: "Spree.t", scope: "spree"}]` in
`config.dialecto` or `DIALECTO_WRAPPERS="Spree.t=spree"`. `spree_core` and `solidus_core` in `Gemfile.lock` declare
`Spree.t` and `Spree.translate` for you. Such a call is recorded with its absolute key but no edit point, so a
rename of that key is refused, never half done.

```
dialecto-rails usages [--summary] [--out FILE] [--worktree]   # what the scan found, per key class
dialecto-rails check                                          # CI after a rename: code that reads a key the catalogs no longer hold
```

`--worktree` reads the folder instead of `HEAD` (to try the scan on code you haven't committed; never use it for
a scan you send). `--require-usages` fails a scan when the code can't be read, instead of sending the catalogs without call sites. The parse error of a file leaves
the scan, as `could not be parsed: <200 bytes>`, never an exception message or source text.

`dialecto-rails doctor` warns when `WEB_CONCURRENCY` is above 1, because the in-context editor's store is per
process.

If you only want your locale files read, Dialecto's settings page also generates a workflow that needs nothing
installed (just `git`, `jq` and `curl`).

## Settings

An option in code wins over the environment, and the environment wins over the default.

| Option | Environment variable | Default |
| --- | --- | --- |
| `url` | `DIALECTO_URL` | `https://app.dialecto.eu` |
| `project` | `DIALECTO_PROJECT` | scan: required (the project's number); in-context: found from the git remote |
| none (environment only) | `DIALECTO_SCAN_TOKEN` | none |
| `catalog_paths` | `DIALECTO_CATALOG_PATHS` | `config/locales/**/*.yml,config/locales/**/*.yaml` |
| `catalogs` | `DIALECTO_CATALOGS` | `config/locales` |
| `usages` | `DIALECTO_USAGES=on` | off |
| `require_usages` | `DIALECTO_REQUIRE_USAGES=on` | off |
| `wrappers` | `DIALECTO_WRAPPERS` | none (the lockfile's gems add known ones) |
| `i18n_functions` | `DIALECTO_I18N_FUNCTIONS` | none |
| `usages_exclude` | `DIALECTO_USAGES_EXCLUDE` | none |
| `default_branch` | `DIALECTO_DEFAULT_BRANCH` | `origin/HEAD` |
| `enabled` | `DIALECTO_IN_CONTEXT=off` | on in development |
| `paths` | `DIALECTO_PATHS` | every page |
| `skip_keys` | `DIALECTO_SKIP_KEYS` | none |

`DIALECTO_URL` must be `https://` (or `http://` on localhost): the scanner never sends the token over plain
HTTP to another host unless `DIALECTO_ALLOW_INSECURE=1`.

Exit codes: 0 done, 1 `check` found problems, 2 the command can't start (the message names the setting), 3
Dialecto refused the scan and a retry can't help, 4 Dialecto or the network is unavailable (rerun; scans are
idempotent).

## Tests

```
rake test
rake corpus[DIR]   # the usage scan over the ten pinned apps (heavy; fetch them with ddd-plan's corpus/fetch.sh)
```
