module DialectoRails
  module Usages
    # Where a lazy key (`t(".title")`) is read from decides what it means (spec-0023 §6.4): Rails resolves it
    # from the rendering view, or from a controller's or mailer's action, so the scan derives that context
    # from the file and the class around the call.
    module LazyScope
      VIEW_ROOT = %r{(?:\A|/)app/views/(.+)\z}
      ACTIONS = %w[index show new create edit update destroy].freeze

      module_function

      # `{base:, from:}` for a file under `app/views/`, or nil. `users/_row.html.erb` is `users.row`, a partial.
      def view(path)
        relative = path[VIEW_ROOT, 1]
        return nil unless relative

        *directories, file = relative.split("/")
        name = file.split(".").first.to_s
        partial = name.start_with?("_")
        name = name.delete_prefix("_")
        {base: (directories + [name]).join(".").delete_prefix("."), from: partial ? "partial" : "view"}
      end

      # :controller, :mailer or nil, from a class's own name and its superclass's.
      def kind(class_name, superclass_name)
        names = [class_name, superclass_name].compact
        return :controller if names.any? { |name| name.end_with?("Controller") }
        return :mailer if names.any? { |name| name.end_with?("Mailer") }

        nil
      end

      # `Admin::UsersController` → `admin.users`; `UserMailer` → `user_mailer`.
      def path(constant_path, kind)
        segments = constant_path.split("::").map { |segment| underscore(segment) }
        segments[-1] = segments[-1].delete_suffix("_controller") if kind == :controller
        segments.join(".")
      end

      def underscore(name)
        name.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end

      def action?(kind, method_name, visibility)
        return false unless method_name
        return ACTIONS.include?(method_name) if kind == :controller

        kind == :mailer && visibility == :public
      end
    end
  end
end
