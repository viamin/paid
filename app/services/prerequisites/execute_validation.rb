# frozen_string_literal: true

module Prerequisites
  # Executes one bounded prerequisite-evidence validation generation inside
  # Paid's real execution infrastructure (#4643).
  #
  # Everything runs through the shipped AgentRun integration surface —
  # `provision_execution_environment`, `execute_in_execution_environment`,
  # `cleanup_execution_environment` — plus the RDR-073 tool-attachment and
  # McpProvisioner contract. No repository or tool code executes on the
  # control plane, no host shell is exposed, and no Docker socket is mounted
  # into the agent (PREREQ-EVIDENCE-003).
  #
  # The executor never resolves the prerequisite notification, closes the
  # owner issue, or mutates paid_state (PREREQ-EVIDENCE-006).
  class ExecuteValidation
    EXECUTE_TIMEOUT_SECONDS = 300
    ENDPOINT_TIMEOUT_SECONDS = 30

    def self.call(...) = new(...).call

    def initialize(validation, capability_report:, provisioner_class: Containers::McpProvisioner,
      git_operations_class: Containers::GitOperations)
      @validation = validation
      @capability_report = capability_report
      @provisioner_class = provisioner_class
      @git_operations_class = git_operations_class
    end

    def call
      # A cancelled validation is never executed, and mark_running!'s
      # conditional update makes a concurrent cancel-win observable here.
      return validation unless validation.mark_running!

      unless capability_report.compatible_host?
        complete_unavailable
        return validation
      end

      run = create_evidence_run
      validation.update!(agent_run: run, capability_snapshot: snapshot)

      begin
        run.provision_execution_environment
        clone_pinned_checkout(run)
        execute_checks(run)
      rescue Cancelled
        checks["tool_sidecar"] ||= skipped_check("Cancelled before the sidecar check ran.")
      rescue StandardError => e
        Rails.logger.error(
          message: "prerequisites.execute_validation.failed",
          prerequisite_validation_id: validation.id,
          agent_run_id: run.id,
          error_class: e.class.name,
          error: e.message
        )
        checks["native_analyzer"] ||= failed_check("Execution environment error: #{e.class} #{e.message}")
        mark_run_failed!(run, e)
      ensure
        # Teardown first so cleanup evidence lands in the same result payload
        # the validation completes with, whichever branch ran.
        teardown_and_capture_cleanup(run)
        complete(run)
      end
    end

    private

    attr_reader :capability_report, :git_operations_class, :provisioner_class, :validation

    def complete_unavailable
      capability_report.host_blockers.each do |blocker|
        validation.record_blocker!(
          check: blocker["check"],
          reason: blocker["reason"],
          authorized_action: blocker["authorized_action"]
        )
      end
      validation.update!(capability_snapshot: snapshot)
      validation.complete!(
        status: "unavailable",
        result: base_result.merge("blockers" => validation.blockers)
      )
      log_completion("unavailable")
      validation
    end

    def create_evidence_run
      AgentRun.create!(
        project: validation.project,
        initiating_user: validation.requested_by,
        agent_type: "internal_agent",
        synthetic: true,
        goal: PrerequisiteValidation::RUN_GOAL,
        external_metadata: {
          "prerequisite_validation_id" => validation.id,
          "issue_id" => validation.issue_id
        },
        custom_prompt: "Capability-aware prerequisite validation ##{validation.id}",
        trigger_type: "manual",
        status: "running",
        started_at: Time.current,
        proxy_token: SecureRandom.hex(32)
      )
    end

    def clone_pinned_checkout(run)
      git_operations_class.new(container_service: run, agent_run: run).clone_and_setup_branch
      run.log!("system", "Prerequisite validation: pinned checkout cloned at #{run.base_commit_sha}")
    end

    def execute_checks(run)
      checks["native_analyzer"] = native_analyzer_check(run)
      raise Cancelled if validation_cancelled?

      checks["tool_sidecar"] = tool_sidecar_check(run)
    end

    def native_analyzer_check(run)
      command = validation.analyzer_command.presence || PrerequisiteValidation::DEFAULT_ANALYZER_COMMAND
      result = run.execute_in_execution_environment(command, timeout: EXECUTE_TIMEOUT_SECONDS, stream: false)
      evidence = evidence_from_result(result).merge(
        "command" => command,
        "status" => result.success? ? "succeeded" : "failed"
      )
      log_run_check(run, "native_analyzer", evidence)
      evidence
    rescue Containers::Provision::Error => e
      failed_check("Native analyzer execution error: #{e.class} #{e.message}")
    end

    # The sidecar check consumes the RDR-073 contract exactly as a normal run
    # does: the rollout flag and image allowlist gate it through the
    # provisioner itself, and every missing policy input is surfaced as a
    # blocker naming the authorized action instead of a bypass
    # (PREREQ-EVIDENCE-004).
    def tool_sidecar_check(run)
      unless validation.include_tool_sidecar?
        return skipped_check("Tool-sidecar interaction was not requested for this validation.")
      end

      unless capability_report.tool_sidecars_enabled?
        return blocked_sidecar(
          "The marketplace_tool_sidecars rollout flag is off for this tenant; the sidecar interaction cannot run.",
          CapabilityReport::FLAG_ENABLE_ACTION
        )
      end

      entry = capability_report.tool_entry
      if entry.blank?
        return blocked_sidecar(
          "No active marketplace entry of entry_type \"tool\" exists for this account.",
          CapabilityReport::TOOL_ENTRY_MISSING_ACTION
        )
      end

      unless capability_report.tool_image_allowed
        return blocked_sidecar(
          "Tool entry #{entry["name"].inspect} image #{capability_report.tool_image.inspect} is not allowlisted.",
          capability_report.tool_image_authorized_action
        )
      end

      provisioned_check(run, entry)
    end

    def blocked_sidecar(reason, authorized_action)
      validation.record_blocker!(check: "tool_sidecar", reason: reason, authorized_action: authorized_action)
      blocked_check(reason, authorized_action)
    end

    def provisioned_check(run, entry)
      MarketplaceEntries::AttachToRun.call(agent_run: run, manual_entry_ids: [ entry["id"] ])
      provisioner_class.new.provision(run)
      run.reload

      endpoints = Array(run.tool_sidecar_endpoints)
      return failed_check("Tool sidecar provisioning recorded no endpoints.") if endpoints.empty?

      endpoint = endpoints.first
      call = run.execute_in_execution_environment(
        endpoint_probe_command(endpoint),
        timeout: ENDPOINT_TIMEOUT_SECONDS,
        stream: false
      )
      evidence = evidence_from_result(call).merge(
        "status" => call.success? ? "succeeded" : "failed",
        "entry" => entry,
        "endpoints" => endpoints
      )
      log_run_check(run, "tool_sidecar", evidence)
      evidence
    rescue Containers::Provision::Error, Containers::McpProvisioner::Error => e
      failed_check("Tool sidecar execution error: #{e.class} #{e.message}")
    end

    def endpoint_probe_command(endpoint)
      "curl -fsS --max-time #{ENDPOINT_TIMEOUT_SECONDS} #{Shellwords.escape(endpoint.fetch('url'))}"
    end

    def teardown_and_capture_cleanup(run)
      sidecars = capture_sidecar_cleanup(run)
      run.cleanup_execution_environment if run.container_id.present?
      checks["cleanup"] = {
        "sidecars" => sidecars,
        "run_container" => run_container_cleanup_evidence(run)
      }
      checks["cleanup"]["status"] = checks["cleanup"].values.all? { |entry| entry.is_a?(Hash) && entry["cleaned"] } ? "succeeded" : "failed"
    rescue StandardError => e
      Rails.logger.warn(
        message: "prerequisites.execute_validation.cleanup_failed",
        prerequisite_validation_id: validation.id,
        agent_run_id: run.id,
        error_class: e.class.name,
        error: e.message
      )
      checks["cleanup"] = { "status" => "failed", "reason" => "#{e.class} #{e.message}" }
    end

    def capture_sidecar_cleanup(run)
      sidecar_ids = Array(run.tool_sidecar_container_ids)
      return { "cleaned" => true, "container_ids" => [] } if sidecar_ids.empty?

      provisioner_class.new.cleanup(run)
      { "cleaned" => Array(run.reload.tool_sidecar_container_ids).empty?, "container_ids" => sidecar_ids }
    end

    def run_container_cleanup_evidence(run)
      container_id = run.container_id
      run.reload
      { "cleaned" => run.container_id.blank?, "container_id" => container_id }
    end

    def complete(run)
      finalize_run!(run)
      validation.complete!(status: overall_status, result: base_result.merge("checks" => checks))
      log_completion(overall_status)
      validation
    end

    def overall_status
      return "cancelled" if validation_cancelled?

      statuses = requested_checks.map { |check| checks.dig(check, "status") }
      return "failed" if statuses.include?("failed")
      return "succeeded" if statuses.compact.all? { |status| status == "succeeded" }
      return "partial" if statuses.include?("succeeded")
      return "blocked" if statuses.compact.all? { |status| status == "blocked" }

      "partial"
    end

    def finalize_run!(run)
      return if run.finished?

      run.update!(
        status: run_status_for_checks,
        completed_at: Time.current,
        duration_seconds: [ (Time.current.to_f - run.started_at.to_f).round, 0 ].max
      )
    end

    def mark_run_failed!(run, error)
      run.update!(status: "failed", error_message: error.message.to_s.truncate(2_000), completed_at: Time.current)
    end

    def run_status_for_checks
      case overall_status
      when "succeeded", "partial", "blocked" then "completed"
      when "cancelled" then "cancelled"
      else "failed"
      end
    end

    def requested_checks
      checks_list = %w[native_analyzer]
      checks_list << "tool_sidecar" if validation.include_tool_sidecar?
      checks_list
    end

    def checks
      @checks ||= {}
    end

    def evidence_from_result(result)
      {
        "stdout" => normalize_output(result[:stdout]),
        "stderr" => normalize_output(result[:stderr]),
        "exit_code" => result[:exit_code]
      }
    end

    def normalize_output(output)
      output.to_s.encode("UTF-8", invalid: :replace, undef: :replace).truncate(PrerequisiteValidation::OUTPUT_BOUND)
    end

    def failed_check(reason)
      { "status" => "failed", "reason" => reason.truncate(PrerequisiteValidation::OUTPUT_BOUND) }
    end

    def blocked_check(reason, authorized_action)
      { "status" => "blocked", "reason" => reason, "authorized_action" => authorized_action }
    end

    def skipped_check(reason)
      { "status" => "skipped", "reason" => reason }
    end

    def log_run_check(run, check, evidence)
      run.log!("system", "Prerequisite validation #{check} #{evidence["status"]}", metadata: {
        event: "prerequisite_validation",
        check: check,
        status: evidence["status"],
        exit_code: evidence["exit_code"]
      })
    end

    def snapshot
      capability_report.to_h.deep_stringify_keys
    end

    def base_result
      {
        "host" => { "compatible" => capability_report.compatible_host, "healthy" => capability_report.healthy_host_identifiers },
        "image" => run_image_identity,
        "checkout" => run_checkout_identity,
        "requested_checks" => requested_checks
      }
    end

    # Image identity comes from the run's own `execution.image_resolved` audit
    # record — the same durable provenance the provisioner writes for every
    # provision — rather than a second resolution path (PREREQ-EVIDENCE-005).
    def run_image_identity
      event = ExecutionAuditEvent.where(
        agent_run_id: validation.agent_run_id,
        event_name: "execution.image_resolved"
      ).order(:id).last
      return {} unless event

      { "reference" => event.image_reference, "digest" => event.image_digest }.compact
    end

    def run_checkout_identity
      run = validation.agent_run
      return {} unless run

      { "base_commit_sha" => run.base_commit_sha, "branch" => run.branch_name }.compact
    end

    def validation_cancelled?
      validation.reload.status == "cancelled"
    end

    def log_completion(status)
      Rails.logger.info(
        message: "prerequisites.execute_validation.completed",
        prerequisite_validation_id: validation.id,
        status: status,
        agent_run_id: validation.agent_run_id
      )
    end

    Cancelled = Class.new(StandardError)
  end
end
