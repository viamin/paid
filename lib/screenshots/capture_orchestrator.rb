# frozen_string_literal: true

require "fileutils"
require "ostruct"
require_relative "../../app/services/screenshots/configuration"
require_relative "driver/base"
require_relative "driver/cuprite"
require_relative "driver/playwright"
require_relative "seed_runner"
require_relative "setup_runner"

module Screenshots
  class CaptureOrchestrator
    CaptureResult = ::Data.define(:name, :path, :success, :error)
    RunResult = ::Data.define(:captures, :failures) do
      def paths
        captures.select(&:success).map(&:path)
      end
    end

    ResolvedRoute = ::Data.define(:name, :path, :requires_auth)

    def self.call(output_dir:, repo_path: Rails.root.to_s, project: nil, config: nil, targets: nil)
      new(output_dir:, repo_path:, project:, config:, targets:).call
    end

    def initialize(output_dir:, repo_path:, project:, config:, targets:)
      @output_dir = output_dir
      @repo_path = repo_path
      @project = project
      @config = config
      @targets = Array(targets)
    end

    def call
      FileUtils.mkdir_p(output_dir)

      setup_runner.call(commands: config.setup_commands, repo_path:)
      seed_data = seed_runner.call(config:, repo_path:, driver_name: config.driver)
      routes = resolve_routes(seed_data)

      capture_results = []
      driver.start_browser

      capture_partition(routes, requires_auth: false, capture_results:)

      authenticated_routes = routes.select(&:requires_auth)
      if authenticated_routes.any? && config.auth.strategy != "none"
        driver.authenticate(auth_config: resolved_auth_config(seed_data))
      end
      capture_partition(authenticated_routes, requires_auth: true, capture_results:)

      RunResult.new(
        captures: capture_results.freeze,
        failures: capture_results.reject(&:success).map { |result| result.error }.freeze
      )
    ensure
      driver.quit if defined?(@driver) && @driver
    end

    private

    attr_reader :output_dir, :repo_path, :project

    def config
      @config ||= Screenshots::ConfigParser.from_repo_path(repo_path, project:)
    end

    def driver
      @driver ||= begin
        driver_class = case config.driver
        when "cuprite" then Screenshots::Driver::Cuprite
        when "playwright" then Screenshots::Driver::Playwright
        else
          raise ArgumentError, "Unsupported screenshot driver: #{config.driver}"
        end

        driver_class.new(config:, repo_path:)
      end
    end

    def setup_runner
      @setup_runner ||= Screenshots::SetupRunner.new
    end

    def seed_runner
      @seed_runner ||= Screenshots::SeedRunner.new
    end

    def resolve_routes(seed_data)
      return resolve_legacy_targets(seed_data) if @targets.any?

      config.routes.map do |route|
        ResolvedRoute.new(
          name: route.name,
          path: interpolate(route.path, seed_data, route.seed_key),
          requires_auth: route.requires_auth
        )
      end
    end

    def resolve_legacy_targets(seed_data)
      @targets.map do |target|
        ResolvedRoute.new(
          name: target.slug,
          path: target.path(seed_data),
          requires_auth: target.requires_auth
        )
      end
    end

    def capture_partition(routes, requires_auth:, capture_results:)
      routes.each do |route|
        next if route.requires_auth != requires_auth

        file_path = File.join(output_dir, "#{route.name}.png")
        driver.visit(route.path)
        driver.wait_for_load

        if route.requires_auth && driver.current_path&.include?("sign_in")
          raise "redirected to sign-in page — authentication may have failed"
        end

        driver.screenshot(name: route.name, path: file_path)
        capture_results << CaptureResult.new(route.name, file_path, true, nil)
      rescue StandardError => e
        capture_results << CaptureResult.new(route.name, file_path, false, "#{route.name} (#{route.path}): #{e.message}")
      end
    end

    def resolved_auth_config(seed_data)
      Screenshots::Configuration::Auth.new(
        strategy: config.auth.strategy,
        login_path: interpolate(config.auth.login_path, seed_data),
        fields: config.auth.fields,
        credentials: config.auth.credentials.transform_values { |value| interpolate(value, seed_data) }.freeze
      )
    end

    def interpolate(template, seed_data, seed_key = nil)
      return template unless template.is_a?(String)

      values = interpolation_values(seed_data, seed_key)
      template.gsub(/:\w+/) do |match|
        values.fetch(match.delete_prefix(":")) { match }
      end % values.symbolize_keys
    rescue KeyError => e
      raise KeyError, "Missing screenshot seed value #{e.message} for #{template.inspect}"
    end

    def interpolation_values(seed_data, seed_key)
      values = seed_data.each_with_object({}) do |(key, record), acc|
        next unless record.respond_to?(:to_h)

        record.to_h.each do |attribute, value|
          acc["#{key}_#{attribute}"] = value
        end
        acc[key.to_s] = record.id if record.respond_to?(:id)
        acc["#{key}_id"] = record.id if record.respond_to?(:id)
      end

      if seed_key.present? && !values.key?("#{seed_key}_id")
        raise KeyError, "Missing seed record #{seed_key.inspect}"
      end

      values
    end
  end
end
