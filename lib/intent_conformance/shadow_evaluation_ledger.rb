# frozen_string_literal: true

require "json"
require "time"
require "yaml"

module IntentConformance
  # Repository-visible, append-only evidence for the RDR-067 shadow evaluation.
  # It intentionally has no writer other than the command-line append operation.
  # @spec INTENT-CONFORMANCE-ROLLOUT-002 @spec INTENT-CONFORMANCE-ROLLOUT-003
  module ShadowEvaluationLedger
    PendingHumanInput = Class.new(StandardError)
    InvalidLedger = Class.new(StandardError)

    HUMAN_VERDICTS = %w[accepted material_drift uncertain].freeze
    REVIEWER_VERDICTS = %w[within_scope material_drift uncertain].freeze
    CORPUS_STRATA = %w[accepted intentionally_drifted uncertain].freeze
    REQUIRED_CASE_IDENTITIES = %w[repository base_sha head_sha approved_design_revision model prompt_version].freeze

    module_function

    def load_manifest(path)
      document = YAML.safe_load_file(path)
      raise InvalidLedger, "invalid corpus manifest: expected a mapping with a cases list" unless document.is_a?(Hash) && document["cases"].is_a?(Array)

      cases = document.fetch("cases")
      raise InvalidLedger, "invalid corpus manifest: cases list must not be empty" if cases.empty?
      raise InvalidLedger, "invalid corpus manifest: every case needs an id" unless cases.all? { |entry| entry.is_a?(Hash) && entry["id"].to_s.strip != "" }
      raise InvalidLedger, "invalid corpus manifest: case ids must be unique" unless cases.map { |entry| entry.fetch("id") }.uniq.length == cases.length

      cases
    rescue Psych::Exception, Errno::ENOENT => error
      raise InvalidLedger, "invalid corpus manifest: #{error.message}"
    end

    def events(path)
      return [] unless File.exist?(path)

      entries = File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
      raise InvalidLedger, "invalid JSONL event: each event must be a JSON object" unless entries.all?(Hash)

      entries
    rescue JSON::ParserError => error
      raise InvalidLedger, "invalid JSONL event: #{error.message}"
    end

    def validate!(manifest_path:, ledger_path:, manifest_commit:)
      cases = load_manifest(manifest_path)
      entries = events(ledger_path)
      ensure_unique_event_ids!(entries)
      ensure_manifest_predates_events!(entries, manifest_commit)
      ensure_operators_frozen!(entries)
      ensure_adjudications!(cases, entries)
      ensure_shadow_runs_follow_adjudications!(cases, entries)
      ensure_corpus_shape!(cases)
      true
    end

    def ready_for_shadow_run!(manifest_path:, ledger_path:, manifest_commit:)
      cases = load_manifest(manifest_path)
      entries = events(ledger_path)
      ensure_unique_event_ids!(entries)
      ensure_manifest_predates_events!(entries, manifest_commit)
      ensure_operators_frozen!(entries)
      ensure_adjudications!(cases, entries)
      ensure_corpus_shape!(cases)
      true
    end

    def append!(path:, event:)
      raise InvalidLedger, "event must be a JSON object" unless event.is_a?(Hash)
      raise InvalidLedger, "event_id is required" if event["event_id"].to_s.strip.empty?
      raise InvalidLedger, "recorded_at is required" if event["recorded_at"].to_s.strip.empty?
      raise InvalidLedger, "event_id already exists" if events(path).any? { |entry| entry["event_id"] == event["event_id"] }

      File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o644) { |file| file.puts(JSON.generate(event)) }
    end

    def ensure_manifest_predates_events!(entries, manifest_commit)
      return if entries.empty?
      raise InvalidLedger, "manifest_commit is required before adjudication" if manifest_commit.to_s.empty?

      return if entries.all? { |entry| entry["manifest_commit"] == manifest_commit }

      raise InvalidLedger, "every ledger event must use the frozen corpus manifest commit"
    end

    def ensure_operators_frozen!(entries)
      frozen_events = entries.each_with_index.select { |entry, _index| entry["type"] == "operators_frozen" }
      adjudication_indices = entries.each_index.select { |index| entries[index]["type"] == "adjudication" }
      return if adjudication_indices.empty?
      raise InvalidLedger, "operators_frozen event must precede adjudications" unless frozen_events.one?

      frozen, frozen_index = frozen_events.first
      raise InvalidLedger, "operators_frozen event must precede adjudications" unless frozen_index < adjudication_indices.min

      frozen_at = Time.iso8601(frozen.fetch("recorded_at"))
      entries.select { |entry| entry["type"] == "adjudication" }.each do |entry|
        raise InvalidLedger, "adjudicator identity was not frozen before adjudication" unless Array(frozen["operators"]).include?(entry["operator"])
        raise InvalidLedger, "adjudicator identity was frozen after adjudication" if Time.iso8601(entry.fetch("recorded_at")) < frozen_at
      end
    rescue ArgumentError, KeyError => error
      raise InvalidLedger, "invalid operator freeze event: #{error.message}"
    end

    def ensure_adjudications!(cases, entries)
      adjudications = entries.select { |entry| entry["type"] == "adjudication" }
      case_ids = cases.to_h { |corpus_case| [ corpus_case.fetch("id"), true ] }
      adjudications.reject { |entry| case_ids.key?(entry["case_id"]) }.each do |entry|
        raise InvalidLedger, "adjudication references a case outside the frozen manifest: #{entry["case_id"].inspect}"
      end

      cases.each do |corpus_case|
        case_entries = adjudications.select { |entry| entry["case_id"] == corpus_case.fetch("id") }
        raise PendingHumanInput, "pending human input: #{corpus_case.fetch("id")} needs two adjudications" if case_entries.length < 2
        raise InvalidLedger, "#{corpus_case.fetch("id")} has more than three adjudications" if case_entries.length > 3
        validate_case_adjudications!(corpus_case.fetch("id"), case_entries)
      end
    end

    def validate_case_adjudications!(case_id, entries)
      entries.each do |entry|
        required = %w[operator verdict cited_design_claim reason recorded_at]
        raise InvalidLedger, "#{case_id} adjudication is incomplete" unless required.all? { |key| entry[key].to_s.strip != "" }
        raise InvalidLedger, "#{case_id} has invalid human verdict" unless HUMAN_VERDICTS.include?(entry["verdict"])
      end
      raise InvalidLedger, "#{case_id} first two adjudications must be independent" if entries.first(2).map { |entry| entry["operator"] }.uniq.length != 2
      return if entries.length == 2 && entries[0]["verdict"] == entries[1]["verdict"]
      raise PendingHumanInput, "pending human input: #{case_id} needs a third-operator tie-break" if entries.length == 2
      raise InvalidLedger, "#{case_id} must not have a tie-break after agreement" if entries[0]["verdict"] == entries[1]["verdict"]

      raise InvalidLedger, "#{case_id} tie-break operator must be independent" if entries.map { |entry| entry["operator"] }.uniq.length != 3
      raise InvalidLedger, "#{case_id} tie-break verdict must agree with one of the primary verdicts" unless [ entries[0]["verdict"], entries[1]["verdict"] ].include?(entries[2]["verdict"])
    end

    def ensure_corpus_shape!(cases)
      raise InvalidLedger, "corpus must contain at least ten cases in each stratum" unless CORPUS_STRATA.all? { |stratum| cases.count { |corpus_case| corpus_case["stratum"] == stratum } >= 10 }

      cases.each { |corpus_case| ensure_case_identity!(corpus_case) }
    end

    def ensure_case_identity!(corpus_case)
      raise InvalidLedger, "corpus case #{corpus_case.fetch("id")} lacks a valid stratum" unless CORPUS_STRATA.include?(corpus_case["stratum"])
      return if REQUIRED_CASE_IDENTITIES.all? { |key| corpus_case[key].to_s.strip != "" }

      raise InvalidLedger, "corpus case #{corpus_case.fetch("id")} lacks required repository, revision, or model/prompt identity"
    end

    def ensure_shadow_runs_follow_adjudications!(cases, entries)
      runs = entries.each_with_index.select { |entry, _index| entry["type"] == "shadow_run" }
      return if runs.empty?

      ensure_adjudications!(cases, entries)
      completion_index = entries.rindex { |entry| entry["type"] == "adjudication" }
      completion_time = entries.select { |entry| entry["type"] == "adjudication" }.map { |entry| Time.iso8601(entry.fetch("recorded_at")) }.max
      case_ids = cases.to_h { |corpus_case| [ corpus_case.fetch("id"), true ] }
      runs.each { |entry, index| validate_shadow_run!(entry, case_ids, index, completion_index, completion_time) }
      ensure_one_shadow_run_per_case!(runs.map { |entry, _index| entry })
    rescue ArgumentError, KeyError => error
      raise InvalidLedger, "invalid shadow run event: #{error.message}"
    end

    def validate_shadow_run!(entry, case_ids, index, completion_index, completion_time)
      required = %w[case_id reviewer_run_id reviewer_model prompt_digest verdict recorded_at cost_cents]
      raise InvalidLedger, "shadow run lacks reviewer identity" unless required.all? { |key| entry[key].to_s.strip != "" }
      raise InvalidLedger, "shadow run cost must be a non-negative integer" unless entry["cost_cents"].is_a?(Integer) && entry["cost_cents"] >= 0
      raise InvalidLedger, "shadow run references a case outside the frozen manifest" unless case_ids.key?(entry["case_id"])
      raise InvalidLedger, "invalid reviewer verdict" unless REVIEWER_VERDICTS.include?(entry["verdict"])
      raise InvalidLedger, "shadow run was recorded before adjudications completed" if index <= completion_index
      raise InvalidLedger, "shadow run was timestamped before adjudications completed" if Time.iso8601(entry.fetch("recorded_at")) < completion_time
    end

    def ensure_one_shadow_run_per_case!(runs)
      duplicated = runs.group_by { |entry| entry["case_id"] }.any? { |_case_id, group| group.length > 1 }
      raise InvalidLedger, "each case may have at most one shadow run" if duplicated
    end

    def ensure_unique_event_ids!(entries)
      event_ids = entries.map { |entry| entry["event_id"].to_s.strip }
      raise InvalidLedger, "event_id is required" if event_ids.any?(&:empty?)
      raise InvalidLedger, "event_id already exists" unless event_ids.uniq.length == event_ids.length
    end
  end
end
