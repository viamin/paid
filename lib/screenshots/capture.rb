# frozen_string_literal: true

begin
  require "capybara"
  require "capybara/cuprite"
rescue LoadError => e
  raise LoadError,
    "#{e.message} — capybara and cuprite are in the :test Gemfile group. " \
    "Run with RAILS_ENV=test or move them to a shared group."
end
require "fileutils"
require_relative "../../app/services/screenshots/capture_targets"

module Screenshots
  # Captures rendered screenshots of changed UI routes using Cuprite (headless Chrome).
  #
  # Intended to run in CI against a booted Rails server with seeded data so
  # reviewers can see actual rendered pages rather than mocks.
  #
  # The Chrome process is provided by a Chrome service container in CI or by
  # a locally installed Chromium on the developer machine.
  #
  # @example
  #   paths = Screenshots::Capture.call(
  #     output_dir: "tmp/screenshots",
  #     changed_files: ["app/views/projects/show.html.erb"]
  #   )
  #   paths # => ["tmp/screenshots/sign_in.png", "tmp/screenshots/dashboard.png", ...]
  class Capture
    SCREENSHOT_WIDTH = 1280
    SCREENSHOT_HEIGHT = 900
    CAPYBARA_REMOTE_PORT = 4001

    def self.call(output_dir: "tmp/screenshots", changed_files: [])
      new(output_dir: output_dir, changed_files: changed_files).call
    end

    def initialize(output_dir:, changed_files:)
      @output_dir = output_dir
      @changed_files = Array(changed_files)
    end

    def call
      FileUtils.mkdir_p(@output_dir)
      register_driver
      setup_capybara

      captured = []
      failures = []
      session = Capybara::Session.new(:paid_screenshots)
      begin
        seed_data = ensure_seed_data!
        targets = Screenshots::CaptureTargets.call(changed_files: @changed_files)

        sign_in(session, seed_data.fetch(:user)) if targets.any?(&:requires_auth)
        targets.each do |target|
          path = target.path(seed_data)
          file_path = File.join(@output_dir, "#{target.slug}.png")
          begin
            session.visit(path)

            if target.requires_auth && session.current_path&.include?("sign_in")
              raise "redirected to sign-in page — authentication may have failed"
            end

            session.save_screenshot(file_path, full: true)
            captured << file_path
            puts "  Captured: #{target.slug} -> #{file_path}"
          rescue StandardError => e
            failures << "#{target.slug} (#{path}): #{e.message}"
          end
        end
      ensure
        session.driver.quit
      end

      raise_capture_error!(failures) if failures.any?

      captured
    end

    private

    def register_driver
      browser_path = ENV["CHROMIUM_PATH"] || find_chrome_binary
      chrome_url = ENV["CHROME_URL"]

      Capybara.register_driver(:paid_screenshots) do |app|
        options = {
          headless: true,
          js_errors: false,
          timeout: 30,
          process_timeout: 60,
          browser_options: {
            "no-sandbox": nil,
            "disable-dev-shm-usage": nil,
            "disable-gpu": nil,
            "disable-software-rasterizer": nil,
            "window-size": "#{SCREENSHOT_WIDTH},#{SCREENSHOT_HEIGHT}"
          }
        }

        options[:browser_path] = browser_path if browser_path
        options[:url] = chrome_url if chrome_url

        Capybara::Cuprite::Driver.new(app, **options)
      end
    end

    def find_chrome_binary
      %w[
        /usr/bin/google-chrome
        /usr/bin/chromium
        /usr/bin/chromium-browser
      ].find { |path| File.exist?(path) }
    end

    def setup_capybara
      Capybara.server = :puma, { Silent: true }
      remote_host = ENV["CAPYBARA_APP_HOST"]

      if ENV["CHROME_URL"].present? && remote_host.blank?
        raise "CAPYBARA_APP_HOST must be set when CHROME_URL is configured"
      end

      if remote_host.present?
        Capybara.server_host = "0.0.0.0"
        Capybara.server_port = CAPYBARA_REMOTE_PORT
        Capybara.app_host = "http://#{remote_host}:#{CAPYBARA_REMOTE_PORT}"
      else
        Capybara.server_host = "127.0.0.1"
      end

      Capybara.default_max_wait_time = 10
    end

    SEED_PASSWORD = "screenshot-password-123"

    def ensure_seed_data!
      account = Account.find_or_create_by!(slug: "screenshot-account") do |a|
        a.name = "Screenshot Account"
      end

      user = User.find_or_initialize_by(email: "screenshot@example.com")
      user.account = account
      user.password = SEED_PASSWORD
      user.password_confirmation = SEED_PASSWORD
      user.save!

      unless user.account_memberships.exists?(account: account)
        user.account_memberships.create!(account: account, role: :owner)
      end

      user.settings.update!(allowed_service_images: [ "postgres:16", "redis:7-alpine", "selenium/standalone-chromium:latest" ])

      github_token = GithubToken.find_or_create_by!(account: account, name: "Screenshot Token") do |token|
        token.created_by = user
        token.token = "ghp_#{'a' * 36}"
        token.scopes = [ "repo" ]
        token.validation_status = "validated"
      end

      project = Project.find_or_create_by!(account: account, github_id: 9_999_999) do |record|
        record.github_token = github_token
        record.created_by = user
        record.name = "Screenshot Project"
        record.owner = "paid"
        record.repo = "screenshots"
        record.default_branch = "main"
        record.poll_interval_seconds = 60
        record.label_mappings = {}
        record.allowed_github_usernames = [ user.email ]
      end

      provider = user.providers.find_or_create_by!(provider_key: "cursor", auth_type: "subscription") do |record|
        record.enabled_for_agent_runs = true
        record.enabled_for_fallback = true
        record.fallback_role = "standard"
        record.config = {}
      end

      service_container = ServiceContainer.find_or_create_by!(account: account, name: "Screenshot Postgres") do |record|
        record.image = "postgres:16"
        record.port = 5432
        record.env = {}
        record.status = "stopped"
      end

      agent_run = project.agent_runs.where(custom_prompt: "Capture screenshot route coverage").first_or_create!(
        agent_type: "codex",
        goal: "create_pr",
        status: "pending"
      )

      prompt = Prompt.find_or_create_by!(account: account, slug: "screenshots.prompt") do |record|
        record.name = "Screenshots Prompt"
        record.category = "coding"
        record.active = true
      end

      current_prompt_version = prompt.current_version || prompt.create_version!(
        template: "Ship {{title}} safely",
        system_prompt: "You are a pragmatic coding assistant.",
        created_by: "screenshots",
        created_by_user: user,
        change_notes: "Initial screenshot seed"
      )

      pending_prompt_version = prompt.prompt_versions.pending_review.order(:id).first || prompt.create_pending_version!(
        template: "Ship {{title}} safely with extra review",
        system_prompt: "You are a pragmatic coding assistant.",
        created_by: "screenshots",
        created_by_user: user,
        change_notes: "Pending screenshot seed",
        parent_version: current_prompt_version
      )

      ab_test = prompt.ab_tests.where(name: "Screenshot A/B Test").first_or_create!(
        control_version: current_prompt_version,
        description: "Representative screenshot coverage",
        status: "draft",
        min_samples_per_variant: 30,
        confidence_threshold: 0.95
      )
      ab_test.ab_test_variants.find_or_create_by!(prompt_version: current_prompt_version) do |record|
        record.is_control = true
      end
      ab_test.ab_test_variants.find_or_create_by!(prompt_version: pending_prompt_version) do |record|
        record.is_control = false
      end

      provider_api_key = user.provider_api_keys.find_or_create_by!(name: "Screenshot OpenAI Key") do |record|
        record.api_service_type = "openai"
        record.api_key = "sk-test-#{'a' * 32}"
      end

      integration_credential = account.integration_credentials.find_or_create_by!(
        name: "Screenshot Claude Credential",
        service_key: "claude"
      ) do |record|
        record.created_by = user
        record.auth_kind = "api_key"
        record.secret = "sk-ant-#{'a' * 24}"
      end

      linear_token = account.linear_tokens.find_or_create_by!(name: "Screenshot Linear Token") do |record|
        record.created_by = user
        record.token = "lin_api_#{'a' * 32}"
        record.validation_status = "validated"
      end

      style_guide = account.style_guides.find_or_create_by!(name: "Screenshot Style Guide") do |record|
        record.project = project
        record.raw_content = "Prefer small methods and explicit tests."
        record.language = "ruby"
        record.active = true
      end

      chat_session = ChatSession.where(account: account, title: "Screenshot Chat").first_or_create!(
        created_by: user,
        project: project,
        provider: provider,
        mode: "workspace",
        status: "active"
      )

      {
        user: user,
        project: project,
        provider: provider,
        github_token: github_token,
        integration_credential: integration_credential,
        linear_token: linear_token,
        provider_api_key: provider_api_key,
        service_container: service_container,
        agent_run: agent_run,
        prompt: prompt,
        pending_prompt_version: pending_prompt_version,
        ab_test: ab_test,
        style_guide: style_guide,
        chat_session: chat_session
      }
    end

    def sign_in(session, user)
      session.visit("/users/sign_in")
      session.fill_in "Email", with: user.email
      session.fill_in "Password", with: SEED_PASSWORD
      session.click_button "Sign in"
    end

    def raise_capture_error!(failures)
      raise "Screenshot capture failed:\n  #{failures.join("\n  ")}"
    end
  end
end
