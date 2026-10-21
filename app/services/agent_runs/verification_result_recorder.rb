# frozen_string_literal: true

require "json"
require "open3"
require "pathname"

module AgentRuns
  # @spec LIVE-PREVIEW-005
  class VerificationResultRecorder
    VALID_STATUSES = %w[passed failed skipped not_run].freeze
    MAX_RETAINED_ARTIFACT_BYTES = 512.kilobytes
    LOG_TAIL_LINES = 40
    LOG_TAIL_CHUNK_BYTES = 4096
    LOG_TAIL_MAX_BYTES = 32 * 1024

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, repo_path:, fallback_result: nil, record_missing: true, result_commit: nil, logger: Rails.logger)
      @agent_run = agent_run
      @repo_path = repo_path
      @fallback_result = fallback_result
      @record_missing = record_missing
      @result_commit = result_commit
      @logger = logger
    end

    def call
      apple_decision = AppleVerificationAttempts::GateEnforcement.evaluate(
        agent_run: @agent_run,
        gate: "pull_request_verification",
        result_commit: @result_commit
      )
      # The rollout flag and project mode guard the apple paths; interactive
      # verification only guards the interactive result. Record whenever
      # interactive verification is enabled OR a binding apple decision must
      # be reflected in the PR verification result.
      # @spec APPLE-ATTEMPT-011
      if !@agent_run.project.verification_enabled? && !apple_decision.enforcing?
        clear_apple_only_result
        return
      end
      return if @repo_path.blank?

      persisted = build_result(apple_decision)
      return if persisted.nil?

      @agent_run.update!(verification_result: persisted)
      persisted
    ensure
      cleanup_transient_files
    end

    private

    def build_result(apple_decision)
      payload = interactive_payload(recorded_result || @fallback_result.presence)
      # @spec APPLE-ATTEMPT-011
      # @spec APPLE-ATTEMPT-012
      return apply_apple_gate(payload, apple_decision) if apple_decision.pending? || apple_decision.blocked?

      payload ||= missing_result if @record_missing
      return if payload.nil?

      normalize(payload)
    end

    def apply_apple_gate(payload, decision)
      interactive = payload.is_a?(Hash) && payload["status"].present? ? normalize(payload) : {}
      entry = { "state" => decision.pending? ? "pending" : "blocked", "gate" => decision.gate }
      entry["failure_classification"] = decision.attempt.failure_classification if decision.blocked? && decision.attempt
      entry["interactive_status"] = interactive["status"] if interactive["status"].present?

      interactive.merge(
        "status" => decision.pending? ? "not_run" : "failed",
        "reason" => decision.pending? ? "apple_verification_pending" : "apple_verification_failed",
        "summary" => interactive["summary"].presence || apple_gate_summary(decision),
        "apple_verification" => entry,
        "recorded_at" => Time.current.iso8601
      )
    end

    def interactive_payload(payload)
      apple_result = payload.is_a?(Hash) && payload["apple_verification"]
      return payload unless apple_result.is_a?(Hash) && apple_result["interactive_status"].present?

      payload.except("apple_verification", "reason").merge("status" => apple_result["interactive_status"])
    end

    def clear_apple_only_result
      return unless @agent_run.verification_result["apple_verification"].present?

      @agent_run.update!(verification_result: {})
    end

    def apple_gate_summary(decision)
      if decision.pending?
        "Required Apple verification has not passed for this pull request."
      else
        "Required Apple verification failed for this pull request."
      end
    end

    def recorded_result
      contents = with_safe_repo_file(result_path) { |file| file.read }
      return if contents.nil?

      JSON.parse(contents)
    rescue JSON::ParserError => e
      invalid_json_result(e)
    end

    def normalize(payload)
      hash = payload.is_a?(Hash) ? payload.deep_stringify_keys : {}
      status = hash["status"].to_s
      status = "failed" unless status.in?(VALID_STATUSES)

      {
        "status" => status,
        "reported_status" => status,
        "summary" => hash["summary"].presence || default_summary_for(status),
        "reason" => hash["reason"].presence,
        "details" => hash["details"].presence,
        "app_url" => hash["app_url"].presence,
        "start_command" => hash["start_command"].presence,
        "used_browser_tools" => hash["used_browser_tools"] == true,
        "browser_steps" => normalize_string_array(hash["browser_steps"]),
        "changed_surfaces" => normalize_string_array(hash["changed_surfaces"]),
        "artifacts" => normalize_artifacts(hash["artifacts"]),
        "app_log_tail" => app_log_tail,
        "evidence" => evidence_for(hash),
        "recorded_at" => Time.current.iso8601
      }.compact
    end

    # Agent-authored JSON is a useful report, but it cannot attest to its own
    # browser execution, artifact ownership, or the revision it exercised.
    # Keep those claims separate from recorder-owned facts so consumers do not
    # accidentally treat a reported pass as accepted evidence.
    # @spec LIVE-PREVIEW-010
    def evidence_for(payload)
      {
        "tested_commit" => tested_commit,
        "freshness" => freshness,
        "runtime_configuration" => runtime_configuration,
        "reported_artifact_assessments" => reported_artifact_assessments(payload["artifacts"]),
        "observed_artifacts" => observed_artifacts,
        "coverage" => coverage_for(payload["acceptance_criteria"]),
        "limitations" => evidence_limitations
      }.compact
    end

    def tested_commit
      @result_commit.presence || git_head_sha || @agent_run.result_commit_sha.presence
    end

    def freshness
      return { "state" => "unbound", "reason" => "tested_commit_unavailable" } if tested_commit.blank?
      return { "state" => "stale", "reason" => "result_commit_changed" } if @result_commit.present? && git_head_sha.present? && @result_commit != git_head_sha
      return { "state" => "stale", "reason" => "run_result_commit_changed" } if @agent_run.result_commit_sha.present? && tested_commit != @agent_run.result_commit_sha

      { "state" => "current" }
    end

    def git_head_sha
      value, status = Open3.capture2e("git", "-C", @repo_path, "rev-parse", "HEAD")
      return unless status.success?

      value = value.strip
      value if value.match?(/\A[0-9a-f]{40}\z/)
    rescue StandardError
      nil
    end

    def runtime_configuration
      plan = Screenshots::RuntimePlan.call(project: @agent_run.project, repo_path: @repo_path)
      {
        "base_url" => plan.base_url,
        "framework" => plan.framework.to_s.presence,
        "start_command" => plan.start_command,
        "setup_commands" => Array(plan.setup_commands).first(10),
        "app_port" => plan.app_port,
        "readiness_path" => plan.readiness_path
      }.compact
    rescue Screenshots::ConfigError => error
      { "state" => "incomplete", "reason" => "runtime_configuration_unavailable", "details" => error.message }
    end

    def coverage_for(value)
      Array(value).filter_map do |criterion|
        next unless criterion.is_a?(Hash)

        criterion = criterion.deep_stringify_keys
        id = criterion["id"].to_s.strip
        next if id.blank?

        reported_status = criterion["status"].to_s
        reported_status = "not_run" unless reported_status.in?(VALID_STATUSES)
        {
          "id" => id,
          "reported_status" => reported_status,
          "reported_assertions" => normalize_string_array(criterion["assertions"]),
          "reported_steps" => normalize_string_array(criterion["steps"]),
          "state" => coverage_state(reported_status),
          "reason" => coverage_reason(reported_status)
        }.compact
      end.first(50)
    end

    def coverage_state(status)
      return "not_run" if status == "not_run"
      return "skipped" if status == "skipped"
      return "contradicted" if status == "failed"

      "unverified"
    end

    def coverage_reason(status)
      return "reported_failure" if status == "failed"
      return "reported_skipped" if status == "skipped"
      return "reported_not_run" if status == "not_run"

      "no_recorder_owned_assertion_for_criterion"
    end

    def reported_artifact_assessments(value)
      Array(value).filter_map do |artifact|
        next unless artifact.is_a?(Hash)

        assess_reported_artifact(artifact.deep_stringify_keys)
      end.first(10)
    end

    def assess_reported_artifact(artifact)
      path = artifact["path"].presence
      return { "state" => "untrusted_reference", "kind" => artifact["kind"].presence || "artifact" } if path.blank?

      candidate = repo_path_candidate(path)
      return { "state" => "outside_repo", "kind" => artifact["kind"].presence || "artifact" } unless candidate
      return { "state" => "missing", "kind" => artifact["kind"].presence || "artifact" } unless File.exist?(candidate)

      resolved_path = resolve_repo_path(candidate)
      return { "state" => "outside_repo", "kind" => artifact["kind"].presence || "artifact" } unless resolved_path
      return { "state" => "missing", "kind" => artifact["kind"].presence || "artifact" } unless File.file?(resolved_path)

      { "state" => "present_untrusted", "kind" => artifact["kind"].presence || "artifact", "bytes" => File.size(resolved_path) }
    end

    def repo_path_candidate(path)
      base = Pathname.new(@repo_path).realpath
      candidate = Pathname.new(path).absolute? ? Pathname.new(path) : base.join(path)
      candidate = candidate.cleanpath
      candidate.to_s.start_with?("#{base}/") ? candidate.to_s : nil
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def resolve_repo_path(path)
      base = Pathname.new(@repo_path).realpath
      resolved = Pathname.new(path).realpath
      resolved.to_s.start_with?("#{base}/") ? resolved.to_s : nil
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def observed_artifacts
      return [] unless app_log_present?

      with_safe_repo_file(app_log_path) do |file|
        observed_artifacts_for(file)
      end || [ observed_log_artifact("inaccessible") ]
    rescue ArtifactStorage::StorageError => error
      [ observed_log_artifact("inaccessible", details: error.message) ]
    end

    def observed_artifacts_for(file)
      return [ observed_log_artifact("too_large") ] if file.size > MAX_RETAINED_ARTIFACT_BYTES
      return [ observed_log_artifact("storage_unavailable") ] unless ArtifactStorage.configured?

      retain_app_log(file)
    end

    def retain_app_log(file)
      key = verification_log_key
      ArtifactStorage.new.upload_io(io: file, key: key, content_type: "text/plain")
      [ observed_log_artifact("retained", storage_key: key) ]
    end

    def verification_log_key
      prefix = Screenshots::Storage.namespace_prefix(org: @agent_run.project.owner, repo: @agent_run.project.repo)
      "#{prefix}verification/#{@agent_run.id}/#{tested_commit || "unknown"}/app.log"
    end

    def observed_log_artifact(state, storage_key: nil, details: nil)
      {
        "kind" => "app_log",
        "state" => state,
        "provenance" => "recorder",
        "agent_run_id" => @agent_run.id,
        "project_id" => @agent_run.project_id,
        "account_id" => @agent_run.project.account_id,
        "tested_commit" => tested_commit,
        "storage_key" => storage_key,
        "details" => details
      }.compact
    end

    def evidence_limitations
      [
        "agent_reported_browser_steps_are_not_observed_evidence",
        "screenshots_and_app_logs_do_not_prove_arbitrary_acceptance_criteria"
      ]
    end

    def normalize_string_array(value)
      Array(value).filter_map do |entry|
        text = entry.to_s.strip
        text if text.present?
      end.first(20)
    end

    def normalize_artifacts(value)
      Array(value).filter_map do |artifact|
        next unless artifact.is_a?(Hash)

        normalized = artifact.deep_stringify_keys.slice(
          "lane",
          "kind",
          "path",
          "url",
          "storage_key",
          "content_type",
          "note"
        )
        normalized["locator"] = normalize_nested_hash(artifact["locator"], allowed_keys: %w[key url])
        normalized["context"] = normalize_nested_hash(artifact["context"], allowed_keys: %w[account_id project_id agent_run_id])
        normalized["metadata"] = normalize_metadata_hash(artifact["metadata"])
        normalized.compact!
        normalized.presence
      end.first(10)
    end

    def normalize_nested_hash(value, allowed_keys:)
      return unless value.is_a?(Hash)

      value.deep_stringify_keys.slice(*allowed_keys).presence
    end

    def normalize_metadata_hash(value)
      return unless value.is_a?(Hash)

      ExecutionRunners.json_value(value.deep_stringify_keys).presence
    end

    def invalid_json_result(error)
      {
        "status" => "failed",
        "reason" => "invalid_verification_result_json",
        "summary" => "Verification result file was present but invalid JSON.",
        "details" => error.message
      }
    end

    def missing_result
      {
        "status" => "not_run",
        "reason" => "verification_result_missing",
        "summary" => "Verification was enabled, but no verification result was recorded."
      }
    end

    def default_summary_for(status)
      {
        "passed" => "Interactive verification passed.",
        "failed" => "Interactive verification failed.",
        "skipped" => "Interactive verification was skipped.",
        "not_run" => "Interactive verification did not run."
      }.fetch(status)
    end

    def app_log_tail
      with_safe_repo_file(app_log_path) { |file| read_log_tail(file, max_lines: LOG_TAIL_LINES) }
    rescue StandardError => e
      @logger.warn(
        message: "agent_runs.verification_result.log_tail_failed",
        agent_run_id: @agent_run.id,
        error: e.message
      )
      nil
    end

    def read_log_tail(file, max_lines:)
      buffer = +""
      position = file.size

      while position.positive? && buffer.count("\n") <= max_lines && buffer.bytesize < LOG_TAIL_MAX_BYTES
        read_size = [ LOG_TAIL_CHUNK_BYTES, position ].min
        position -= read_size
        file.seek(position)
        buffer.prepend(file.read(read_size))
      end

      normalize_log_tail(buffer, max_lines:)
    end

    # Agent-authored transient paths are resolved from the opened descriptor,
    # then that same descriptor is used for every read and upload. This
    # prevents a symlink replacement between validation and consumption.
    # @spec LIVE-PREVIEW-010
    def with_safe_repo_file(path)
      File.open(path, File::RDONLY | File::NOFOLLOW) do |file|
        return unless file.stat.file? && path_within_repo?(descriptor_path(file))

        yield file
      end
    rescue Errno::EACCES, Errno::ELOOP, Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    def app_log_present?
      File.lstat(app_log_path)
      true
    rescue Errno::EACCES, Errno::ENOENT, Errno::ENOTDIR
      false
    end

    def descriptor_path(file)
      File.realpath("/proc/self/fd/#{file.fileno}")
    end

    def path_within_repo?(path)
      base = Pathname.new(@repo_path).realpath.to_s
      path.start_with?("#{base}/")
    rescue Errno::EACCES, Errno::ENOENT, Errno::ENOTDIR
      false
    end

    def delete_transient_file(path)
      return unless File.lstat(path).file?
      return unless path_within_repo?(File.realpath(path))

      File.delete(path)
    rescue Errno::EACCES, Errno::ENOENT, Errno::ENOTDIR
      nil
    end

    def normalize_log_tail(content, max_lines:)
      content = content.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
      lines = content.lines.last(max_lines)
      lines.join.presence
    end

    def cleanup_transient_files
      [ result_path, app_log_path, app_pid_path ].each do |path|
        delete_transient_file(path)
      rescue StandardError => e
        @logger.warn(
          message: "agent_runs.verification_result.cleanup_failed",
          agent_run_id: @agent_run.id,
          path: path,
          error: e.message
        )
      end
    end

    def result_path
      File.join(@repo_path, AgentRuns::VerificationPrompt::RESULT_PATH)
    end

    def app_log_path
      File.join(@repo_path, AgentRuns::VerificationPrompt::APP_LOG_PATH)
    end

    def app_pid_path
      File.join(@repo_path, AgentRuns::VerificationPrompt::APP_PID_PATH)
    end
  end
end
