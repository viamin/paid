# frozen_string_literal: true

require "time"

module IntentConformance
  # Evaluation-policy rules shared by the repository-visible JSONL ledger
  # (CLI) and the Rails labeling screen (UI). Both surfaces must apply the
  # same policy, validation, and record shapes (#4594).
  #
  # The team policy (two independent operators plus a third tie-break) is the
  # default and its requirements are unchanged; those rules stay owned by
  # ShadowEvaluationLedger. The solo-maintainer policy is explicitly selected
  # through a recorded `evaluation_policy` declaration event naming the single
  # authenticated maintainer. A ledger without a declaration keeps the team
  # policy, so historical bot-authored records are never silently
  # reinterpreted as qualifying solo human evidence.
  # @spec INTENT-CONFORMANCE-ROLLOUT-005
  module ShadowEvaluationPolicy
    POLICIES = %w[team solo].freeze
    DEFAULT_POLICY = "team"
    LABELS = %w[within_scope material_drift uncertain].freeze

    Declaration = Data.define(:policy, :maintainer, :recorded_at) do
      def solo? = policy == "solo"
    end

    module_function

    # @param entries [Array<Hash>] ledger events in append order.
    # @return [Declaration, nil] the parsed declaration, or nil when the
    #   ledger predates policies (the team default applies).
    def declaration_for(entries)
      candidates = entries.select { |entry| entry["type"] == "evaluation_policy" }
      raise invalid("an evaluation may declare at most one evaluation_policy event") if candidates.length > 1

      event = candidates.first
      return nil if event.nil?

      policy = event["policy"].to_s
      maintainer = event["maintainer"].to_s.strip
      raise invalid("evaluation_policy event needs a policy in #{POLICIES.join('|')}") unless POLICIES.include?(policy)
      raise invalid("a solo evaluation_policy event must name its single maintainer") if policy == "solo" && maintainer.empty?
      raise invalid("evaluation_policy event needs a recorded_at timestamp") if event["recorded_at"].to_s.empty?

      Declaration.new(policy:, maintainer:, recorded_at: parse_time!(event["recorded_at"], "evaluation_policy recorded_at"))
    end

    def policy_for(entries)
      declaration_for(entries)&.policy || DEFAULT_POLICY
    end

    def solo?(entries)
      policy_for(entries) == "solo"
    end

    # The declaration must precede every adjudication in append order and
    # recorded time; a solo declaration also freezes the only allowed
    # operator identity, replacing the team policy's separate
    # operators_frozen event.
    def ensure_declaration!(entries)
      declaration = declaration_for(entries)
      return declaration unless declaration&.solo?

      adjudications = entries.select { |entry| entry["type"] == "adjudication" }
      return declaration if adjudications.empty?

      declaration_index = entries.index { |entry| entry["type"] == "evaluation_policy" }
      raise invalid("evaluation_policy declaration must precede adjudications") unless declaration_index < entries.index(adjudications.first)

      adjudications.each do |entry|
        raise invalid("solo adjudication operator must be the declared maintainer") unless entry["operator"] == declaration.maintainer

        recorded_at = parse_time!(entry["recorded_at"], "solo adjudication recorded_at")
        raise invalid("solo adjudication was recorded before the policy declaration") if recorded_at < declaration.recorded_at
      end

      declaration
    end

    # Completeness and shape for solo adjudication events. Raises
    # PendingHumanInput while the maintainer still owes labels.
    def ensure_solo_adjudications!(cases, entries)
      declaration = ensure_declaration!(entries)
      raise invalid("solo adjudication events require a solo evaluation_policy declaration") unless declaration&.solo?

      adjudications = entries.select { |entry| entry["type"] == "adjudication" }
      known_cases = cases.to_h { |corpus_case| [ corpus_case.fetch("id"), true ] }
      adjudications.each do |entry|
        raise invalid("adjudication references a case outside the frozen manifest: #{entry["case_id"].inspect}") unless known_cases.key?(entry["case_id"])
        raise invalid("solo adjudication operator must be the declared maintainer") unless entry["operator"] == declaration.maintainer
      end

      cases.each do |corpus_case|
        case_entries = adjudications.select { |entry| entry["case_id"] == corpus_case.fetch("id") }
        raise pending("#{corpus_case.fetch("id")} needs the maintainer's blinded label") if case_entries.empty?
        raise invalid("#{corpus_case.fetch("id")} may not carry more than one solo adjudication") if case_entries.length > 1
        raise invalid("#{corpus_case.fetch("id")} adjudication is incomplete") unless adjudication_fields_complete?(case_entries.first)
      end
      true
    end

    def adjudication_fields_complete?(entry)
      return false unless %w[operator verdict cited_design_claim reason recorded_at].all? { |key| entry[key].to_s.strip != "" }

      LABELS.include?(entry["verdict"])
    end

    # Post-result revisions: appended after the case's reviewer run, bound to
    # the original frozen label, and never counted as adjudications or fed
    # into blinded scoring.
    def ensure_label_revisions!(cases, entries)
      revisions = entries.each_with_index.select { |entry, _index| entry["type"] == "label_revision" }
      return if revisions.empty?

      known_cases = cases.to_h { |corpus_case| [ corpus_case.fetch("id"), true ] }
      run_indexes = entries.each_with_index.select { |entry, _index| entry["type"] == "shadow_run" }.to_h { |entry, index| [ entry["case_id"], index ] }
      adjudications = entries.select { |entry| entry["type"] == "adjudication" }

      revisions.each do |entry, index|
        case_id = entry["case_id"]
        raise invalid("label revision references a case outside the frozen manifest: #{case_id.inspect}") unless known_cases.key?(case_id)
        raise invalid("label revision is incomplete") unless %w[operator original_verdict revised_verdict reason recorded_at].all? { |key| entry[key].to_s.strip != "" }
        raise invalid("label revision has an invalid revised verdict") unless LABELS.include?(entry["revised_verdict"])
        raise invalid("label revision has an invalid original verdict") unless LABELS.include?(entry["original_verdict"])
        raise invalid("label revision must follow the case's shadow run") unless run_indexes[case_id] && run_indexes[case_id] < index

        frozen_verdicts = adjudications.select { |adjudication| adjudication["case_id"] == case_id }.map { |adjudication| adjudication["verdict"] }
        raise invalid("label revision original_verdict does not match the frozen reference label") unless frozen_verdicts.include?(entry["original_verdict"])
      end
      nil
    end

    # Skipped cases are recorded intent, never completed evidence: the case
    # still owes its adjudication, so a ledger holding skips cannot validate.
    def ensure_skips!(cases, entries)
      entries.select { |entry| entry["type"] == "case_skipped" }.each do |entry|
        raise invalid("skip references a case outside the frozen manifest: #{entry["case_id"].inspect}") unless cases.any? { |corpus_case| corpus_case.fetch("id") == entry["case_id"] }
        raise invalid("skip event is incomplete") if entry["operator"].to_s.strip.empty? || entry["recorded_at"].to_s.strip.empty?
      end
      nil
    end

    # Reference-label validation for persisted (database) label rows about to
    # be frozen — the same rules `ensure_solo_adjudications!` enforces over
    # ledger events, expressed over string-keyed label hashes so the UI
    # freeze and the CLI ledger cannot drift apart.
    def validate_reference_labels!(cases:, labels:, declaration:)
      raise invalid("a solo declaration is required to freeze solo reference labels") unless declaration&.solo?

      by_case = labels.group_by { |label| label.fetch("case_id") }
      cases.each do |corpus_case|
        case_id = corpus_case.fetch("id")
        entries = Array(by_case[case_id]).reject { |label| label["state"] == "skipped" }
        raise pending("#{case_id} is unlabeled or skipped and cannot be silently counted as completed") if entries.empty?
        raise invalid("#{case_id} may not carry more than one solo reference label") if entries.length > 1

        label = entries.first
        raise invalid("#{case_id} reference label operator must be the declared maintainer") unless label["operator"] == declaration.maintainer
        raise invalid("#{case_id} has an invalid reference label") unless LABELS.include?(label["verdict"])
        raise invalid("#{case_id} reference label needs a cited design claim") if label["cited_design_claim"].to_s.strip.empty?
        raise invalid("#{case_id} reference label needs a reason") if label["reason"].to_s.strip.empty?
      end
      true
    end

    def parse_time!(value, field)
      Time.iso8601(value.to_s)
    rescue ArgumentError => error
      raise invalid("#{field} is not ISO-8601: #{error.message}")
    end

    def invalid(message)
      ShadowEvaluationLedger::InvalidLedger.new(message)
    end

    def pending(message)
      ShadowEvaluationLedger::PendingHumanInput.new(message)
    end
  end
end
