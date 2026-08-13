# frozen_string_literal: true

# Shared host-health-check-with-container-fallback logic for Runners::TestAgent
# and Providers::TestAgent.
#
# Including classes must implement:
#   - #harness_health_check_key  — the harness provider/runner key Symbol to
#       pass to AgentHarness.check_provider
#   - #harness_fallback_log_prefix — log message prefix (e.g. "runners.test_agent")
#   - #harness_fallback_log_context — Hash of extra log attributes (e.g. { runner_key: "codex" })
#
# Including classes must also define:
#   - TIMEOUT constant
#   - #test_project, #build_test_run, #execute_harness_health_check, #process_harness_result
#   - #kilocode_direct_outbound?, #prepare_kilocode_config!, #container_provider_runtime
#   - #normalize_output_text (via OutputSanitizer)
module TestAgentHealthCheckFallback
  private

  def execute_harness_health_check_with_fallback
    process_harness_result(maybe_fallback_harness_result(execute_harness_health_check))
  rescue StandardError => e
    raise unless fallback_to_container_smoke_test?(e.message)

    log_harness_fallback(error_message: e.message, error_class: e.class.name)
    execute_container_smoke_test
  end

  def maybe_fallback_harness_result(result)
    return result unless fallback_to_container_smoke_test?(result[:message], result[:output])

    log_harness_fallback(error_message: [ result[:message], result[:output] ].compact.join("\n"))
    execute_container_smoke_test_raw
  end

  def execute_container_smoke_test_raw
    test_run = build_test_run

    begin
      test_run.with_container do |run|
        executor = Containers::HarnessExecutor.new(run)
        prepare_kilocode_config!(run) if kilocode_direct_outbound?
        AgentHarness.check_provider(
          harness_health_check_key,
          timeout: self.class::TIMEOUT,
          executor: executor,
          provider_runtime: container_provider_runtime
        )
      end
    ensure
      test_run.destroy! if test_run&.persisted?
    end
  end

  # Runs the agent-harness smoke_test contract inside a provisioned container.
  #
  # Instead of building provider-specific CLI commands locally, this delegates
  # to the harness provider's smoke_test method with a container-backed executor.
  def execute_container_smoke_test
    process_harness_result(execute_container_smoke_test_raw)
  end

  def fallback_to_container_smoke_test?(*messages)
    return false unless test_project

    combined = messages.compact.map { |message| normalize_output_text(message) }.join("\n")
    return false if combined.blank?

    combined.match?(/permission denied \(os error 13\)/i) ||
      combined.match?(/sandbox failure detected/i) ||
      combined.match?(/bwrap:.*permission denied/i)
  end

  def log_harness_fallback(error_message:, error_class: nil)
    Rails.logger.warn(
      message: "#{harness_fallback_log_prefix}.host_health_check_fallback",
      **harness_fallback_log_context,
      error_class: error_class,
      error_message: normalize_output_text(error_message)
    )
  end
end
