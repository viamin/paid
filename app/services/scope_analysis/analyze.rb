# frozen_string_literal: true

module ScopeAnalysis
  # Analyzes a feature request description to determine whether it should be
  # decomposed into multiple smaller issues.
  #
  # Scores the text across several signal categories (component mentions,
  # sequential phases, cross-cutting concerns, complexity markers, and length)
  # and returns a Result indicating whether decomposition is warranted.
  #
  # Integration: called early in the issue-to-agent-run pipeline (e.g.
  # Issues::Plan or AgentRuns::Create) to gate decomposition. The call site
  # will be added when the decomposition planner is wired up.
  #
  # @example
  #   result = ScopeAnalysis::Analyze.call(text: issue.body)
  #   result.should_decompose?  # => true
  #   result.confidence         # => 0.82
  #   result.sub_components     # => ["authentication", "background jobs", ...]
  class Analyze
    DEFAULT_THRESHOLD = 0.5
    WORD_COUNT_THRESHOLD = 200

    # Weights for each signal category (must sum to 1.0)
    SIGNAL_WEIGHTS = {
      components: 0.30,
      phases: 0.20,
      cross_cutting: 0.25,
      complexity: 0.15,
      length: 0.10
    }.freeze

    COMPONENT_PATTERNS = [
      /\bmodel(?:s)?\b/i,
      /\bcontroller(?:s)?\b/i,
      /Controller\b/,
      /\bview(?:s)?\b/i,
      /\bservice(?:s)?\b/i,
      /Service\b/,
      /\bmigration(?:s)?\b/i,
      /\btest(?:s|ing)?\b/i,
      /\bspec(?:s)?\b/i,
      /\bjob(?:s)?\b/i,
      /Job\b/,
      /\bmailer(?:s)?\b/i,
      /Mailer\b/,
      /\bserializer(?:s)?\b/i,
      /Serializer\b/,
      /\bmiddleware\b/i,
      /\broute(?:s|ing)?\b/i,
      /\bvalidation(?:s)?\b/i,
      /\bcallback(?:s)?\b/i,
      /\bhelper(?:s)?\b/i
    ].freeze

    NUMBERED_LIST_PATTERN = /^\s*\d+\.\s+/m

    PHASE_PATTERNS = [
      /\bfirst(?:ly)?\b.*\bthen\b/im,
      /\bstep\s+\d/i,
      /\bphase\s+\d/i,
      /\bfinally\b/i,
      /\bafter\s+that\b/i,
      /\bnext\b.*\bthen\b/im,
      NUMBERED_LIST_PATTERN
    ].freeze

    CROSS_CUTTING_CONCERNS = {
      "authentication" => /\bauthenticat(?:e|ion|ed|ing)\b|\bauth\b|\blogin\b|\bsign.?in\b/i,
      "authorization" => /\bauthoriz(?:e|ation|ed|ing)\b|\bpermission(?:s)?\b|\brole(?:s)?\b|\baccess.?control\b/i,
      "background jobs" => /\bbackground\s+job(?:s)?\b|\basync(?:hronous)?\b|\bworker(?:s)?\b|\bqueue(?:s|d|ing)?\b/i,
      "api endpoints" => /\bapi\s+endpoint(?:s)?\b|\brest(?:ful)?\s+api\b/i,
      "ui" => /\bui\b|\buser\s+interface\b|\bfrontend\b|\bfront.?end\b|\bdashboard\b/i,
      "database" => /\bdatabase\b|\bschema\b|\btable(?:s)?\b|\bcolumn(?:s)?\b|\bindex(?:es)?\b/i,
      "notifications" => /\bnotificat(?:ion|ions)\b|\bemail(?:s)?\b|\bwebhook(?:s)?\b|\balert(?:s)?\b/i,
      "caching" => /\bcach(?:e|ing|ed)\b|\bmemoiz(?:e|ation)\b/i
    }.freeze

    COMPLEXITY_MARKERS = [
      /\bredesign\b/i,
      /\brefactor(?:ing)?\b/i,
      /\bmigrat(?:e|ion|ing)\b/i,
      /\boverhaul\b/i,
      /\brewrite\b/i,
      /\breplace\b/i,
      /\brearchitect\b/i,
      /\brestructur(?:e|ing)\b/i,
      /\bconvert(?:ing)?\b/i,
      /\btransform(?:ation|ing)?\b/i
    ].freeze

    attr_reader :text, :threshold

    def initialize(text:, threshold: DEFAULT_THRESHOLD)
      @text = text.to_s
      @threshold = normalize_threshold(threshold)
    end

    def self.call(...)
      new(...).call
    end

    def call
      scores = {
        components: score_components,
        phases: score_phases,
        cross_cutting: score_cross_cutting,
        complexity: score_complexity,
        length: score_length
      }

      raw_confidence = scores.sum { |signal, score| SIGNAL_WEIGHTS[signal] * score }
      rounded_confidence = raw_confidence.round(2)

      Result.new(
        should_decompose: raw_confidence >= threshold,
        confidence: rounded_confidence,
        sub_components: extract_sub_components
      )
    end

    private

    def score_components
      matches = COMPONENT_PATTERNS.count { |pattern| text.match?(pattern) }
      normalize(matches, max: 5)
    end

    def score_phases
      numbered_list_items = text.scan(NUMBERED_LIST_PATTERN).size
      phase_keyword_matches = PHASE_PATTERNS.count { |pattern| pattern != NUMBERED_LIST_PATTERN && text.match?(pattern) }
      signal = phase_keyword_matches + [ numbered_list_items, 3 ].min
      normalize(signal, max: 5)
    end

    def score_cross_cutting
      matches = CROSS_CUTTING_CONCERNS.count { |_name, pattern| text.match?(pattern) }
      normalize(matches, max: 4)
    end

    def score_complexity
      matches = COMPLEXITY_MARKERS.count { |pattern| text.match?(pattern) }
      normalize(matches, max: 3)
    end

    def score_length
      word_count = text.split(/\s+/).size
      normalize(word_count, max: WORD_COUNT_THRESHOLD)
    end

    def normalize_threshold(value)
      result = Float(value)
      result.clamp(0.0, 1.0)
    rescue ArgumentError, TypeError
      raise ArgumentError, "threshold must be numeric between 0.0 and 1.0 (got #{value.inspect})"
    end

    def normalize(value, max:)
      [ value.to_f / max, 1.0 ].min
    end

    def canonical_component_label(raw)
      case raw
      when "job", "jobs" then "background jobs"
      when "controller", "controllers" then "web controllers"
      when "service", "services" then "service layer"
      when "mailer", "mailers" then "email"
      when "spec", "specs", "test", "tests", "testing" then "tests"
      when "route", "routes", "routing" then "routing"
      when "validation", "validations" then "validations"
      when "callback", "callbacks" then "callbacks"
      when "serializer", "serializers" then "serializers"
      when "helper", "helpers" then "helpers"
      when "migration", "migrations" then "migrations"
      when "model", "models" then "models"
      when "view", "views" then "views"
      when "middleware" then "middleware"
      else raw
      end
    end

    def extract_sub_components
      cross_cutting = CROSS_CUTTING_CONCERNS.filter_map do |name, pattern|
        name if text.match?(pattern)
      end

      component_mentions = COMPONENT_PATTERNS.filter_map do |pattern|
        match = text.match(pattern)
        canonical_component_label(match[0].downcase) if match
      end

      (cross_cutting + component_mentions).uniq
    end

    # Immutable result value object.
    class Result
      attr_reader :confidence, :sub_components

      def initialize(should_decompose:, confidence:, sub_components:)
        @should_decompose = should_decompose
        @confidence = confidence
        @sub_components = (sub_components || []).dup.freeze
      end

      def should_decompose?
        @should_decompose
      end
    end
  end
end
