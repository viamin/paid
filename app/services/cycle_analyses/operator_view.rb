# frozen_string_literal: true

module CycleAnalyses
  # Operator-facing view state for one dependency-cycle Inbox occurrence:
  # plain-language status, next action, evidence coverage, and readable
  # recommendation fields. Presentation only — every authority, occurrence,
  # and live-source recheck stays in the analysis and repair services.
  # @spec AUTO-PICK-QUEUE-023 AUTO-PICK-QUEUE-024
  class OperatorView
    Button = Data.define(:kind, :label, :confirm)
    Status = Data.define(:key, :title, :description, :next_action, :button)
    EvidenceWarning = Data.define(:title, :description, :next_action)
    Change = Data.define(:action, :from_ref, :to_ref, :source_description, :source_url, :replacement_to_ref) do
      def readable_description
        return correction_description if action == "correct"

        "Remove the dependency declared by #{from_ref} → #{to_ref}, #{source_description}."
      end

      private

      def correction_description
        target = replacement_to_ref || "another issue"
        "Correct the dependency declared by #{from_ref} → #{to_ref} to point at #{target} instead, #{source_description}."
      end
    end
    Candidate = Data.define(:index, :changes, :evidence, :tradeoffs, :missing_or_conflicting_intent, :acyclic) do
      def manual_repair?
        removal = changes.one? && changes.first.action == "remove"
        named = changes.first && changes.first.from_ref && changes.first.to_ref
        acyclic && removal && named
      end

      def expected_result
        if acyclic
          "The resulting graph is acyclic — the cycle breaks, and held work can resume after synchronization."
        else
          "The resulting graph is still cyclic — this change set alone does not break the cycle."
        end
      end

      def repair_button_label
        "Remove the #{changes.first.to_ref} dependency #{changes.first.source_description}"
      end

      def repair_confirmation
        change = changes.first
        "Remove the dependency declaration where #{change.from_ref} declares #{change.to_ref} as a dependency " \
          "(#{change.source_description})? This edits GitHub. Paid re-checks the live declaration, your authority, " \
          "and the current graph before writing."
      end

      def before_description
        change = changes.first
        "#{change.from_ref} lists #{change.to_ref} as a dependency (#{change.source_description})."
      end

      def after_description
        change = changes.first
        "That single declaration is removed; #{change.from_ref} stops waiting on #{change.to_ref}. " \
          "Every other declaration is unchanged."
      end
    end

    MAY_EDIT_COPY = "a qualifying run may edit one verified GitHub dependency declaration"
    START_CONFIRMATION = "Start a bounded repair analysis of this cycle? It reads GitHub first; " \
                         "#{MAY_EDIT_COPY}, only when every safeguard passes. " \
                         "Paid re-checks authority and the live graph before any write."
    RETRY_CONFIRMATION = "Retry the bounded repair analysis of this cycle? It reads GitHub first; " \
                         "#{MAY_EDIT_COPY}, only when every safeguard passes. " \
                         "Paid re-checks authority and the live graph before any write."
    CONFIRM_REPAIR_CONFIRMATION = "Re-check the synchronized dependency graph to confirm the repair? " \
                                  "This only reads the synced graph — it does not edit GitHub."
    MANUAL_REPAIR_STATUSES = %i[completed ambiguous stopped].freeze

    REASON_DESCRIPTIONS = {
      "unauthorized" => "Paid could not confirm run and issue-mutation authority for every project in this cycle.",
      "graph_changed" => "The persisted dependency graph changed before the write, so the reviewed evidence no longer matched.",
      "resulting_graph_changed" => "The live graph would not match the reviewed resulting graph, so the repair stopped.",
      "edge_changed" => "The analyzed declaration changed on GitHub before the write.",
      "live_declaration_missing" => "Paid could not find the declaration on live GitHub.",
      "live_declaration_ambiguous" => "The declaration appears more than once on live GitHub, so no single line could be removed safely.",
      "live_declaration_not_removable" => "The declaration line carries more than the dependency itself, so removing the whole line would discard unrelated text.",
      "untrusted_source" => "The declaration's source is not trusted by this project.",
      "github_authorization_failed" => "GitHub rejected the repair credentials.",
      "github_write_failed" => "GitHub rejected the repair write.",
      "github_comment_write_suppressed" => "The declaration lives in a comment this environment is configured not to edit."
    }.freeze

    def initialize(cycle:, run:)
      @cycle = cycle
      @run = run
    end

    # @spec AUTO-PICK-QUEUE-023
    def status
      @status ||= calculate_status
    end

    # @spec AUTO-PICK-QUEUE-023
    def evidence_warning
      return unless coverage_gaps?

      description = [
        provenance_phrase,
        content_phrase
      ].compact.join(" and ") + ", so the recommendation may be incomplete."
      EvidenceWarning.new(title: "Some evidence was unavailable", description:,
        next_action: "Synchronize the affected repositories, then start a fresh analysis.")
    end

    # @spec AUTO-PICK-QUEUE-024
    def render_recommendation?
      run.present? && run.successful? && !stale? && recommendation_data.present?
    end

    def recommendation_summary
      return recommendation_data if recommendation_data.is_a?(String)
      return "" unless recommendation_data.is_a?(Hash)

      recommendation_data["summary"].to_s
    end

    def candidates
      @candidates ||= build_candidates
    end

    def manual_repair_candidates
      @manual_repair_candidates ||= if MANUAL_REPAIR_STATUSES.include?(status.key)
        candidates.select(&:manual_repair?)
      else
        []
      end
    end

    # @spec AUTO-PICK-QUEUE-024
    def diagnostics
      { "occurrence" => cycle.occurrence, "fingerprint" => cycle.fingerprint, "agent_run_id" => run&.id }.compact
    end

    def raw_recommendation_json
      JSON.pretty_generate(result)
    end

    def coverage_provenance_edge_ids
      coverage.fetch("unavailable_provenance_edge_ids", [])
    end

    def coverage_unavailable_content_issue_ids
      coverage.fetch("unavailable_content_issue_ids", [])
    end

    private

    attr_reader :cycle, :run

    def calculate_status
      return no_analysis_status if run.nil?
      return in_flight_status(:queued) if run.status == "queued"
      return in_flight_status(:running) if run.status == "running"
      return failed_status unless run.successful? || cancelled_pending_sync?
      return stale_status if stale?
      return pending_sync_status(confirmable: run.successful?) if repair_status == "pending_sync"
      return confirmed_status if repair_status == "resolved"
      return ambiguous? ? ambiguous_status : stopped_status if repair_status == "needs_operator_action"

      completed_status
    end

    def build_candidates
      return [] unless recommendation_data.is_a?(Hash)

      recommendation_data.fetch("candidates", []).each_with_index.filter_map do |raw, index|
        next unless raw.is_a?(Hash)

        Candidate.new(index:, changes: changes_for(raw), evidence: text_array(raw["evidence"]),
          tradeoffs: text_array(raw["tradeoffs"]),
          missing_or_conflicting_intent: text_array(raw["missing_or_conflicting_intent"]),
          acyclic: raw["acyclic"] == true)
      end
    end

    def result
      run&.verification_result&.dig(RESULT_KEY) || {}
    end

    def recommendation_data
      result["recommendation"]
    end

    def coverage
      result.is_a?(Hash) ? result.fetch("coverage", {}) : {}
    end

    def coverage_gaps?
      coverage_provenance_edge_ids.any? || coverage_unavailable_content_issue_ids.any?
    end

    def repair
      result["repair"].is_a?(Hash) ? result["repair"] : {}
    end

    def repair_status
      repair["status"]
    end

    def stale?
      run.external_metadata.dig(METADATA_KEY, "occurrence") != cycle.occurrence
    end

    # CycleAnalysisJob keeps an applied repair on a cancelled run; the run is
    # not successful, yet a GitHub declaration was written and awaits sync.
    def cancelled_pending_sync?
      run.status == "cancelled" && repair_status == "pending_sync"
    end

    def no_analysis_status
      Status.new(key: :no_analysis, title: "No analysis yet",
        description: "Paid recommends one bounded repair analysis: it reviews every declaration in the cycle and, " \
                     "only when strict safeguards pass, #{MAY_EDIT_COPY} — nothing else.",
        next_action: "Start the analysis below, or review the declarations yourself and edit the wrong one on GitHub.",
        button: fresh_analysis_button)
    end

    # A requeued pending-sync run keeps its applied repair and takes
    # CycleAnalysisJob's read-only confirm_repair branch, so the in-flight copy
    # must not promise a possible GitHub edit the confirmation run never makes.
    def in_flight_status(key)
      Status.new(key:, title: key == :queued ? "Analysis queued" : "Analysis running",
        description: in_flight_description,
        next_action: "Check the run for progress — no operator action is needed here.",
        button: nil)
    end

    def in_flight_description
      if repair_status == "pending_sync"
        "Paid already made the repair and is re-checking the synchronized graph to confirm it. " \
          "This does not edit GitHub."
      else
        "The analysis has not changed GitHub yet. When its safeguards pass, " \
          "the run may edit one verified GitHub dependency declaration."
      end
    end

    # The confirm action is offered only for a completed, current run that
    # CycleAnalyses::Start resumes for the read-only confirmation. A cancelled
    # run keeps the applied repair, but Start would replace it with a fresh
    # analysis that may edit GitHub, so the operator only waits for the
    # synchronization that requeues the confirmation automatically.
    def pending_sync_status(confirmable:)
      Status.new(key: :pending_sync, title: "Safe repair made, awaiting synchronization",
        description: "Paid removed one dependency declaration on #{repaired_declaration_ref || 'GitHub'}. " \
                     "Nothing else changed. The next GitHub synchronization confirms whether the cycle is gone.",
        next_action: pending_sync_next_action(confirmable),
        button: confirmable ? Button.new(:confirm_repair, "Re-check synced graph — no GitHub edit", CONFIRM_REPAIR_CONFIRMATION) : nil)
    end

    def pending_sync_next_action(confirmable)
      if confirmable
        "Confirm the repair by re-checking the synchronized graph, or wait for the next synchronization."
      else
        "Wait for the next GitHub synchronization to confirm the repair."
      end
    end

    def confirmed_status
      Status.new(key: :confirmed, title: "Repair confirmed",
        description: "Synchronization confirmed the repaired graph is acyclic. This Inbox item clears automatically; " \
                     "the analysis run keeps the full record.",
        next_action: "No further action is needed.", button: nil)
    end

    def ambiguous_status
      Status.new(key: :ambiguous, title: "No single safe repair",
        description: "The analysis could not narrow this cycle to one supported declaration removal with no " \
                     "missing or conflicting intent, so Paid did not edit GitHub.",
        next_action: "Review the candidates and their evidence below, apply one reviewed removal yourself, " \
                     "or edit the declaration on GitHub.",
        button: nil)
    end

    # No start action: this completed run still covers the unchanged
    # occurrence, so CycleAnalyses::Start refuses a duplicate and the operator
    # must edit GitHub (or wait for the graph to change) before a fresh
    # analysis can be queued.
    def stopped_status
      Status.new(key: :stopped, title: "Automatic repair stopped",
        description: stopped_description,
        next_action: stopped_next_action,
        button: nil)
    end

    def stopped_description
      reason = repair["reason"].to_s
      REASON_DESCRIPTIONS.fetch(reason,
        "The automatic repair stopped before any GitHub write (#{reason.humanize.downcase}).")
    end

    def stopped_next_action
      "Edit the declaration on GitHub yourself; a fresh analysis can start only after synchronization changes this cycle."
    end

    def stale_status
      Status.new(key: :stale, title: "Stale analysis",
        description: "The effective dependency graph changed after this analysis, so its recommendation no longer " \
                     "describes this cycle.",
        next_action: "Start a fresh analysis of the current graph.",
        button: fresh_analysis_button)
    end

    def failed_status
      reason = run.error_message.presence || run.status.humanize.downcase
      Status.new(key: :failed, title: "Analysis failed",
        description: "The analysis did not complete (#{reason}). Its recorded result cannot confirm whether GitHub changed.",
        next_action: "Check the live GitHub declaration before retrying the analysis or editing it yourself.",
        button: Button.new(:retry_analysis, "Retry repair analysis", RETRY_CONFIRMATION))
    end

    def completed_status
      Status.new(key: :completed, title: "Analysis complete",
        description: "The analysis completed. Review the recommendation below before anyone edits GitHub.",
        next_action: "Apply one reviewed removal below, or edit the declaration on GitHub yourself.",
        button: nil)
    end

    def fresh_analysis_button
      Button.new(:start_analysis, "Analyze cycle — may edit GitHub", START_CONFIRMATION)
    end

    def ambiguous?
      return false unless recommendation_data.is_a?(Hash)

      raw_candidates = recommendation_data.fetch("candidates", [])
      return true if repair["reason"] == "not_obvious" || raw_candidates.size != 1

      sole = raw_candidates.first
      !sole.is_a?(Hash) || text_array(sole["missing_or_conflicting_intent"]).any?
    end

    def changes_for(candidate)
      Array(candidate["declaration_changes"]).filter_map do |raw|
        next unless raw.is_a?(Hash)

        edge = snapshot_edges_by_id[raw["edge_id"]]
        replacement = raw["replacement"].is_a?(Hash) ? raw["replacement"] : {}
        Change.new(action: raw["action"], from_ref: issue_ref(edge&.fetch("from_issue_id", nil)),
          to_ref: issue_ref(edge&.fetch("to_issue_id", nil)),
          source_description: source_description(edge), source_url: edge&.fetch("declaration_url", nil),
          replacement_to_ref: issue_ref(replacement["to_issue_id"]))
      end
    end

    def snapshot_edges_by_id
      @snapshot_edges_by_id ||= Array(snapshot_edges).index_by { |edge| edge["id"] }
    end

    def snapshot_edges
      run.external_metadata.dig(METADATA_KEY, "effective_edges") || []
    end

    def snapshot_issues_by_id
      @snapshot_issues_by_id ||= Array(run.external_metadata.dig(METADATA_KEY, "issues"))
        .select { |issue| issue.is_a?(Hash) }.index_by { |issue| issue["id"] }
    end

    def issue_ref(issue_id)
      issue = snapshot_issues_by_id[issue_id]
      return unless issue

      "#{issue['project']}##{issue['number']}"
    end

    def source_description(edge)
      case edge&.fetch("declaration_source", nil)
      when "issue_comment" then "declared in a trusted comment on #{issue_ref(edge['from_issue_id'])}"
      when "issue_body" then "declared in the issue body of #{issue_ref(edge['from_issue_id'])}"
      else "declaration source not recorded"
      end
    end

    def repaired_declaration_ref
      details = repair.fetch("details", {})
      project = Project.find_by(id: details["project_id"])
      return unless project && details["issue_number"]

      "#{project.full_name}##{details['issue_number']}"
    end

    def text_array(value)
      Array(value).select { |item| item.is_a?(String) }
    end

    def provenance_phrase
      count = coverage_provenance_edge_ids.size
      return if count.zero?

      "#{count} declaration#{'s' unless count == 1} in the analysis had no recorded GitHub source"
    end

    def content_phrase
      count = coverage_unavailable_content_issue_ids.size
      return if count.zero?

      "the trusted content of #{count} issue#{'s' unless count == 1} could not be read"
    end
  end
end
