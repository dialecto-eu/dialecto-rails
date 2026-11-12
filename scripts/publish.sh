#!/usr/bin/env bash
# Publishes dialecto-rails to RubyGems and its GitHub Action to dialecto-eu/dialecto-rails, step by step,
# asking before anything leaves this Mac.
# Run from anywhere: bash sdk/rails/scripts/publish.sh   (--check stops after the clean-folder try)
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)"
mirror="dialecto-eu/dialecto-rails"
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ask() { read -r -p "$1 [y/N] " answer; [[ "$answer" == [yY]* ]]; }

tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT

step "1. Build the gem"
version="$(ruby -e 'require_relative ARGV[0]; print DialectoRails::VERSION' "$here/lib/dialecto_rails/version.rb")"
(cd "$here" && gem build dialecto-rails.gemspec --output "$tmp/dialecto-rails-$version.gem" -q >/dev/null)
gemfile="$tmp/dialecto-rails-$version.gem"
echo "Built dialecto-rails $version"

step "2. What goes to RubyGems"
tar -xOf "$gemfile" data.tar.gz | tar -tz | sed 's/^/  /'

step "3. Checking it installs (automatic, in a temporary folder; can take a minute)"
gem install --install-dir "$tmp/gems" --no-document -q "$gemfile" >/dev/null
GEM_HOME="$tmp/gems" GEM_PATH="$tmp/gems" ruby -e 'require "dialecto_rails"; require "dialecto_rails/scan/cli"'
echo "Installs and loads: OK"
[[ "${1:-}" == "--check" ]] && exit 0

step "4. Check the name and version"
if curl -fsS "https://rubygems.org/api/v1/versions/dialecto-rails.json" 2>/dev/null | grep -q "\"number\":\"$version\""; then
  echo "dialecto-rails $version is already on RubyGems. Raise VERSION in sdk/rails/lib/dialecto_rails/version.rb, then run this again."
  exit 1
fi
echo "dialecto-rails $version is unused."

step "5. Publish the gem"
echo "This makes dialecto-rails $version public on rubygems.org. A published version can't be reused."
echo "RubyGems asks for your email, password and two-factor code if you aren't signed in."
echo "No account yet? Make one at rubygems.org/sign_up and turn on two-factor sign-in first."
if ask "Publish the gem now?"; then
  gem push "$gemfile"
  echo "Live: https://rubygems.org/gems/dialecto-rails"
else
  echo "Skipped the gem."
fi

step "6. The GitHub Action ($mirror)"
echo "Rails projects' CI runs 'uses: $mirror@v1', which installs the gem. This pushes sdk/rails as one new commit"
echo "(no history from this repository) and points the tags v$version and v1 at it. The repository is public."
if ! ask "Publish the Action repository now?"; then
  echo "Skipped the Action. Nothing else to do."
  exit 0
fi
if ! gh repo view "$mirror" >/dev/null 2>&1; then
  gh repo create "$mirror" --public --description "Dialecto for Rails: scan locale files, find call sites, edit text in context (development only)."
fi
url="git@github.com:$mirror.git"
parent=()
if previous="$(git -C "$root" ls-remote "$url" refs/heads/main | cut -f1)" && [[ -n "$previous" ]]; then
  git -C "$root" fetch -q "$url" main
  parent=(-p "$previous")
fi
tree="$(git -C "$root" rev-parse "HEAD:sdk/rails")"
commit="$(git -C "$root" commit-tree "$tree" "${parent[@]}" -m "dialecto-rails $version")"
git -C "$root" push "$url" "$commit:refs/heads/main" "$commit:refs/tags/v$version" "+$commit:refs/tags/v1"
echo "Done: https://github.com/$mirror (tags v$version and v1)"
