# frozen_string_literal: true

require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Opt into RubyLLM's new acts_as mode before ActiveRecord loads. The gem's
# railtie reads this flag from an `on_load :active_record` hook that fires
# during the railtie phase (before config/initializers), and emits a per-boot
# deprecation warning when it is false. We use RubyLLM only for model-catalog
# data (app/services/models/*), never its acts_as ActiveRecord API, so enabling
# the new mode is inert beyond silencing that warning across every CLI/process.
RubyLLM.configure do |config|
  config.use_new_acts_as = true
end

# Loaded via require_relative because the middleware must be registered before
# Zeitwerk autoloading is available. The middleware is stateless so the pinned
# constant is a low-risk trade-off; use to_prepare for install! re-subscription.
require_relative "../app/services/database/query_monitor"
require_relative "../app/middleware/previews_proxy"

module Paid
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    if ENV["RAILS_ENV"] == "test" && ENV["RAILS_TEST_KEY"].to_s.empty? && ENV["RAILS_MASTER_KEY"].to_s.empty?
      # Rails 8's Active Record encryption initializer always probes
      # app.credentials at boot. Point test runs without credential keys at an
      # intentionally absent encrypted file so isolated environments can boot
      # with empty credentials instead of failing during decryption.
      config.credentials.content_path = Pathname.new(File.expand_path("credentials/.missing-test.yml.enc", __dir__))
      config.credentials.key_path = Pathname.new(File.expand_path("credentials/.missing-test.key", __dir__))
    end

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    config.time_zone = "Pacific Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil
    config.active_record.schema_format = :ruby

    # App-level configurable settings (ENV fallbacks for deployment flexibility)
    config.x.workspace_root = ENV.fetch("WORKSPACE_ROOT", "/var/paid/workspaces")
    config.x.paid_proxy_port = Integer(ENV.fetch("PAID_PROXY_PORT", "3000"))

    # Use GoodJob for background jobs across environments.
    config.active_job.queue_adapter = :good_job

    config.middleware.use Database::QueryMonitor::Middleware
    config.middleware.use PreviewsProxy
  end
end
