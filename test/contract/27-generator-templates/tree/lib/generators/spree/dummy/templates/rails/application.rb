require File.expand_path('../boot', __FILE__)

module <%= app_name.camelize %>
  class Application < Rails::Application
    config.i18n.default_locale = :<%= locale %>
    I18n.t("generators.never_read")
  end
end
