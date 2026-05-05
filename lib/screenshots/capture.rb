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
  # Chrome is launched locally by Ferrum (via Cuprite). In CI this uses the
  # runner's pre-installed Chrome; locally it finds Chromium via CHROMIUM_PATH
  # or find_chrome_binary. A remote Chrome can be used by setting CHROME_URL
  # and CAPYBARA_APP_HOST.
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
      session = Capybara::Session.new(:paid_screenshots, Capybara.app)
      begin
        seed_data = ensure_seed_data!
        targets = Screenshots::CaptureTargets.call(changed_files: @changed_files)

        # Split targets into unauthenticated and authenticated groups so that
        # guest-only pages (e.g. sign_in) are captured before signing in. Signing
        # in first would cause Devise's require_no_authentication filter to redirect
        # away from the login form.
        unauthenticated_targets, authenticated_targets = targets.partition { |t| !t.requires_auth }

        unauthenticated_targets.each do |target|
          capture_target(session, target, seed_data, captured, failures)
        end

        if authenticated_targets.any?
          sign_in(session, seed_data.fetch(:user))
          authenticated_targets.each do |target|
            capture_target(session, target, seed_data, captured, failures)
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
          js_errors: true,
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
        options[:base_url] = Capybara.app_host if Capybara.app_host

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
      Capybara.app = Rails.application
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
      TenantContext.with_system_access do
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

        # Reuse the default subscription provider created by User#ensure_default_provider
        # (after_create callback) rather than creating a second subscription entry which
        # could conflict with the per-(user, provider_key, auth_type) uniqueness validation.
        provider = user.providers.subscription.first!
        provider.update!(enabled_for_agent_runs: true, enabled_for_fallback: true)

        service_container = ServiceContainer.find_or_create_by!(account: account, name: "Screenshot Postgres") do |record|
          record.image = "postgres:16"
          record.port = 5432
          record.env = {}
          record.status = "stopped"
        end

        mcp_server_definition = McpServerDefinition.find_or_create_by!(account: account, name: "Screenshot MCP Server") do |record|
          record.transport = "stdio"
          record.install_type = "npx"
          record.command = "@modelcontextprotocol/server-filesystem"
        end

        agent_run = project.agent_runs.find_or_initialize_by(custom_prompt: "Capture screenshot route coverage")
        if agent_run.persisted?
          agent_run.agent_run_logs.destroy_all
          agent_run.agent_run_phases.destroy_all
          agent_run.quality_metrics.destroy_all
          agent_run.model_selection&.destroy
          agent_run.created_at = Time.current
        end
        agent_run.assign_attributes(
          agent_type: "codex", goal: "create_pr", status: "queued",
          issue_id: nil, source_pull_request_number: nil,
          temporal_workflow_id: nil, temporal_run_id: nil,
          started_at: nil, completed_at: nil, duration_seconds: nil,
          container_id: nil, service_container_ids: [],
          error_message: nil, pull_request_url: nil, pull_request_number: nil,
          created_issue_url: nil, created_issue_number: nil,
          review_url: nil, review_posted_at: nil,
          result_commit_sha: nil, iterations: 0, cost_cents: 0,
          tokens_input: 0, tokens_output: 0
        )
        agent_run.save!

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

        style_guide = StyleGuide.find_or_create_by!(project: project, name: "Screenshot Style Guide") do |record|
          record.account = account
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

        project_version = ProjectVersion.find_or_create_by!(project: project, commit_sha: "f" * 40) do |record|
          record.branch = "main"
          record.committed_at = 1.day.ago
        end

        collector_run = CollectorRun.find_or_create_by!(project_version: project_version, collector_type: "screenshot_seed") do |record|
          record.status = "completed"
          record.started_at = 5.minutes.ago
          record.completed_at = 4.minutes.ago
          record.duration_ms = 60_000
          record.artifacts_count = 1
        end

        knowledge_artifact = KnowledgeArtifact.find_or_create_by!(
          collector_run: collector_run,
          content_hash: Digest::SHA256.hexdigest("screenshots-seed-artifact")
        ) do |record|
          record.project = project
          record.collector_type = collector_run.collector_type
          record.artifact_type = "route"
          record.scope_path = "config/routes.rb"
          record.identifier = "GET /screenshots"
          record.content = "Screenshot artifact seed"
          record.metadata = { source: "screenshots_seed" }
          record.status = "active"
        end

        KnowledgeChunk.find_or_create_by!(knowledge_artifact: knowledge_artifact, sequence: 0) do |record|
          record.project = project
          record.chunk_type = "definition"
          record.status = "active"
          record.content = "Screenshot artifact chunk seed"
          record.content_hash = Digest::SHA256.hexdigest("screenshots-seed-artifact-chunk")
        end

        KnowledgeRecommendation.find_or_create_by!(project: project, description: "Add database_schema collector") do |record|
          record.recommendation_type = "add_collector"
          record.collector_type = "database_schema"
          record.priority = "high"
          record.status = "pending"
          record.evidence = { reason: "No schema artifacts found" }
        end

        KnowledgeRecommendation.find_or_create_by!(project: project, description: "Remove stale api_docs collector") do |record|
          record.recommendation_type = "remove_collector"
          record.collector_type = "api_docs"
          record.priority = "medium"
          record.status = "pending"
          record.evidence = { reason: "Collector has produced no artifacts in 30 days" }
        end

        WorkflowState.find_or_create_by!(temporal_workflow_id: "github-poll-#{project.id}") do |record|
          record.project = project
          record.workflow_type = "GitHubPollWorkflow"
          record.status = "running"
          record.started_at = 1.hour.ago
        end

        {
          user: user,
          project: project,
          provider: provider,
          github_token: github_token,
          integration_credential: integration_credential,
          linear_token: linear_token,
          provider_api_key: provider_api_key,
          service_container: service_container,
          mcp_server_definition: mcp_server_definition,
          agent_run: agent_run,
          prompt: prompt,
          pending_prompt_version: pending_prompt_version,
          ab_test: ab_test,
          style_guide: style_guide,
          chat_session: chat_session,
          knowledge_artifact: knowledge_artifact
        }
      end
    end

    def capture_target(session, target, seed_data, captured, failures)
      path = target.path(seed_data)
      file_path = File.join(@output_dir, "#{target.slug}.png")
      session.visit(path)
      wait_for_async_content(session)

      if target.requires_auth && session.current_path&.include?("sign_in")
        raise "redirected to sign-in page — authentication may have failed"
      end

      session.save_screenshot(file_path, full: true)
      captured << file_path
      puts "  Captured: #{target.slug} -> #{file_path}"
    rescue StandardError => e
      failures << "#{target.slug} (#{path}): #{e.message}"
    end

    def sign_in(session, user)
      session.visit("/users/sign_in")
      # Use field names (form attribute) rather than visible labels so this
      # continues to work even if the UI copy changes (which is exactly the
      # kind of change this workflow is designed to capture screenshots of).
      session.fill_in "user[email]", with: user.email
      session.fill_in "user[password]", with: SEED_PASSWORD
      session.click_button "commit"
    end

    # Wait for the page to fully render, including lazy-loaded Turbo frames
    # that pages like project_show use for cost snapshots and workflow status.
    def wait_for_async_content(session)
      session.has_no_css?("turbo-frame[busy]", wait: 5)
    end

    def raise_capture_error!(failures)
      raise "Screenshot capture failed:\n  #{failures.join("\n  ")}"
    end
  end
end
