require "uri"

module DialectoRails
  # Settings, with sdk/astro's precedence: an option wins over the environment, and the environment wins
  # over the default. `options` is a Hash of symbols (the Railtie's `config.dialecto`, or CLI flags).
  class Config
    DEFAULT_URL = "https://app.dialecto.eu".freeze
    DEFAULT_CATALOG_PATHS = ["config/locales/**/*.yml", "config/locales/**/*.yaml"].freeze
    DEFAULT_CATALOGS = "config/locales".freeze
    OFF = %w[off false 0 no].freeze
    ON = %w[on true 1 yes].freeze
    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 [::1] ::1].freeze

    attr_reader :options, :env

    def initialize(options = {}, env = ENV)
      @options = options.to_h.transform_keys(&:to_sym)
      @env = env
    end

    def url
      text(:url, "DIALECTO_URL")&.sub(%r{/+\z}, "") || DEFAULT_URL
    end

    def project = text(:project, "DIALECTO_PROJECT")

    # The token is never an option: it lives in the environment (a CI secret), not in a file.
    def scan_token = blank_to_nil(env["DIALECTO_SCAN_TOKEN"])

    def catalog_paths = list(:catalog_paths, "DIALECTO_CATALOG_PATHS") || DEFAULT_CATALOG_PATHS

    def catalogs = text(:catalogs, "DIALECTO_CATALOGS") || DEFAULT_CATALOGS

    def source_locale = text(:source_locale, "DIALECTO_SOURCE_LOCALE")

    def usages_exclude = list(:usages_exclude, "DIALECTO_USAGES_EXCLUDE") || []

    def i18n_functions = list(:i18n_functions, "DIALECTO_I18N_FUNCTIONS") || []

    # Translate methods called on a constant that the scan can't read, as `[{call: "Spree.t", scope: "spree"}]`.
    # From the environment: `DIALECTO_WRAPPERS="Spree.t=spree,Admin::I18n.tr"` (a scope after `=`, optional).
    def wrappers
      configured = option(:wrappers)
      return Array(configured).map { |entry| entry.is_a?(Hash) ? entry : {call: entry.to_s} } if configured

      (list(:wrappers, "DIALECTO_WRAPPERS") || []).map do |item|
        call, scope = item.split("=", 2)
        {call: call, scope: scope}
      end
    end

    def default_branch = text(:default_branch, "DIALECTO_DEFAULT_BRANCH")

    def paths = list(:paths, "DIALECTO_PATHS")

    # Strings (`*` is a wildcard) or, from Ruby config, Regexps; the environment holds strings only.
    def skip_keys
      configured = option(:skip_keys)
      if configured.is_a?(Array) && !configured.empty?
        return configured.map { |item| item.is_a?(Regexp) ? item : item.to_s.strip }.reject { |item| item == "" }
      end

      list(:skip_keys, "DIALECTO_SKIP_KEYS") || []
    end

    def usages? = flag(:usages, "DIALECTO_USAGES", default: false)

    def require_usages? = flag(:require_usages, "DIALECTO_REQUIRE_USAGES", default: false)

    def enabled? = flag(:enabled, "DIALECTO_IN_CONTEXT", default: true)

    MODES = %i[dev live off].freeze

    # `:dev`, `:live` or `:off` (spec-0025 §4). `default` is what an unset mode means: the Railtie passes
    # `:dev` in development and `:off` everywhere else. Options only: the live settings are public and live in
    # the app's config.
    def mode(default = :off)
      value = option(:mode).to_s.strip.downcase.to_sym
      MODES.include?(value) ? value : default
    end

    # "owner/name": the Dialecto repo editors work on.
    def repo = text(:repo, nil)

    # The site's own origin, normalised like Dialecto stores it, or nil if unset or not a web URL. Never read
    # from a request header, which a proxy can rewrite.
    def origin = self.class.normalize_origin(option(:origin))

    # The repo's `ed25519:` key as 32 raw bytes, or nil.
    def public_key
      value = option(:public_key).to_s.strip
      return nil unless value.start_with?("ed25519:")

      bytes = value.delete_prefix("ed25519:")
      return nil unless bytes.match?(/\A[A-Za-z0-9_-]{43}\z/)

      (bytes.tr("-_", "+/") + "=").unpack1("m0")
    rescue ArgumentError
      nil
    end

    # Live mode has everything it needs: switched on, a repo, an origin and a key.
    def live?(default_mode = :off) = live_problems(default_mode).empty? && mode(default_mode) == :live

    # Why `mode = :live` stays off: what is missing or malformed. Empty when live mode is fine or not asked for.
    def live_problems(default_mode = :off)
      return [] unless mode(default_mode) == :live

      [
        (!enabled? && "the add-on is switched off (enabled = false or DIALECTO_IN_CONTEXT=off)"),
        (repo.nil? && "repo is not set"),
        (origin.nil? && "origin is not set or is not an http(s) origin"),
        (public_key.nil? && "public_key is not set or is not an ed25519:<base64url> key"),
        (!Config.ed25519? && "the openssl gem is older than 3.2, which Ed25519 keys need: add gem \"openssl\", \">= 3.2\" to the Gemfile")
      ].select { |problem| problem }
    end

    # Raw Ed25519 public keys arrived in the openssl gem 3.2; Ruby 3.2 ships 3.1.
    def self.ed25519?
      require "openssl"
      ::OpenSSL::PKey.respond_to?(:new_raw_public_key)
    end

    # For tests: the clock, in Unix seconds, the launch token's times are checked against.
    def clock = option(:clock).respond_to?(:call) ? option(:clock) : -> { Time.now.to_i }

    def self.normalize_origin(url)
      uri = URI.parse(url.to_s.strip)
      return nil unless %w[http https].include?(uri.scheme) && !uri.host.to_s.empty? && (1..65_535).cover?(uri.port.to_i)

      host = uri.host.downcase
      host = "[#{host.delete("[]")}]" if host.include?(":")
      default_port = (uri.scheme == "https") ? 443 : 80
      "#{uri.scheme}://#{host}#{":#{uri.port}" unless uri.port == default_port}"
    rescue URI::InvalidURIError
      nil
    end

    def allow_insecure? = flag(:allow_insecure, "DIALECTO_ALLOW_INSECURE", default: false)

    def url_valid? = http_url? && (https? || loopback_host? || allow_insecure?)

    def https? = uri&.scheme == "https"

    def loopback_host? = uri ? LOOPBACK_HOSTS.include?(uri.host.to_s) : false

    # Why the URL can't carry a token, or nil.
    def url_problem
      return "DIALECTO_URL isn't an http or https URL: #{url.inspect}" unless http_url?
      return nil if url_valid?

      "DIALECTO_URL is plain http on #{uri.host}. The scan token would travel unencrypted: use https, " \
        "or set DIALECTO_ALLOW_INSECURE=1 for a Dialecto on a private network."
    end

    private

    def uri
      @uri ||= begin
        URI.parse(url)
      rescue URI::InvalidURIError
        nil
      end
    end

    def http_url? = !uri.nil? && %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?

    def option(name)
      options[name] if options.key?(name)
    end

    def text(name, var)
      value = option(name)
      value = value.to_s if value.is_a?(Integer)
      blank_to_nil(value.is_a?(String) ? value : nil) || blank_to_nil(env[var])
    end

    def list(name, var)
      value = option(name)
      items =
        case value
        when Array then value.map(&:to_s)
        when String then value.split(",")
        end
      items = env[var].to_s.split(",") if items.nil? || items.all? { |item| item.strip.empty? }
      items = items.map(&:strip).reject(&:empty?)
      items.empty? ? nil : items
    end

    def flag(name, var, default:)
      value = option(name)
      return value if value == true || value == false

      raw = blank_to_nil(env[var])&.downcase
      return false if OFF.include?(raw)
      return true if ON.include?(raw)

      default
    end

    def blank_to_nil(value)
      value = value.to_s.strip
      value.empty? ? nil : value
    end
  end
end
