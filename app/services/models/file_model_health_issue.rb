# frozen_string_literal: true

require "digest"

module Models
  # Files (or updates) a single consolidated GitHub issue describing model-health
  # problems: catalog drift from DetectCatalogDrift, contract drift from
  # DetectContractDrift (RDR-040), and broken runner models from
  # DetectBrokenRunnerModels. Mirrors the self-healing pattern in
  # ExceptionHandler::IssueFiler — at most one open issue at a time, deduped by a
  # fingerprint marker embedded in the body, commenting when findings change.
  class FileModelHealthIssue
    LABEL = "model-health"
    FINGERPRINT_MARKER = "model-health-fingerprint"
    AGENT_HARNESS_REPO = "viamin/agent-harness"

    def self.call(...)
      new(...).call
    end

    def initialize(project:, drift:, broken:, contract_drift: nil, client: nil)
      @project = project
      @drift = drift
      @broken = broken
      @contract_drift = contract_drift || Models::DetectContractDrift::Result.new(findings: [], runner_count: 0)
      @client = client || project.client
    end

    def call
      return Result.new(action: :noop) unless findings?

      existing = open_health_issue
      if existing
        return Result.new(action: :skipped, issue: existing) if same_fingerprint?(existing)

        return comment_on(existing)
      end

      create_issue
    end

    private

    def findings?
      @drift.drift? || @contract_drift.drift? || @broken.broken?
    end

    def open_health_issue
      @client.issues(@project.full_name, labels: LABEL, state: "open").first
    rescue GithubClient::Error => e
      log(:lookup_failed, error: e.message)
      nil
    end

    def same_fingerprint?(issue)
      issue.body.to_s.include?(fingerprint_comment)
    end

    def comment_on(issue)
      # Update the body (and its fingerprint marker) before posting the
      # notification comment.  If the comment post fails after the body update
      # succeeds, the next run sees the correct fingerprint and skips — no
      # duplicate-comment loop.
      @client.update_issue(@project.full_name, issue.number, body: issue_body)
      @client.add_comment(@project.full_name, issue.number, comment_body)
      log(:commented, issue_number: issue.number)
      Result.new(action: :commented, issue: issue)
    rescue GithubClient::Error => e
      log(:comment_failed, error: e.message)
      Result.new(action: :error, error: e.message)
    end

    def create_issue
      ensure_label
      issue = @client.create_issue(
        @project.full_name,
        title: issue_title,
        body: issue_body,
        labels: issue_labels
      )
      log(:created, issue_number: issue.number)
      Result.new(action: :created, issue: issue)
    rescue GithubClient::Error => e
      log(:create_failed, error: e.message)
      Result.new(action: :error, error: e.message)
    end

    # Routes through the canonical provisioning service rather than a blind
    # create, so a stale `model-health` label's color/description gets
    # reconciled too (@spec GH-LABELS-002) — not just created once and left
    # to drift. Best-effort: this label is filed by a background job with no
    # "Sync Labels" UI trigger in its path, and a sync failure must not block
    # filing the issue — GitHub creates unknown labels on issue creation
    # anyway.
    def ensure_label
      Projects::EnsureStandardLabels.call_best_effort(project: @project)
    end

    def issue_labels
      [ LABEL, @project.generated_label_name, @project.automation_label_name ].compact.uniq
    end

    def issue_title
      parts = []
      parts << "#{@drift.new_model_count} new / #{@drift.deprecated_model_count} retired models" if @drift.drift?
      parts << "#{@contract_drift.total_affected_models} incompatible catalog model(s) (RDR-040)" if @contract_drift.drift?
      parts << "#{@broken.findings.size} broken runner model(s)" if @broken.broken?
      "chore(models): model-health drift detected — #{parts.join(", ")}"
    end

    def issue_labels_note
      "Labels `#{@project.generated_label_name}`/`#{@project.automation_label_name}` route this into Paid automation."
    end

    def issue_body
      <<~BODY.strip
        #{fingerprint_comment}
        _Filed automatically by `ModelHealthCheckJob`. #{issue_labels_note}_

        #{summary_sections}

        #{remediation_section}
      BODY
    end

    def comment_body
      <<~BODY.strip
        #{fingerprint_comment}
        🔄 Model-health findings changed since this issue was filed.

        #{summary_sections}
      BODY
    end

    def summary_sections
      [ drift_section, contract_drift_section, broken_section ].compact.join("\n\n")
    end

    def drift_section
      return unless @drift.drift?

      lines = [ "## Catalog drift (registry vs `LlmModel`)" ]
      @drift.providers.each do |provider, drift|
        lines << "\n### #{provider}"
        unless drift[:new_models].empty?
          lines << "**New models not in catalog:**"
          drift[:new_models].each do |entry|
            suffix = entry[:variants] > 1 ? " _(+#{entry[:variants] - 1} snapshot/alias variants)_" : ""
            lines << "- `#{entry[:representative]}`#{suffix}"
          end
        end
        unless drift[:deprecated_models].empty?
          lines << "**Catalogued models no longer in registry (likely retired):**"
          drift[:deprecated_models].each { |id| lines << "- `#{id}`" }
        end
      end
      lines.join("\n")
    end

    def contract_drift_section
      return unless @contract_drift.drift?

      lines = [ "## Catalog contract drift (active `LlmModel` vs installed runner contracts — RDR-040)" ]
      @contract_drift.findings.each do |finding|
        lines << "\n### #{finding[:runner_key]} (#{finding[:auth_type]}) ↔ `#{finding[:provider]}`"
        lines << "- incompatible catalog models: #{finding[:models].map { |id| "`#{id}`" }.join(', ')}"
        lines << "- incompatibility types: #{finding[:incompatibility_types].map { |t| "`#{t}`" }.join(', ')}" if finding[:incompatibility_types].any?
        unless finding[:sample_reasons].empty?
          lines << "- sample reasons:"
          finding[:sample_reasons].each { |reason| lines << "  - #{reason}" }
        end
      end
      lines.join("\n")
    end

    def broken_section
      return unless @broken.broken?

      lines = [ "## Broken runner models (from recent failed runs)" ]
      @broken.findings.each do |finding|
        lines << "\n### #{finding[:runner_name]} (`#{finding[:runner_key]}`) → `#{finding[:model]}`"
        lines << "- signature: `#{finding[:error_type]}`, #{finding[:occurrences]} occurrence(s)"
        lines << "- example runs: #{finding[:run_ids].join(', ')}"
        # Top-level fenced block: error output is multi-line and may contain
        # backticks, so an inline code span would break the markdown.
        lines << "\n```text\n#{finding[:sample_message]}\n```"
      end
      lines.join("\n")
    end

    def remediation_section
      <<~MD.strip
        ## Remediation

        - **Catalog drift** — update `Models::SeedKnownModels::KNOWN_MODELS` with current model ids
          (tier/category/capability_score are judgment calls); the registry merge backfills pricing/context.
        - **Catalog contract drift (RDR-040)** — active catalog rows are incompatible with the installed
          runner contracts (CLI version, auth mode, provider mismatch, etc.). Either:
          - mark the model `active: false` in the catalog until the runner contract catches up, or
          - bump the upstream CLI pin in [`#{AGENT_HARNESS_REPO}`](https://github.com/#{AGENT_HARNESS_REPO})
            (and the `agent-harness` gem version in Paid's `Gemfile`), or
          - swap the catalog model id for the runner's `replacement_model_id` listed in the finding reason.
        - **Broken runner models** — a runner's configured model id was rejected by its provider/CLI:
          - `model_not_found`: correct the runner's `tier_model_ids`/`config` model id (admin/config change,
            **not** a code change), or disable the runner if the model is gone.
          - `cli_version_outdated`: the runner's pinned CLI is too old for the provider's default model
            (e.g. Codex `gpt-5.5`). Bump the CLI pin upstream in [`#{AGENT_HARNESS_REPO}`](https://github.com/#{AGENT_HARNESS_REPO})
            and then the `agent-harness` gem version in Paid's `Gemfile`.
      MD
    end

    def fingerprint_comment
      "<!-- #{FINGERPRINT_MARKER}: #{combined_fingerprint} -->"
    end

    def combined_fingerprint
      Digest::SHA256.hexdigest("#{@drift.fingerprint}|#{@contract_drift.fingerprint}|#{@broken.fingerprint}")
    end

    def log(event, **payload)
      Rails.logger.info(message: "model_health.issue_#{event}", project_id: @project.id, **payload)
    end

    class Result
      attr_reader :action, :issue, :error

      def initialize(action:, issue: nil, error: nil)
        @action = action
        @issue = issue
        @error = error
      end

      def created? = action == :created
      def filed? = %i[created commented].include?(action)
    end
  end
end
