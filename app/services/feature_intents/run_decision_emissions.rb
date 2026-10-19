# frozen_string_literal: true

module FeatureIntents
  # Parses an agent run's recorded output for the explicitly emitted
  # open-decisions block (FEATURE-APPROVAL-019). The create_feature and
  # lid_planning prompts instruct the agent to emit, in its final output:
  #
  #   <!-- feature-decisions-start -->
  #   [
  #     {"kind": "question", "design_claim": "...", "prompt": "..."},
  #     {"kind": "inferred_decision", "design_claim": "...", "prompt": "..."}
  #   ]
  #   <!-- feature-decisions-end -->
  #
  # Parsing is deterministic (the same marker approach the multi-issue plan
  # parser uses): only what the run explicitly emitted becomes an item.
  # Absent block, malformed JSON, or incomplete items yield nothing — the
  # service never fabricates a question the run did not raise.
  # @spec FEATURE-APPROVAL-019
  class RunDecisionEmissions
    include Llm::OutputNormalizer

    EMISSION_PATTERN = /<!--\s*feature-decisions-start\s*-->\n?(.*?)\n?<!--\s*feature-decisions-end\s*-->/m.freeze
    KINDS = FeatureIntentDecision::KINDS
    MAX_DECISIONS = 20
    INFERRED_MARKER = "[inferred]"

    Item = Data.define(:kind, :design_claim, :prompt)

    def self.parse(summary)
      new(summary).parse
    end

    def initialize(summary)
      @summary = summary.to_s
    end

    def parse
      raw = @summary[EMISSION_PATTERN, 1]
      return [] if raw.blank?

      parse_items(strip_markdown_fence(raw.strip))
    end

    private

    def parse_items(raw)
      parsed = JSON.parse(raw)
      return [] unless parsed.is_a?(Array)

      parsed.filter_map { |entry| build_item(entry) }.first(MAX_DECISIONS)
    rescue JSON::ParserError
      []
    end

    def build_item(entry)
      return unless entry.is_a?(Hash)

      kind = entry["kind"].to_s
      prompt = entry["prompt"].to_s.strip
      design_claim = entry["design_claim"].to_s.strip
      return unless KINDS.include?(kind)
      return if prompt.blank? || design_claim.blank?

      Item.new(
        kind: kind,
        design_claim: design_claim.truncate(1_000),
        prompt: normalized_prompt(kind, prompt).truncate(2_000)
      )
    end

    # Inferred decisions carry the `[inferred]` flag in their prompt text so
    # a human can confirm or reject them through the Inbox
    # (FEATURE-APPROVAL-007). An emission that already carries the marker is
    # not double-flagged.
    def normalized_prompt(kind, prompt)
      return prompt unless kind == "inferred_decision"
      return prompt if prompt.start_with?(INFERRED_MARKER)

      "#{INFERRED_MARKER} #{prompt}"
    end
  end
end
