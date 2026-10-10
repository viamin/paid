# frozen_string_literal: true

require "digest"
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

    module_function

    def load_manifest(path)
      YAML.safe_load_file(path).fetch("cases")
    rescue KeyError, Psych::Exception => error
      raise InvalidLedger, "invalid corpus manifest: #{error.message}"
    end

    def events(path)
      return [] unless File.exist?(path)

      File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
    rescue JSON::ParserError => error
      raise InvalidLedger, "invalid JSONL event: #{error.message}"
    end

    def validate!(manifest_path:, ledger_path:, manifest_commit:)
      cases = load_manifest(manifest_path)
      entries = events(ledger_path)
      ensure_manifest_predates_events!(entries, manifest_commit)
      ensure_operators_frozen!(entries)
      ensure_adjudications!(cases, entries)
      ensure_shadow_runs_follow_adjudications!(cases, entries)
      true
    end

    def ready_for_shadow_run!(manifest_path:, ledger_path:, manifest_commit:)
      cases = load_manifest(manifest_path)
      entries = events(ledger_path)
      ensure_manifest_predates_events!(entries, manifest_commit)
      ensure_operators_frozen!(entries)
      ensure_adjudications!(cases, entries)
      true
    end

    def append!(path:, event:)
      raise InvalidLedger, "event must be a JSON object" unless event.is_a?(Hash)
      raise InvalidLedger, "event_id is required" if event["event_id"].to_s.empty?
      raise InvalidLedger, "recorded_at is required" if event["recorded_at"].to_s.empty?
      raise InvalidLedger, "event_id already exists" if events(path).any? { |entry| entry["event_id"] == event["event_id"] }

      File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o644) { |file| file.puts(JSON.generate(event)) }
    end

    def digest(path) = Digest::SHA256.file(path).hexdigest

    def ensure_manifest_predates_events!(entries, manifest_commit)
      return if entries.empty?
      raise InvalidLedger, "manifest_commit is required before adjudication" if manifest_commit.to_s.empty?

      return if entries.all? { |entry| entry["manifest_commit"] == manifest_commit }

      raise InvalidLedger, "every ledger event must use the frozen corpus manifest commit"
    end

    def ensure_operators_frozen!(entries)
      frozen = entries.select { |entry| entry["type"] == "operators_frozen" }.first
      return if entries.none? { |entry| entry["type"] == "adjudication" }
      raise InvalidLedger, "operators_frozen event must precede adjudications" unless frozen

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
      raise InvalidLedger, "#{case_id} tie-break operator must be independent" if entries.map { |entry| entry["operator"] }.uniq.length != 3
    end

    def ensure_shadow_runs_follow_adjudications!(cases, entries)
      runs = entries.each_with_index.select { |entry, _index| entry["type"] == "shadow_run" }
      return if runs.empty?

      ensure_adjudications!(cases, entries)
      completion_index = entries.rindex { |entry| entry["type"] == "adjudication" }
      completion_time = entries.select { |entry| entry["type"] == "adjudication" }.map { |entry| Time.iso8601(entry.fetch("recorded_at")) }.max
      runs.each do |entry, index|
        raise InvalidLedger, "shadow run lacks reviewer identity" unless %w[case_id reviewer_run_id reviewer_model prompt_digest verdict recorded_at cost_cents].all? { |key| entry.key?(key) }
        raise InvalidLedger, "invalid reviewer verdict" unless REVIEWER_VERDICTS.include?(entry["verdict"])
        raise InvalidLedger, "shadow run was recorded before adjudications completed" if index <= completion_index
        raise InvalidLedger, "shadow run was timestamped before adjudications completed" if Time.iso8601(entry.fetch("recorded_at")) < completion_time
      end
    rescue ArgumentError, KeyError => error
      raise InvalidLedger, "invalid shadow run event: #{error.message}"
    end
  end
end
