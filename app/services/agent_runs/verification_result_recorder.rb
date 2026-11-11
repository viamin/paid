# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "digest"

module AgentRuns
  # @spec LIVE-PREVIEW-005 LIVE-PREVIEW-011 LIVE-PREVIEW-013
  class VerificationResultRecorder
    VALID_STATUSES = %w[passed failed skipped not_run].freeze
    MAX_RETAINED_ARTIFACT_BYTES = 512.kilobytes
    LOG_TAIL_LINES = 40
    LOG_TAIL_CHUNK_BYTES = 4096
    LOG_TAIL_MAX_BYTES = ApplicationLog::MAX_BYTES
    MAX_CRITERION_INPUTS = 20
    MAX_REPOSITORY_INPUT_VALIDATIONS = 100
    MAX_INPUT_EXCERPT_BYTES = 2_000
    GIT_SHA = /\A[0-9a-f]{40}\z/i
    SHA256_DIGEST = /\A[0-9a-f]{64}\z/i
    # Agent-supplied criterion inputs. Every field is bounded before it is
    # persisted, and the free-text fields are redacted as well.
    INPUT_FIELDS = %w[type locator path revision digest excerpt result command storage_key url reason].freeze
    REDACTED_INPUT_FIELDS = %w[excerpt command locator reason result url].freeze
    # The receipt repeats the checked identity and the mechanical verdict. The
    # bulky agent excerpt stays with the reported claim it came from.
    RECEIPT_REFERENCE_FIELDS = (INPUT_FIELDS - %w[excerpt]).freeze

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
      # The rollout flag and project mode guard the apple paths. Criterion
      # evidence is always recorded for issue implementation runs; interactive
      # verification only guards browser-specific evidence.
      # @spec APPLE-ATTEMPT-011
      unless evidence_recording_applicable?(apple_decision)
        clear_apple_only_result
        return
      end
      return if @repo_path.blank?

      persisted = build_result(apple_decision)
      return if persisted.nil?

      @agent_run.with_lock do
        @previous_verification_result = nil
        persisted = merge_captured_log(persisted)
        @agent_run.update!(verification_result: persisted)
        persisted
      end
    ensure
      cleanup_transient_files
    end

    private

    def evidence_recording_applicable?(apple_decision)
      interactive_verification? || issue_implementation? || apple_decision.enforcing?
    end

    def interactive_verification?
      @agent_run.verification_applicable?
    end

    def issue_implementation?
      @agent_run.create_pr_goal? && @agent_run.issue_id.present?
    end

    def build_result(apple_decision)
      payload = recorded_result || @fallback_result.presence
      apple_only_result = apple_only_result?(payload)
      payload = nil if apple_only_result && !apple_decision.enforcing?
      payload = interactive_payload(payload)
      # @spec APPLE-ATTEMPT-011
      # @spec APPLE-ATTEMPT-012
      return apply_apple_gate(payload, apple_decision) if apple_decision.pending? || apple_decision.blocked?

      payload ||= missing_result if @record_missing || apple_only_result
      return if payload.nil?

      normalize(payload)
    end

    # A prior Apple gate result has no criterion evidence of its own. Once the
    # gate no longer enforces, replace it with an explicit missing result rather
    # than retaining its stale pending reason or silently clearing the run.
    # @spec APPLE-ATTEMPT-011 LIVE-PREVIEW-011
    def apple_only_result?(payload)
      return false unless payload.is_a?(Hash) && payload["apple_verification"].present?
      return false if payload.dig("apple_verification", "interactive_status").present?

      payload.dig("evidence", "coverage").blank? && payload["reported_acceptance_criteria"].blank?
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

    def merge_captured_log(hash)
      return hash unless interactive_verification?

      tail = captured_log_tail
      return hash if tail.blank?

      hash.merge(
        "app_log_tail" => tail,
        "app_log_recorded_at" => previous_verification_result["app_log_recorded_at"] || Time.current.iso8601,
        "app_log_truncated" => previous_verification_result.fetch("app_log_truncated", false)
      )
    end

    def interactive_payload(payload)
      apple_result = payload.is_a?(Hash) && payload["apple_verification"]
      return payload unless apple_result.is_a?(Hash) && apple_result["interactive_status"].present?

      payload.except("apple_verification", "reason").merge("status" => apple_result["interactive_status"])
    end

    def clear_apple_only_result
      @agent_run.with_lock do
        next unless @agent_run.verification_result["apple_verification"].present?

        @agent_run.update!(verification_result: {})
      end
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

      result = {
        "status" => status,
        "reported_status" => status,
        "summary" => hash["summary"].presence || default_summary_for(status),
        "reason" => hash["reason"].presence,
        "details" => hash["details"].presence,
        "reported_acceptance_criteria" => normalize_criteria(hash["acceptance_criteria"] || hash["reported_acceptance_criteria"]),
        "artifacts" => normalize_artifacts(hash["artifacts"]),
        "evidence" => evidence_for(hash),
        "recorded_at" => Time.current.iso8601
      }.compact
      result.merge!(interactive_result_fields(hash)) if interactive_verification?
      add_readiness_observation(result)
    end

    def interactive_result_fields(hash)
      recorder_log = app_log_tail
      fields = {
        "app_url" => hash["app_url"].presence,
        "start_command" => hash["start_command"].presence,
        "used_browser_tools" => hash["used_browser_tools"] == true,
        "browser_steps" => normalize_string_array(hash["browser_steps"]),
        "changed_surfaces" => normalize_string_array(hash["changed_surfaces"])
      }.compact
      return fields if recorder_log[:content].blank?

      fields.merge(
        "app_log_tail" => recorder_log[:content],
        "app_log_recorded_at" => Time.current.iso8601,
        "app_log_truncated" => log_truncated(recorder_log[:truncated])
      )
    end

    def captured_log_tail
      previous_verification_result["app_log_tail"].presence
    end

    # When the recorder produced the tail it knows exactly whether the read
    # hit a cap. When we fall back to the agent-captured tail the only honest
    # answer is the marker the agent capture stored — if it stored one.
    def log_truncated(recorder_truncated)
      recorder_truncated
    end

    def previous_verification_result
      @previous_verification_result ||= @agent_run.verification_result.to_h
    end

    # Agent-authored JSON is a useful report, but it cannot attest to its own
    # browser execution, artifact ownership, or the revision it exercised.
    # Keep those claims separate from recorder-owned facts so consumers do not
    # accidentally treat a reported pass as accepted evidence.
    # @spec LIVE-PREVIEW-010
    def evidence_for(payload)
      @current_observed_artifacts = interactive_verification? ? observed_artifacts : []
      # The pilot metric covers receipt validation only. Artifact retention is
      # measured by the storage layer, not by the receipt validator.
      @receipt_validation_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      coverage = coverage_for(payload["acceptance_criteria"] || payload["reported_acceptance_criteria"])
      evidence = {
        "tested_commit" => tested_commit,
        "freshness" => freshness,
        "reported_artifact_assessments" => reported_artifact_assessments(payload["artifacts"]),
        "coverage" => coverage,
        "criterion_receipt_pilot" => criterion_receipt_pilot(coverage),
        "limitations" => evidence_limitations
      }.compact
      return evidence unless interactive_verification?

      evidence.merge(
        "runtime_configuration" => runtime_configuration,
        "observed_artifacts" => @current_observed_artifacts
      )
    end

    # The reviewed revision is resolved once per recording: every criterion
    # input, the freshness check, and the artifact key must agree on it, and
    # each `git` fork costs a process spawn.
    def tested_commit
      return @tested_commit if defined?(@tested_commit)

      @tested_commit = @result_commit.presence || git_head_sha || @agent_run.result_commit_sha.presence
    end

    def freshness
      return { "state" => "unbound", "reason" => "tested_commit_unavailable" } if tested_commit.blank?
      return { "state" => "stale", "reason" => "run_result_commit_changed" } if @agent_run.result_commit_sha.present? && tested_commit != @agent_run.result_commit_sha
      return { "state" => "stale", "reason" => "result_commit_changed" } if @result_commit.present? && git_head_sha.present? && @result_commit != git_head_sha

      { "state" => "current" }
    end

    def git_head_sha
      return @git_head_sha if defined?(@git_head_sha)

      @git_head_sha = read_git_head_sha
    end

    def read_git_head_sha
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
        reported_verification = normalize_criterion_verification(criterion["verification"])
        {
          "id" => id,
          "reported_status" => reported_status,
          "reported_assertions" => normalize_criterion_text_array(criterion["assertions"]),
          "reported_steps" => normalize_criterion_text_array(criterion["steps"]),
          "reported_verification" => reported_verification,
          "input_receipt" => criterion_input_receipt(reported_verification),
          "state" => coverage_state(reported_status),
          "reason" => coverage_reason(reported_status)
        }.compact
      end.first(50)
    end

    def normalize_criteria(value)
      Array(value).filter_map do |criterion|
        next unless criterion.is_a?(Hash)

        criterion.deep_stringify_keys.slice("id", "status", "assertions", "steps", "verification").then do |normalized|
          normalized["assertions"] = normalize_criterion_text_array(normalized["assertions"]) if normalized.key?("assertions")
          normalized["steps"] = normalize_criterion_text_array(normalized["steps"]) if normalized.key?("steps")
          normalized["verification"] = normalize_criterion_verification(normalized["verification"])
          normalized.presence
        end
      end.first(50)
    end

    # Criterion references are agent-reported claims. Preserve their structured
    # locator/result form for review without deriving coverage from their text.
    # @spec LIVE-PREVIEW-011
    def normalize_criterion_verification(value)
      return unless value.is_a?(Hash)

      verification = value.deep_stringify_keys.slice("kind", "reason").each_with_object({}) do |(key, entry), bounded|
        bounded[key] = redact_input_excerpt(entry) if entry.is_a?(String)
      end
      verification["rationale"] = redact_input_excerpt(value["rationale"] || value[:rationale])
      verification["limitations"] = normalize_criterion_limitations(value["limitations"] || value[:limitations])
      verification["references"] = Array(value["references"] || value[:references]).filter_map do |reference|
        next unless reference.is_a?(Hash)

        normalize_criterion_reference(reference)
      end.first(20).presence
      verification["inputs"] = Array(value["inputs"] || value[:inputs]).first(MAX_CRITERION_INPUTS).filter_map do |input|
        normalize_criterion_input(input)
      end.presence
      verification.compact.presence
    end

    # Agent prose is untrusted: bound and redact it before it is persisted.
    def normalize_criterion_limitations(value)
      Array(value).filter_map { |limitation| redact_input_excerpt(limitation) }.first(20).presence
    end

    # A reported reference stays a reported claim, but its text is bounded and
    # redacted like every other agent-supplied string.
    def normalize_criterion_reference(reference)
      reference.deep_stringify_keys.slice("locator", "result", "reason", "url").each_with_object({}) do |(key, entry), bounded|
        bounded[key] = bounded_input_value(key, entry)
      end.presence
    end

    # Input receipts validate bounded mechanical facts only. They deliberately
    # leave the agent's semantic conclusion in the reported coverage state.
    # The receipt carries the checked identity and the mechanical verdict; the
    # agent's rationale, limitations, and excerpts stay with the reported
    # claim, where they are already bounded and redacted.
    # @spec LIVE-PREVIEW-013
    def criterion_input_receipt(reported_verification)
      return unless reported_verification.is_a?(Hash) && reported_verification["rationale"].present?

      inputs = Array(reported_verification["inputs"])
      return { "state" => "unavailable", "verdict_reason" => "no_bounded_inputs" } if inputs.empty?

      references = inputs.map { |input| verify_criterion_input(input) }
      state = receipt_state(references.map { |reference| reference["state"] })
      { "state" => state, "references" => references }.compact
    end

    def criterion_receipt_pilot(coverage)
      receipts = coverage.filter_map { |criterion| criterion["input_receipt"] }
      references = receipts.flat_map { |receipt| Array(receipt["references"]) }
      {
        "false_claims_caught" => references.count { |reference| reference["state"] == "contradicted" },
        "valid_claims_rejected" => { "state" => "unavailable", "reason" => "requires_human_adjudication" },
        "validation_runtime_ms" => elapsed_receipt_validation_ms,
        "storage_bytes" => receipts.sum { |receipt| JSON.generate(receipt).bytesize },
        "review_usefulness" => { "state" => "unavailable", "reason" => "requires_reviewer_feedback" }
      }
    end

    def elapsed_receipt_validation_ms
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @receipt_validation_started_at) * 1000).round
    end

    # Every agent-supplied field is bounded before it is persisted, and the
    # free-text fields are redacted as well.
    def normalize_criterion_input(input)
      return unless input.is_a?(Hash)

      value = input.deep_stringify_keys.slice(*INPUT_FIELDS).each_with_object({}) do |(key, entry), bounded|
        bounded[key] = bounded_input_value(key, entry)
      end
      value.compact.presence
    end

    def bounded_input_value(key, entry)
      return unless entry.is_a?(String)
      return redact_input_excerpt(entry) if REDACTED_INPUT_FIELDS.include?(key)

      truncate_input_text(entry)
    end

    def redact_input_excerpt(value)
      text = truncate_input_text(value.to_s)
      return if text.blank?

      ApplicationLog.redact_and_bound(text, agent_run: @agent_run).content
    end

    # Truncating on a byte boundary can split a multi-byte character. Scrub the
    # result before any string inspection so an invalid sequence cannot raise.
    def truncate_input_text(text)
      text.to_s.byteslice(0, MAX_INPUT_EXCERPT_BYTES).force_encoding(Encoding::UTF_8).scrub("")
    end

    # @spec LIVE-PREVIEW-013
    def verify_criterion_input(input)
      state, reason = input_verdict(input)
      reference = input.slice(*RECEIPT_REFERENCE_FIELDS).merge("state" => state)
      reference["verdict_reason"] = reason if reason.present?
      reference["provenance"] = "recorder" if state == "verified" && input["type"] == "artifact"
      reference
    end

    # Paid validates only what it can check itself. A cited test execution and
    # an external reference are agent reports, so they stay unavailable
    # evidence rather than a recorder-owned verdict.
    def input_verdict(input)
      case input["type"]
      when "repository_file" then repository_input_verdict(input)
      when "artifact" then artifact_input_verdict(input)
      when "human_or_external" then [ "unavailable", "external_evidence_not_recorder_owned" ]
      else [ "unavailable", "unsupported_input_type" ]
      end
    end

    def repository_input_verdict(input)
      return [ "unavailable", "repository_input_incomplete" ] if input.values_at("path", "revision", "digest").any?(&:blank?)
      return [ "unavailable", "reviewed_revision_unavailable" ] if tested_commit.blank?
      return [ "unavailable", "repository_revision_invalid" ] unless input["revision"].match?(GIT_SHA)
      return [ "unavailable", "repository_digest_invalid" ] unless input["digest"].match?(SHA256_DIGEST)

      revision = input["revision"].downcase
      expected_digest = input["digest"].downcase
      return [ "stale", "revision_does_not_match_reviewed_head" ] unless revision == tested_commit.downcase

      path = repo_path_candidate(input["path"])
      return [ "contradicted", "path_outside_repository" ] unless path
      relative_path = Pathname.new(path).relative_path_from(repo_base).to_s
      digest = repository_blob_digest(revision, relative_path)
      return [ "unavailable", "repository_validation_limit_exceeded" ] if digest == :validation_limit_exceeded
      return [ "contradicted", "path_missing_or_inaccessible" ] if digest.blank?

      return [ "contradicted", "content_digest_mismatch" ] unless ActiveSupport::SecurityUtils.secure_compare(digest, expected_digest)

      [ "verified", nil ]
    rescue Errno::EACCES
      [ "unavailable", "path_inaccessible" ]
    rescue Errno::ENOENT
      [ "contradicted", "path_missing_or_inaccessible" ]
    end

    def repository_blob_digest(revision, relative_path)
      key = [ revision, relative_path ]
      # The recorder instance handles one result, which bounds the cache's
      # lifetime and invalidates it before another result can be recorded.
      cache = (@repository_blob_digests ||= {})
      return cache[key] if cache.key?(key)
      return :validation_limit_exceeded if cache.size >= MAX_REPOSITORY_INPUT_VALIDATIONS

      cache[key] = read_repository_blob_digest(revision, relative_path)
    end

    def read_repository_blob_digest(revision, relative_path)
      digest = Digest::SHA256.new
      status = nil
      Open3.popen2e("git", "-C", @repo_path, "show", "#{revision}:#{relative_path}") do |stdin, output, wait_thread|
        stdin.close
        digest.update(output.read(16.kilobytes)) until output.eof?
        status = wait_thread.value
      end
      digest.hexdigest if status.success?
    rescue SystemCallError
      nil
    end

    # A recorder-owned artifact is cited by the path the agent wrote (the
    # run-owned application log) or by the storage key the recorder chose.
    # Both are matched against the artifacts this recorder retained.
    def artifact_input_verdict(input)
      identity = cited_artifact_identity(input)
      return [ "unavailable", "artifact_identity_missing" ] if identity.blank?

      observed = recorder_observed_artifacts.find { |artifact| artifact_identity_matches?(artifact, identity) }
      return [ "unavailable", "artifact_not_recorder_owned" ] unless observed
      return [ "contradicted", "artifact_not_retained" ] unless observed["state"] == "retained"
      return [ "unavailable", "artifact_revision_unavailable" ] if observed["tested_commit"].blank? || tested_commit.blank?
      unless observed["tested_commit"].casecmp?(tested_commit)
        return [ "stale", "artifact_revision_does_not_match_reviewed_head" ]
      end

      [ "verified", nil ]
    end

    def recorder_observed_artifacts
      @current_observed_artifacts.presence || Array(previous_verification_result.dig("evidence", "observed_artifacts"))
    end

    def cited_artifact_identity(input)
      {
        "path" => repo_relative_path(input["path"]),
        "storage_key" => input["storage_key"].to_s.strip.presence
      }.compact
    end

    def artifact_identity_matches?(artifact, identity)
      identity.all? { |field, value| artifact[field] == value }
    end

    def receipt_state(states)
      return "contradicted" if states.include?("contradicted")
      return "stale" if states.include?("stale")
      return "unavailable" if states.include?("unavailable")

      "verified"
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

    def repo_base
      @repo_base ||= Pathname.new(@repo_path).realpath
    end

    def repo_path_candidate(path)
      path = path.to_s
      candidate = Pathname.new(path).absolute? ? Pathname.new(path) : repo_base.join(path)
      candidate = candidate.cleanpath
      candidate.to_s.start_with?("#{repo_base}/") ? candidate.to_s : nil
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    # Repository-relative form of an agent-supplied path. Paths that escape the
    # checkout have no relative form and cannot identify a run-owned artifact.
    def repo_relative_path(path)
      return if path.to_s.blank?

      candidate = repo_path_candidate(path)
      return if candidate.nil?

      Pathname.new(candidate).relative_path_from(repo_base).to_s
    rescue ArgumentError
      nil
    end

    def resolve_repo_path(path)
      resolved = Pathname.new(path).realpath
      resolved.to_s.start_with?("#{repo_base}/") ? resolved.to_s : nil
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
        # The run-owned path the agent wrote. It is the identifier an agent can
        # cite; the recorder-owned storage key stays internal to Paid.
        "path" => AgentRuns::VerificationPrompt::APP_LOG_PATH,
        "agent_run_id" => @agent_run.id,
        "project_id" => @agent_run.project_id,
        "account_id" => @agent_run.project.account_id,
        "tested_commit" => tested_commit,
        "storage_key" => storage_key,
        "details" => details
      }.compact
    end

    def evidence_limitations
      limitations = [
        "agent_reported_references_are_not_recorder_owned_evidence",
        "agent_reported_test_executions_are_not_recorder_owned_evidence",
        "validated_inputs_do_not_prove_semantic_coverage"
      ]
      return limitations unless interactive_verification?

      limitations.concat([
        "agent_reported_browser_steps_are_not_observed_evidence",
        "screenshots_and_app_logs_do_not_prove_arbitrary_acceptance_criteria"
      ])
    end

    def normalize_string_array(value)
      Array(value).filter_map do |entry|
        text = truncate_input_text(entry.to_s.strip)
        text if text.present?
      end.first(20)
    end

    def normalize_criterion_text_array(value)
      Array(value).filter_map { |entry| redact_input_excerpt(entry.to_s.strip) }.first(20).presence
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
        "summary" => "No verification result was recorded."
      }
    end

    def default_summary_for(status)
      {
        "passed" => "Verification passed.",
        "failed" => "Verification failed.",
        "skipped" => "Verification was skipped.",
        "not_run" => "Verification did not run."
      }.fetch(status)
    end

    # @spec PROJECT-READINESS-012
    def add_readiness_observation(result)
      return result unless result["reason"].in?(readiness_setup_reasons)

      result.merge(
        "readiness_observation" => {
          "reason" => result["reason"],
          "agent_run_id" => @agent_run.id,
          "checkout_revision" => @agent_run.result_commit_sha.presence || @agent_run.base_commit_sha,
          "observed_at" => result.fetch("recorded_at")
        }.compact
      )
    end

    def readiness_setup_reasons
      %w[app_start_command_unavailable verification_configuration_invalid]
    end

    def app_log_tail
      result = with_safe_repo_file(app_log_path) { |file| read_log_tail(file, max_lines: LOG_TAIL_LINES) }
      result.presence || { content: nil, truncated: false }
    rescue StandardError => e
      @logger.warn(
        message: "agent_runs.verification_result.log_tail_failed",
        agent_run_id: @agent_run.id,
        error: e.message
      )
      { content: nil, truncated: false }
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

      # Truncation is true whenever either cap stopped the read or the final
      # buffer holds more lines than the per-call limit. A caller reading
      # `app_log_truncated` knows the persisted tail is a bounded excerpt.
      truncated = position.positive? || buffer.count("\n") > max_lines
      normalize_log_tail(buffer, max_lines:, truncated:)
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

    def normalize_log_tail(content, max_lines:, truncated: false)
      content = content.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
      lines = content.lines.last(max_lines)
      # `truncated` reflects whether the read hit a cap. The final
      # `lines.last(max_lines)` may also discard a trailing partial line when
      # the buffer does not end with a newline; that is faithful redaction of
      # the buffer we just read, not extra truncation, so it does not flip the
      # flag.
      application_log = ApplicationLog.redact_and_bound(lines.join, agent_run: @agent_run)
      { content: application_log.content.presence, truncated: truncated || application_log.truncated }
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
