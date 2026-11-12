# The `railsUsages` contract

These fixtures are the usage-record contract between the dialecto-rails gem and Dialecto's server
(`ddd-plan/engineering/spec-0022-rails-structural-edits-and-rename.md`, §6). The spec says what each field means;
the files here say exactly what a scan sends. When the two disagree, the files win and the spec is fixed.

Change them only together with spec-0022 §6, from the server's side. The gem builds against them and never edits
them (`sdk/rails/AGENTS.md`).

## Layout

Each case is a directory:

| Path | What it is |
|---|---|
| `tree/` | a small repository, the root a scan starts from |
| `expected.json` | the `railsUsages` object a scan of `tree/` sends, without `parsers` |

`expected.json` is beside the tree, not in it, so it is never scanned.

## How a scan is compared

- Parse both sides as JSON and compare values; key order doesn't matter, and `parsers` is not compared.
- `usages` are sorted by `file` (byte order), then `offset`. `unscanned` is sorted by `file`, `conventions` by
  `file`, then `line`, then `key` or `prefix`, and `gems` by `name`, then `version`.
- A field that doesn't apply is absent. `fn` and `spans` are always present: `fn` is null outside a method and in
  templates, and `spans` is `[]` when a record has no rewritable literal.
- Offsets and span positions are UTF-8 bytes. `17-byte-offsets` puts multi-byte characters before a call and
  inside a key, where a character count gives a different answer.
- `unscanned` reasons are fixed strings:

  | Reason | When |
  |---|---|
  | `Slim isn't scanned` | a `.slim` template |
  | `HAML isn't scanned` | a `.haml` template, only until the gem reads HAML |
  | `JavaScript that reads the locale files isn't scanned` | every `.js` and `.ts` file, when the project has an i18n-js configuration |
  | `JavaScript that names a catalog key isn't scanned` | a `.js` or `.ts` file with a string equal to a catalog key |
  | `could not be parsed: <the parser's message>` | a Ruby, ERB or HAML file the parser rejects; only the prefix is fixed |

## Cases

| Case | What it pins |
|---|---|
| `01-erb-string-key` | `t("a.b")` in an ERB view |
| `02-controller-string-key` | `t('a.b')` in a controller, and a call that spans lines |
| `03-symbol-keys` | `t(:a)`, `t(:"a.b")`, `t(:'a.b')` |
| `04-scope-string` | `t("b", scope: "a")` in a helper |
| `05-scope-array` | `I18n.t(:b, scope: [:a, :b])`, and a scope element that isn't a literal |
| `06-module-forms` | `I18n.t`, `I18n.translate`, `I18n.t!`, `I18n.translate!`, `I18n.exists?`, and `translate` in a view |
| `07-default-symbol` | a `default:` symbol, and a `default:` string that names no key |
| `08-lazy-view` | `t(".title")` in a view |
| `09-lazy-partial-no-parens` | `t ".edit"` in a partial, without parentheses |
| `10-lazy-controller` | a lazy call in a REST action, and in a private method |
| `11-lazy-mailer` | a lazy call in a mailer action, and the mailer subject convention |
| `12-interpolation` | an interpolated key with a literal start |
| `13-set` | a loop over a literal array |
| `14-dynamic-keys` | variable, constant, method-call, custom-separator and concatenated keys |
| `15-wrapper` | a wrapper method and its calls |
| `16-identical-anchors` | two identical calls on one line |
| `17-byte-offsets` | multi-byte characters before a call and inside a key |
| `18-literal` | a plain string equal to a catalog key |
| `19-unscanned` | a Slim file, and a JavaScript file that names a catalog key |
| `20-gems` | the `gems` list from `Gemfile.lock` |
| `21-haml` | HAML, which the gem must read before renames are switched on (spec-0022 phase 6) |
| `22-lazy-outside-view` | a lazy call in a helper method |
| `23-scope-normalization` | a scope with a trailing dot, a symbol scope holding dots, an array scope mixing both: the key is as I18n reads it (`users.title`), while the spans keep the text as written |
| `24-bom` | a byte-order mark at the start of the file: offsets count its three bytes |
| `25-concatenation` | `"a.b." + x` and `'a.' + x.to_s`: a string literal on the left of `+` is the template `a.b.*`, as `"a.b.#{x}"` is, with no span: a group rename that reaches it is refused, not rewritten |
| `28-unscanned-many-keys` | a JavaScript file that names 201 catalog keys, one past the gem's 200-key cap: the entry carries `"keys": "all"` (no partial list), and the server locks every key on it |
| `27-generator-templates` | `lib/generators/**/templates/**` is not scanned: it holds ERB inside `.rb` and is never loaded, so it is neither a use nor an unscanned file |
| `26-concatenation-right` | `x + ".title"`, `[a, "b"].join(".")` and `"a.%s" % x` are not read: each is `*` |

The server checks every case's internal consistency (each `content` is the tree's bytes at `offset`, lines and
spans agree) in `test/dlocal/localize/rails_usages_contract_test.exs`.
