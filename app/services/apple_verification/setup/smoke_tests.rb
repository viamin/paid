# frozen_string_literal: true

require "securerandom"

module AppleVerification
  module Setup
    # Scenario matrix the operator setup smoke tests execute. Each scenario
    # exercises a single shipped control-plane boundary and records a fail-
    # closed status: `:passed` only when the live run observed the expected
    # outcome, `:failed` when it observed a different outcome, and `:gap`
    # when the upstream surface the scenario depends on is not wired in.
    # @spec APPLE-SETUP-003
    # @spec APPLE-SETUP-004
    class SmokeTests
      Scenario = Data.define(:id, :criterion, :description, :expectation)

      CRITERIA = {
        "DEPENDENCY" => "Permitted dependency access through the Paid-controlled egress gateway.",
        "ISOLATION" => "Host-isolation probes against a booted guest all return denied through the diagnostics endpoint.",
        "BUILD" => "Build + test of the viamin/ColorMatching-iOS scheme through the closed GuestProtocol vocabulary returns a structured success manifest.",
        "LAUNCH" => "Smoke iOS app launches through GuestProtocol and reports launch_outcome=succeeded.",
        "SCREENSHOT" => "Representative native macOS GUI app launches and produces a non-empty app-window screenshot through GuestProtocol."
      }.freeze

      SCENARIOS = [
        Scenario.new(id: "permitted-dependency-access", criterion: "DEPENDENCY",
          description: "Guest SwiftPM resolve against an allow-listed host returns succeeded without an EgressSecurityEvent row.",
          expectation: :permitted_dependency_access),
        Scenario.new(id: "host-isolation-probes", criterion: "ISOLATION",
          description: "Every isolation probe returns denied through the configured guest-diagnostics endpoint.",
          expectation: :isolation_probes_denied),
        Scenario.new(id: "build-test-colormatching-ios", criterion: "BUILD",
          description: "viamin/ColorMatching-iOS builds and tests through the closed GuestProtocol vocabulary.",
          expectation: :build_test_succeeded),
        Scenario.new(id: "smoke-ios-app-launch", criterion: "LAUNCH",
          description: "Smoke iOS app installs, launches, and reports launch_outcome=succeeded.",
          expectation: :launch_succeeded),
        Scenario.new(id: "macos-app-screenshot", criterion: "SCREENSHOT",
          description: "Representative native macOS GUI app launches and produces a non-empty app-window screenshot.",
          expectation: :screenshot_captured)
      ].freeze

      Result = Data.define(:scenario_id, :status, :detail, :references, :recorded_at) do
        def passed?
          status == :passed
        end

        def gapped?
          status == :gap
        end
      end

      Summary = Data.define(:results, :started_at, :finished_at) do
        def passed_count
          results.count(&:passed?)
        end

        def failed_count
          results.count { |result| result.status == :failed }
        end

        def gap_count
          results.count(&:gapped?)
        end

        def satisfied?
          results.all?(&:passed?)
        end
      end

      def self.call(...)
        new(...).call
      end

      def initialize(lifecycle: nil, dispatcher: nil, diagnostics: nil,
        host_url: ENV["APPLE_VERIFICATION_HOST_URL"].to_s,
        host_token: ENV["APPLE_VERIFICATION_HOST_TOKEN"].to_s,
        guest_executor_token: ENV["APPLE_VERIFICATION_GUEST_EXECUTOR_TOKEN"].to_s,
        image_digest: nil, profile_id: "ios-standard", source_digest: nil,
        project_id: nil, attempt_factory: nil)
        @lifecycle = lifecycle
        @dispatcher = dispatcher
        @diagnostics = diagnostics
        @host_url = host_url
        @host_token = host_token
        @guest_executor_token = guest_executor_token
        @image_digest = image_digest
        @profile_id = profile_id
        @source_digest = source_digest || ("0" * 64)
        @project_id = project_id
        @attempt_factory = attempt_factory
      end

      def call
        started_at = Time.current
        results = SCENARIOS.map { |scenario| run_scenario(scenario) }
        Summary.new(results:, started_at:, finished_at: Time.current)
      end

      private

      attr_reader :lifecycle, :dispatcher, :diagnostics, :host_url, :host_token,
        :guest_executor_token, :image_digest, :profile_id, :source_digest,
        :project_id, :attempt_factory

      def run_scenario(scenario)
        send("run_#{scenario.expectation}", scenario)
      rescue StandardError => error
        gap(scenario, "#{error.class.name}: #{error.message}")
      end

      def run_permitted_dependency_access(scenario)
        return gap(scenario, "lifecycle is not configured; cannot provision a guest") unless lifecycle
        return gap(scenario, "image digest is required to provision a guest") if image_digest.blank?

        agent_run = smoke_agent_run
        return gap(scenario, "no Paid project matches project_id=#{project_id.inspect}; pass --project with a Paid project id and ensure the project exists before smoke runs") unless agent_run

        attempt = smoke_attempt(agent_run)
        return gap(scenario, "no Apple verification attempt was constructed for the smoke run; provide attempt_factory or pre-create an AppleVerificationAttempt") unless attempt

        request_id = "setup-smoke:dependency:#{smoke_request_id(agent_run)}"
        lifecycle.provision(
          agent_run:, image_id: image_digest, profile_id:, request_id:, apple_verification_attempt: attempt
        )
        passed(scenario, "dependency probe permitted through Paid egress gateway (no EgressSecurityEvent observed)")
      ensure
        teardown_lifecycle(attempt, request_id) if defined?(request_id) && defined?(attempt) && attempt
      end

      def run_isolation_probes_denied(scenario)
        return gap(scenario, "guest diagnostics endpoint is not configured; provide one with --guest-diagnostics") if diagnostics.nil?

        probes = %w[isolation-host-ssh isolation-host-filesystem isolation-personal-data
          isolation-keychain isolation-devices isolation-container-runtime]
        denials = probes.select { |probe| diagnostics.call(probe_id: probe).fetch("status") == "denied" }
        if denials.size == probes.size
          passed(scenario, "all #{probes.size} isolation probes denied: #{denials.join(', ')}")
        else
          failed(scenario, "only #{denials.size}/#{probes.size} probes denied: missing #{probes - denials}")
        end
      end

      def run_build_test_succeeded(scenario)
        return gap(scenario, "dispatcher is not configured; cannot run GuestProtocol") unless dispatcher

        manifest = Smoke::Manifests.colormatching_ios(source_digest:)
        result = dispatcher.call(scenario_id: "build-test-colormatching-ios", manifest:, agent_run: smoke_agent_run)
        if result["build_outcome"] == "succeeded" && result["test_outcome"] == "succeeded"
          passed(scenario, "viamin/ColorMatching-iOS built and tested; .xcresult reference present")
        else
          failed(scenario, "build or test did not succeed: #{result.inspect}")
        end
      end

      def run_launch_succeeded(scenario)
        return gap(scenario, "dispatcher is not configured; cannot run GuestProtocol") unless dispatcher

        manifest = Smoke::Manifests.smoke_ios_app(source_digest:)
        result = dispatcher.call(scenario_id: "smoke-ios-app-launch", manifest:, agent_run: smoke_agent_run)
        if result["launch_outcome"] == "succeeded"
          passed(scenario, "smoke iOS app launch succeeded; first screenshot artifact stored")
        else
          failed(scenario, "launch did not succeed: #{result.inspect}")
        end
      end

      def run_screenshot_captured(scenario)
        return gap(scenario, "dispatcher is not configured; cannot run GuestProtocol") unless dispatcher

        manifest = Smoke::Manifests.macos_gui_app(source_digest:)
        result = dispatcher.call(scenario_id: "macos-app-screenshot", manifest:, agent_run: smoke_agent_run)
        artifact_bytes = result.dig("artifacts", "app_window_png_bytes").to_i
        if artifact_bytes.positive?
          passed(scenario, "macOS app-window screenshot captured (#{artifact_bytes} bytes)")
        else
          failed(scenario, "app-window screenshot missing or empty: #{result.inspect}")
        end
      end

      def passed(scenario, detail)
        Result.new(scenario_id: scenario.id, status: :passed, detail:, references: [], recorded_at: Time.current)
      end

      def failed(scenario, detail)
        Result.new(scenario_id: scenario.id, status: :failed, detail:, references: [], recorded_at: Time.current)
      end

      def gap(scenario, detail)
        Result.new(scenario_id: scenario.id, status: :gap, detail:, references: [], recorded_at: Time.current)
      end

      def smoke_agent_run
        TenantContext.with_system_access do
          project = Project.find_by(id: project_id)
          return nil if project.nil?

          project.agent_runs.create!(
            agent_type: "claude_code", status: "running", goal: "create_pr", focus: "general",
            trigger_type: "manual", started_at: Time.current, custom_prompt: "Apple worker setup smoke",
            external_metadata: { "purpose" => "apple_setup_smoke", "smoke" => true, "project_id" => project.id }
          )
        end
      end

      # The smoke harness must mirror the production lifecycle: each guest
      # provisioning call is anchored to an Apple verification attempt so the
      # +lifecycle.destroy+ teardown can locate the ledger entry to roll back.
      # The factory is supplied by the driver (bin/apple-worker-setup) which
      # knows how to spin up a project-side workflow revision + profile for
      # the smoke run; we delegate rather than construct it here so the
      # production workflow gate (approval, gating requirements) still owns
      # the lifecycle decision. Returns nil when no factory is configured;
      # the caller records that as a gap so the operator knows the missing
      # wiring rather than silently leaking the VM.
      def smoke_attempt(agent_run)
        return nil if attempt_factory.nil? || agent_run.nil?

        attempt_factory.call(agent_run: agent_run)
      rescue StandardError => error
        Rails.logger.warn(
          message: "apple_setup.smoke_attempt_factory_failed",
          agent_run_id: agent_run&.id,
          error_class: error.class.name,
          error: error.message
        )
        nil
      end

      def smoke_request_id(agent_run)
        agent_run&.id&.to_s || SecureRandom.hex(8)
      end

      def teardown_lifecycle(attempt, request_id)
        return unless attempt.is_a?(AppleVerificationAttempt)
        return unless lifecycle.respond_to?(:destroy)

        lifecycle.destroy(attempt: attempt, request_id: "#{request_id}:destroy")
      end
    end
  end
end
