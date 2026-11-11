# frozen_string_literal: true

require "digest"
require "pathname"

module AgentRuns
  # Recorder-owned mechanical validation of the inputs an agent cites behind a
  # criterion evidence claim. Labels each reference verified, contradicted,
  # stale, or unavailable. A valid receipt means the cited inputs were
  # mechanically verified; it never proves the semantic coverage judgment.
  # @spec LIVE-PREVIEW-013
  class CriterionInputReceipts
    MAX_INPUTS = 20
    MAX_LOCATOR_BYTES = 200
    EXCERPT_SCAN_BYTES = 64.kilobytes
    COMMIT_SHA = /\A[0-9a-f]{40}\z/
    SHA256_DIGEST = /\Asha256:[0-9a-f]{64}\z/
    NON_PASSING_RESULTS = %w[failed skipped not_run].freeze
    INPUT_TYPES = %w[repo_path spec_revision test_run artifact external].freeze

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, repo_path:, criteria:, tested_commit:, retained_storage_keys: [])
      @agent_run = agent_run
      @repo_path = repo_path
      @criteria = Array(criteria)
      @tested_commit = tested_commit.presence
      @retained_storage_keys = Array(retained_storage_keys)
    end

    def call
      @criteria.filter_map do |criterion|
        next unless criterion.is_a?(Hash)

        id = criterion["id"].to_s.strip
        next if id.blank?

        [ id, receipt_for(criterion) ]
      end.to_h
    end

    private

    def receipt_for(criterion)
      references = cited_inputs(criterion).filter_map { |input| assess_input(input) }.first(MAX_INPUTS)
      counts = tally(references)
      state, reason = aggregate_state(references, counts)
      { "state" => state, "reason" => reason, "references" => references, "counts" => counts }
    end

    # Accepts inputs under `verification.inputs` (the prompt contract) with a
    # top-level `inputs` fallback for hand-written results.
    def cited_inputs(criterion)
      verification = criterion["verification"]
      inputs = verification.is_a?(Hash) ? verification["inputs"] : nil
      Array(inputs || criterion["inputs"]).select { |input| input.is_a?(Hash) }.map(&:deep_stringify_keys)
    end

    def assess_input(input)
      type = input["type"].to_s
      return unknown_type_receipt(type, input) unless type.in?(INPUT_TYPES)

      send("assess_#{type}", input)
    end

    def assess_repo_path(input)
      assess_revision_bound_path(input, input["commit"].presence || input["revision"].presence)
    end
    alias_method :assess_spec_revision, :assess_repo_path

    def assess_revision_bound_path(input, pinned_commit)
      path = bounded_string(input["path"])
      return unavailable(input, "path", "malformed_reference") if path.blank?
      return unavailable(input, path, "malformed_reference") if malformed_binding?(input, pinned_commit)

      file = resolved_repo_file(path)
      return unavailable(input, path, "outside_repo") if file == :outside_repo
      return unavailable(input, path, "path_not_found") unless file

      commit = pinned_commit.to_s
      return unavailable(input, path, "commit_not_pinned") unless commit.match?(COMMIT_SHA)
      # Without a known reviewed revision the revision binding is unchecked,
      # so the reference cannot be verified against the PR head.
      return unavailable(input, path, "tested_revision_unavailable") unless @tested_commit
      return stale(input, path, "revision_mismatch") if commit != @tested_commit

      assess_content_binding(input, path, file)
    end

    def assess_content_binding(input, locator, file)
      digest = input["digest"].to_s
      if digest.match?(SHA256_DIGEST)
        return verified(input, locator, "digest_match") if content_digest(file) == digest

        return contradicted(input, locator, "digest_mismatch")
      end
      return contradicted(input, locator, "digest_mismatch") if digest.present?

      excerpt = bounded_string(input["excerpt"])
      return unavailable(input, locator, "content_binding_missing") if excerpt.blank?

      case excerpt_state(file, excerpt)
      when :found then verified(input, locator, "excerpt_match")
      when :absent then contradicted(input, locator, "excerpt_not_found")
      else unavailable(input, locator, "excerpt_binding_unreadable")
      end
    end

    def excerpt_state(file, excerpt)
      File.open(file, "rb") do |io|
        content = io.read(EXCERPT_SCAN_BYTES).to_s
        return :found if content.include?(excerpt)

        io.size > EXCERPT_SCAN_BYTES ? :unreadable : :absent
      end
    end

    def assess_test_run(input)
      command = bounded_string(input["command"])
      return unavailable(input, "test_run", "malformed_reference") if command.blank?

      result = input["result"].to_s
      return contradicted(input, command, "reported_result_not_passing") if result.in?(NON_PASSING_RESULTS)
      return unavailable(input, command, "result_not_reported") unless result == "passed"

      # Paid holds no recorder-owned record of an arbitrary in-container test
      # execution, so a claimed pass stays unverifiable rather than trusted.
      unavailable(input, command, "no_recorder_owned_execution")
    end

    def assess_artifact(input)
      return assess_artifact_storage_key(input) if input["storage_key"].present?

      return assess_artifact_path(input) if input["path"].present?
      return unavailable(input, bounded_string(input["url"]), "url_not_mechanically_verifiable") if input["url"].present?

      unavailable(input, "artifact", "malformed_reference")
    end

    def assess_artifact_storage_key(input)
      key = bounded_string(input["storage_key"])
      return verified(input, key, "recorder_owned_provenance") if key.in?(@retained_storage_keys)
      return unavailable(input, key, "artifact_not_retained") if key.include?("verification/#{@agent_run.id}/")

      unavailable(input, key, "provenance_not_recorder_owned")
    end

    def assess_artifact_path(input)
      path = bounded_string(input["path"])
      file = resolved_repo_file(path)
      return unavailable(input, path, "outside_repo") if file == :outside_repo
      return unavailable(input, path, "path_not_found") unless file

      # Binary artifacts are presence-checked; a digest, when cited, is
      # matched exactly like a repository content binding.
      return verified(input, path, "artifact_present") if input["digest"].blank?

      assess_content_binding(input, path, file)
    end

    def assess_external(input)
      locator = bounded_string(input["url"].presence || input["description"])
      # Human and external criteria require actual inspectable evidence; the
      # reference stays visible for review but is never machine-verified.
      unavailable(input, locator, "external_reference_requires_human_review")
    end

    def unknown_type_receipt(type, input)
      unavailable(input, bounded_string(type.presence || input["path"] || input["description"]), "unknown_input_type")
    end

    def malformed_binding?(input, pinned_commit)
      digest = input["digest"].to_s
      commit = pinned_commit.to_s
      (digest.present? && !digest.match?(SHA256_DIGEST)) || (commit.present? && !commit.match?(COMMIT_SHA))
    end

    def resolved_repo_file(path)
      base = Pathname.new(@repo_path).realpath
      candidate = Pathname.new(path).absolute? ? Pathname.new(path) : base.join(path)
      candidate = candidate.cleanpath
      return :outside_repo unless candidate.to_s.start_with?("#{base}/")

      File.file?(candidate.to_s) ? candidate.to_s : nil
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOTDIR
      nil
    end

    def content_digest(file)
      "sha256:#{Digest::SHA256.file(file).hexdigest}"
    end

    def verified(input, locator, reason)
      reference(input, locator, "verified", reason)
    end

    def contradicted(input, locator, reason)
      reference(input, locator, "contradicted", reason)
    end

    def stale(input, locator, reason)
      reference(input, locator, "stale", reason)
    end

    def unavailable(input, locator, reason)
      reference(input, locator, "unavailable", reason)
    end

    def reference(input, locator, state, reason)
      {
        "type" => bounded_string(input["type"]).presence || "unknown",
        "locator" => redacted_locator(locator),
        "state" => state,
        "reason" => reason
      }
    end

    def redacted_locator(locator)
      redacted = AgentRuns::Research::SecretGuard.redact_text(locator.to_s, agent_run: @agent_run)
      bounded_string(redacted).presence || "unavailable"
    end

    def bounded_string(value)
      value.to_s.strip.byteslice(0, MAX_LOCATOR_BYTES).to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
    end

    def tally(references)
      states = references.map { |reference| reference["state"] }
      {
        "total" => references.size,
        "verified" => states.count("verified"),
        "contradicted" => states.count("contradicted"),
        "stale" => states.count("stale"),
        "unavailable" => states.count("unavailable")
      }
    end

    # A criterion receipt counts as verified only when every cited reference
    # verifies: one nonexistent or unverifiable input means the receipt is not
    # valid, so a fabricated input cannot hide behind genuine ones.
    def aggregate_state(references, counts)
      return [ "unavailable", "no_input_references_cited" ] if references.empty?
      return [ "contradicted", "input_reference_contradicted" ] if counts["contradicted"].positive?
      return [ "stale", "input_reference_stale" ] if counts["stale"].positive?
      return [ "verified", "input_references_verified" ] if counts["verified"] == counts["total"]

      [ "unavailable", "no_verifiable_input_references" ]
    end
  end
end
