module DialectoRails
  module InContext
    # In development, lets the overlay's origin through the app's own Content-Security-Policy (spec-0023
    # §7.6): the origin is appended to the directives the policy already defines, or to `default-src` when it
    # defines none of them. Only ever called after the development guard.
    module Csp
      DIRECTIVES = %w[script-src frame-src connect-src img-src style-src font-src].freeze

      module_function

      def allow(policy, origin)
        return unless policy.respond_to?(:directives)

        directives = policy.directives
        present = DIRECTIVES.select { |name| directives.key?(name) }
        if present.empty?
          add(policy, "default-src", origin) if directives.key?("default-src")
        else
          present.each { |name| add(policy, name, origin) }
        end
      end

      # Live mode: the same idea for one response's header text rather than the app's policy object, and only
      # for frames, since the overlay comes from the site's own origin. `frame-src`, else `child-src`, else
      # `default-src` governs frames; a policy with none of them lets frames through already. The browser
      # enforces every policy, so several (an Array, or values joined by newlines) are widened one by one.
      def widen_frame_src(header, origin)
        return header.map { |policy| widen_frame_src(policy, origin) } if header.is_a?(Array)

        policies = header.to_s.split("\n")
        return policies.map { |policy| widen_frame_src(policy, origin) }.join("\n") if policies.size > 1

        directives = header.to_s.split(";").map(&:strip).reject(&:empty?)
        found = %w[frame-src child-src default-src].lazy.filter_map do |name|
          directives.find { |directive| directive.split(/\s+/).first.downcase == name }
        end.first
        return header unless found

        name, *sources = found.split(/\s+/)
        sources = sources.reject { |source| source.casecmp?("'none'") }
        sources << origin unless sources.include?(origin)
        widened = (["frame-src"] + sources).join(" ")
        return directives.map { |directive| directive.equal?(found) ? widened : directive }.join("; ") if name.casecmp?("frame-src")

        (directives + [widened]).join("; ")
      end

      # Live mode: the nonce a script needs. A browser takes it from `script-src-elem`, else `script-src`, else
      # `default-src`, and a nonce in `style-src` or elsewhere does not allow a script. `header` is the
      # `content-security-policy` value: one policy, several joined by newlines, or an array of them. The first
      # policy whose governing directive has a nonce wins.
      def script_nonce(header)
        Array(header).flat_map { |value| value.to_s.split("\n") }.each do |policy|
          directives = policy.split(";").map(&:strip).reject(&:empty?)
          governing = %w[script-src-elem script-src default-src].lazy.filter_map do |name|
            directives.find { |directive| directive.split(/\s+/).first.downcase == name }
          end.first
          nonce = governing && governing[/'nonce-([A-Za-z0-9+\/=_-]+)'/, 1]
          return nonce if nonce
        end
        nil
      end

      def add(policy, name, origin)
        sources = Array(policy.directives[name]).reject { |source| source == "'none'" }
        return if sources.include?(origin)

        policy.public_send(name.tr("-", "_"), *sources, origin)
      end
    end
  end
end
