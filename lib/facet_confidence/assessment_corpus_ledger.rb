# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "yaml"

module FacetConfidence
  # Repository-visible, append-only evidence for the RDR-070 versioned
  # facet-confidence assessment corpus. It intentionally has no writer other
  # than the command-line append operation, so recorded runs cannot be edited
  # after the fact — a correction or re-run is a new event, never a rewrite.
  # @spec FACET-CONFIDENCE-016 @spec FACET-CONFIDENCE-017
  module AssessmentCorpusLedger
    InvalidLedger = Class.new(StandardError)
    PendingOperatorInput = Class.new(StandardError)

    REQUIRED_SHAPES = %w[
      provisional_direction
      explicit_correction
      repeated_agent_suggestions
      collaborator_disagreement
      unknown_intent_strong_technical
      strong_intent_weak_feasibility
      research_scope
      boundary_79_80
    ].freeze

    EXPECTED_STATUSES = %w[completed clarification_needed unknown].freeze
    RUN_STATUSES = %w[completed clarification_needed unknown failed].freeze
    BANDS = %w[unknown below_threshold at_or_above_threshold].freeze
    READINESS = %w[ready not_ready].freeze

    module_function

    def load_corpus(path)
      document = read_yaml(path)
      cases = document.fetch("cases")
      raise InvalidLedger, "invalid corpus manifest: cases list must not be empty" if cases.empty?

      ensure_corpus_identity!(document)
      ensure_case_ids!(cases)
      ensure_shape_coverage!(cases)
      cases.each { |corpus_case| ensure_case!(corpus_case) }
      cases.each { |corpus_case| normalize_case!(corpus_case, document) }
    end

    def corpus_digest(path)
      Digest::SHA256.file(path).hexdigest
    rescue Errno::ENOENT => error
      raise InvalidLedger, "invalid corpus manifest: #{error.message}"
    end

    def events(path)
      return [] unless File.exist?(path)

      entries = File.readlines(path, chomp: true, encoding: "UTF-8").reject(&:empty?).map { |line| JSON.parse(line) }
      raise InvalidLedger, "invalid JSONL event: each event must be a JSON object" unless entries.all?(Hash)

      entries
    rescue JSON::ParserError => error
      raise InvalidLedger, "invalid JSONL event: #{error.message}"
    end

    def append!(ledger_path:, event:, corpus_path:)
      raise InvalidLedger, "event must be a JSON object" unless event.is_a?(Hash)
      raise InvalidLedger, "event_id is required" if event["event_id"].to_s.strip.empty?
      raise InvalidLedger, "recorded_at is required" if event["recorded_at"].to_s.strip.empty?

      event = event.merge("corpus_version" => corpus_version_of(corpus_path), "corpus_digest" => corpus_digest(corpus_path))
      validate_entries!(corpus_path:, entries: events(ledger_path) + [ event ])
      File.open(ledger_path, File::WRONLY | File::APPEND | File::CREAT, 0o644, encoding: "UTF-8") { |file| file.puts(JSON.generate(event)) }
    end

    # Validates the ledger and returns the per-case evaluation structure the
    # outcome report consumes: each case with its ordered runs, corrections,
    # and rework events.
    def evaluate(corpus_path:, ledger_path:)
      validate_entries!(corpus_path:, entries: events(ledger_path))
    end

    def validate!(corpus_path:, ledger_path:)
      evaluate(corpus_path:, ledger_path:)
      true
    end

    def corpus_version_of(path)
      read_yaml(path).fetch("corpus_version")
    end

    def validate_entries!(corpus_path:, entries:)
      cases = load_corpus(corpus_path)
      ensure_unique_event_ids!(entries)
      ensure_frozen_corpus_identity!(entries, corpus_path)
      validate_events!(cases, entries)
    end

    def read_yaml(path)
      document = YAML.safe_load_file(path)
      raise InvalidLedger, "invalid corpus manifest: expected a mapping with a cases list" unless document.is_a?(Hash) && document["cases"].is_a?(Array)

      document
    rescue Psych::Exception, Errno::ENOENT => error
      raise InvalidLedger, "invalid corpus manifest: #{error.message}"
    end

    def ensure_corpus_identity!(document)
      raise InvalidLedger, "invalid corpus manifest: corpus_version is required" if document["corpus_version"].to_s.strip.empty?
      return if document["rubric"].is_a?(Hash) && document.dig("rubric", "version").to_s.strip != "" && document.dig("rubric", "model").to_s.strip != ""

      raise InvalidLedger, "invalid corpus manifest: rubric version and model are required"
    end

    def ensure_case_ids!(cases)
      raise InvalidLedger, "invalid corpus manifest: every case needs an id" unless cases.all? { |entry| entry.is_a?(Hash) && entry["id"].to_s.strip != "" }
      return unless cases.map { |entry| entry.fetch("id") }.uniq.length != cases.length

      raise InvalidLedger, "invalid corpus manifest: case ids must be unique"
    end

    def ensure_shape_coverage!(cases)
      missing = REQUIRED_SHAPES - cases.map { |entry| entry["shape"].to_s }
      return if missing.empty?

      raise InvalidLedger, "invalid corpus manifest: corpus must cover every required shape (missing: #{missing.join(', ')})"
    end

    def ensure_case!(corpus_case)
      id = corpus_case.fetch("id")
      raise InvalidLedger, "corpus case #{id} lacks a valid shape" unless REQUIRED_SHAPES.include?(corpus_case["shape"])
      ensure_case_content!(corpus_case, id)
      ensure_case_evidence!(corpus_case, id)
      ensure_case_expectation!(corpus_case, id)
    end

    def ensure_case_content!(corpus_case, id)
      [ %w[facet name], %w[facet design_claim], %w[direction name], %w[direction description] ].each do |keys|
        raise InvalidLedger, "corpus case #{id} lacks #{keys.join(' ')}" if corpus_case.dig(*keys).to_s.strip.empty?
      end
      raise InvalidLedger, "corpus case #{id} lacks a selection rationale" if corpus_case["selection_rationale"].to_s.strip.empty?
    end

    def ensure_case_evidence!(corpus_case, id)
      evidence = Array(corpus_case["evidence"])
      raise InvalidLedger, "corpus case #{id} needs at least one attributable evidence item" if evidence.empty?

      references = evidence.map { |item| item["reference"].to_s }
      raise InvalidLedger, "corpus case #{id} evidence references must be unique and present" unless references.all? { |reference| !reference.strip.empty? } && references.uniq.length == references.length

      evidence.each do |item|
        raise InvalidLedger, "corpus case #{id} evidence needs a source type and statement" if item["source_type"].to_s.strip.empty? || item["statement"].to_s.strip.empty?
        parse_timestamp!(item["occurred_at"], "corpus case #{id} evidence #{item['reference']} occurred_at")
        next if item["supersedes"].nil? || references.include?(item["supersedes"])

        raise InvalidLedger, "corpus case #{id} evidence #{item['reference']} supersedes an unknown reference"
      end
    end

    def ensure_case_expectation!(corpus_case, id)
      expected = corpus_case["expected"]
      raise InvalidLedger, "corpus case #{id} lacks expected outcome bands" unless expected.is_a?(Hash)

      raise InvalidLedger, "corpus case #{id} has an invalid expected status" unless EXPECTED_STATUSES.include?(expected["status"])
      raise InvalidLedger, "corpus case #{id} has an invalid expected intent band" unless BANDS.include?(expected["intent_band"])
      raise InvalidLedger, "corpus case #{id} has an invalid expected technical band" unless BANDS.include?(expected["technical_band"])
      raise InvalidLedger, "corpus case #{id} has an invalid expected readiness" unless READINESS.include?(expected["readiness"])

      if expected["status"] != "completed" && expected["intent_band"] != "unknown"
        raise InvalidLedger, "corpus case #{id}: an expectation with unknown status cannot claim a known intent band"
      end
      return if expected["readiness"] == readiness_from_bands(expected)

      raise InvalidLedger, "corpus case #{id}: expected readiness contradicts the expected bands"
    end

    def readiness_from_bands(expected)
      return "ready" if expected["status"] == "completed" && expected["intent_band"] == "at_or_above_threshold" && expected["technical_band"] == "at_or_above_threshold"

      "not_ready"
    end

    def normalize_case!(corpus_case, document)
      defaults = document.fetch("threshold_defaults")
      corpus_case["thresholds"] = { "intent" => defaults.fetch("intent"), "technical" => defaults.fetch("technical") } if corpus_case["thresholds"].nil?
      corpus_case["evidence_revision"] = corpus_case.fetch("evidence").length
      corpus_case["rubric_version"] = document.dig("rubric", "version")
      corpus_case["model_version"] = document.dig("rubric", "model")
      corpus_case
    end

    def ensure_unique_event_ids!(entries)
      event_ids = entries.map { |entry| entry["event_id"].to_s.strip }
      raise InvalidLedger, "event_id is required" if event_ids.any?(&:empty?)
      raise InvalidLedger, "event_id already exists" unless event_ids.uniq.length == event_ids.length
    end

    def ensure_frozen_corpus_identity!(entries, corpus_path)
      return if entries.empty?

      raise InvalidLedger, "every ledger event must record the frozen corpus version" unless entries.all? { |entry| entry["corpus_version"] == corpus_version_of(corpus_path) }
      return if entries.all? { |entry| entry["corpus_digest"] == corpus_digest(corpus_path) }

      raise InvalidLedger, "every ledger event must match the frozen corpus content"
    end

    def validate_events!(cases, entries)
      evaluation = cases.to_h { |corpus_case| [ corpus_case.fetch("id"), { case: corpus_case, runs: [], corrections: [], rework: [] } ] }
      trackers = cases.to_h do |corpus_case|
        [ corpus_case.fetch("id"), { baseline_revision: corpus_case.fetch("evidence_revision"), run_seen: false, last_run_revision: nil, pending_corrections: [] } ]
      end
      entries.each { |entry| dispatch_event!(entry, evaluation, trackers) }
      evaluation
    end

    def dispatch_event!(entry, evaluation, trackers)
      parse_timestamp!(entry["recorded_at"], "ledger event recorded_at")
      case entry["type"]
      when "assessment_run" then validate_run!(entry, evaluation, trackers)
      when "correction" then validate_correction!(entry, evaluation, trackers)
      when "rework" then validate_rework!(entry, evaluation)
      else raise InvalidLedger, "unknown ledger event type: #{entry['type'].inspect}"
      end
    end

    def validate_run!(entry, evaluation, trackers)
      entry_state = state_for!(entry, evaluation)
      corpus_case = entry_state.fetch(:case)
      expected = corpus_case.fetch("expected")
      ensure_run_identity!(entry, corpus_case)
      ensure_run_scores!(entry)
      ensure_run_references!(entry, corpus_case, expected)
      ensure_run_revision!(entry, trackers.fetch(corpus_case.fetch("id")))
      entry_state[:runs] << entry
    end

    RUN_FIELD_LABELS = {
      "case_id" => "a case id", "corpus_version" => "the corpus version", "rubric_version" => "the rubric version",
      "model_version" => "the model version", "status" => "a status", "recorded_at" => "a recorded_at timestamp"
    }.freeze

    def ensure_run_identity!(entry, corpus_case)
      id = corpus_case.fetch("id")
      RUN_FIELD_LABELS.each do |field, label|
        raise InvalidLedger, "#{id} assessment run must record #{label}" if entry[field].to_s.strip.empty?
      end
      raise InvalidLedger, "#{id} assessment run must record the rubric version of the frozen corpus" unless entry["rubric_version"] == corpus_case.fetch("rubric_version")
      raise InvalidLedger, "#{corpus_case.fetch('id')} assessment run must record the model version of the frozen corpus" unless entry["model_version"] == corpus_case.fetch("model_version")
      raise InvalidLedger, "#{corpus_case.fetch('id')} assessment run has an invalid status" unless RUN_STATUSES.include?(entry["status"])
      raise InvalidLedger, "#{corpus_case.fetch('id')} assessment run cost must be a non-negative integer" unless entry["cost_cents"].is_a?(Integer) && entry["cost_cents"] >= 0
      parse_timestamp!(entry["recorded_at"], "#{corpus_case.fetch('id')} assessment run recorded_at")
    end

    def ensure_run_scores!(entry)
      id = entry["case_id"]
      if entry["status"] == "completed"
        raise InvalidLedger, "#{id} completed assessment run requires both bounded scores" unless known_score?(entry["intent_score"]) && known_score?(entry["technical_score"])
      else
        raise InvalidLedger, "#{id} unresolved assessment run cannot assert an intent score" unless entry["intent_score"].nil?
        return if entry["technical_score"].nil? || known_score?(entry["technical_score"])

        raise InvalidLedger, "#{id} assessment run technical score must be a bounded integer"
      end
    end

    def ensure_run_references!(entry, corpus_case, expected)
      references = Array(entry["evidence_references"])
      known = corpus_case.fetch("evidence").map { |item| item.fetch("reference") }
      must_cite = Array(expected["must_cite"])
      must_not_cite = Array(expected["must_not_cite"])
      id = corpus_case.fetch("id")
      if entry["status"] == "completed"
        unless references.any? && references.all? { |reference| known.include?(reference) }
          raise InvalidLedger, "#{id} completed assessment run must cite evidence drawn from the case"
        end

        missing = must_cite - references
        raise InvalidLedger, "#{id} assessment run must cite the correction evidence: #{missing.join(', ')}" unless missing.empty?
      end
      superseded = must_not_cite & references
      raise InvalidLedger, "#{id} assessment run must not cite superseded evidence: #{superseded.join(', ')}" unless superseded.empty?
    end

    def ensure_run_revision!(entry, tracker)
      id = entry["case_id"]
      revision = entry["input_revision"]
      raise InvalidLedger, "#{id} assessment run must record a positive integer input revision" unless revision.is_a?(Integer) && revision.positive?

      if tracker[:run_seen]
        if revision == tracker[:last_run_revision]
          raise InvalidLedger, "#{id} identical input cannot be replayed to inflate certainty at input revision #{revision}"
        end
        raise InvalidLedger, "#{id} input revisions must advance" unless revision > tracker[:last_run_revision]
        raise InvalidLedger, "#{id} re-run requires a recorded correction at the new input revision" unless tracker[:pending_corrections].include?(revision)
      else
        raise InvalidLedger, "#{id} first assessment run must assess the frozen case input revision" unless revision == tracker[:baseline_revision]
      end
      tracker[:run_seen] = true
      tracker[:last_run_revision] = revision
    end

    def validate_correction!(entry, evaluation, trackers)
      entry_state = state_for!(entry, evaluation)
      id = entry["case_id"]
      raise InvalidLedger, "#{id} correction must record a statement" if entry["statement"].to_s.strip.empty?
      revision = entry["input_revision"]
      raise InvalidLedger, "#{id} correction must record a positive integer input revision" unless revision.is_a?(Integer) && revision.positive?
      tracker = trackers.fetch(id)
      raise InvalidLedger, "#{id} correction must follow an assessment run" unless tracker[:run_seen]
      raise InvalidLedger, "#{id} correction must advance beyond the recorded input revision" unless revision > tracker[:last_run_revision]

      tracker[:pending_corrections] << revision
      entry_state[:corrections] << entry
    end

    def validate_rework!(entry, evaluation)
      entry_state = state_for!(entry, evaluation)
      id = entry["case_id"]
      raise InvalidLedger, "#{id} rework must record a description" if entry["description"].to_s.strip.empty?
      raise InvalidLedger, "#{id} rework cost must be a non-negative integer" unless entry["cost_cents"].is_a?(Integer) && entry["cost_cents"] >= 0
      run_ids = entry_state[:runs].map { |run| run["event_id"] }
      raise InvalidLedger, "#{id} rework must reference an assessment run of the same case" unless run_ids.include?(entry["run_event_id"])

      entry_state[:rework] << entry
    end

    def state_for!(entry, evaluation)
      evaluation.fetch(entry["case_id"])
    rescue KeyError
      raise InvalidLedger, "event references a case outside the frozen corpus: #{entry['case_id'].inspect}"
    end

    def known_score?(score) = score.is_a?(Integer) && score.between?(0, 100)

    def parse_timestamp!(value, label)
      Time.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      raise InvalidLedger, "#{label} must be an ISO-8601 timestamp"
    end
  end
end
