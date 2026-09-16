# frozen_string_literal: true

module IssueEnhancements
  # Shapes Paid enhancement / clarifying-answer comments for an LLM prompt by
  # section rather than by byte offset. Enhancement comments lead with prose
  # or `## Clarifying questions` and put `## Implementation context` further
  # down, so a blind head-truncate cuts exactly the content that proves
  # readiness. Instead, every comment is split on `##` headings, sections are
  # ranked by how decision-relevant they are, and one total budget is spent in
  # rank order (newer comments first within a rank) with a per-section cap so
  # a single long section cannot starve the rest. Retained sections are then
  # rendered back in their original comment and section order so the
  # narrative still reads chronologically (#3850).
  #
  # Returns one digested string per input body, in the given order — an empty
  # string when nothing from that body fit the budget.
  class CommentDigest
    Section = Struct.new(:body_index, :position, :tier, :text, :allotted)

    PRIORITY_HEADINGS = [
      "implementation context", "suggested approach", "clarifying question", "current context"
    ].freeze
    BOILERPLATE_HEADINGS = [ "proposed change intent record", "auto-enhancement stopped", "latest context" ].freeze
    MARKER_PATTERN = /<!--\s*paid:[^>]*-->/
    HEADING_PATTERN = /\A[ \t]{0,3}\#{2}[ \t]+(.+?)[ \t#]*\z/
    FENCE_PATTERN = /\A[ \t]{0,3}(```|~~~)/
    SEPARATOR = "\n\n"
    # A fragment shorter than this is just a heading with no content; skip it
    # rather than spend budget on noise.
    MIN_SECTION_CHARS = 80

    def self.call(...)
      new(...).call
    end

    def initialize(bodies:, total_budget:, section_budget: total_budget)
      @bodies = bodies
      @total_budget = total_budget
      @section_budget = [ section_budget, total_budget ].min
    end

    # @spec ISSUE-ANALYSIS-015
    def call
      sections = bodies.each_with_index.flat_map { |body, index| split_sections(body, index) }
      allocate(sections)
      bodies.each_index.map { |index| render(sections, index) }
    end

    private

    attr_reader :bodies, :total_budget, :section_budget

    def split_sections(body, body_index)
      chunks = [ +"" ]
      in_fence = false
      body.to_s.gsub(MARKER_PATTERN, "").each_line do |line|
        in_fence = !in_fence if line.match?(FENCE_PATTERN)
        chunks << +"" if !in_fence && heading_of(line)
        chunks.last << line
      end
      chunks.map(&:strip).each_with_index.filter_map do |text, position|
        Section.new(body_index, position, tier_for(text), text, 0) if content?(text)
      end
    end

    def heading_of(line)
      line.chomp[HEADING_PATTERN, 1]
    end

    # A bare heading with nothing under it (e.g. the stopped-round path's
    # `## Latest context` wrapper) carries no information.
    def content?(text)
      text.present? && (heading_of(text.lines.first).nil? || text.lines.size > 1)
    end

    def tier_for(text)
      heading = heading_of(text.lines.first)&.downcase
      return 1 unless heading
      return 0 if PRIORITY_HEADINGS.any? { |known| heading.include?(known) }
      return 2 if BOILERPLATE_HEADINGS.any? { |known| heading.include?(known) }

      1
    end

    # Rank order: decision-relevant sections first, then newer bodies first.
    # Pass 1 gives each section up to the per-section cap; pass 2 tops up
    # capped sections with whatever budget is left, in the same order.
    def allocate(sections)
      ranked = sections.sort_by { |section| [ section.tier, -section.body_index, section.position ] }
      remaining = total_budget
      ranked.each { |section| remaining -= grant(section, [ section_budget, remaining ].min) }
      ranked.each { |section| remaining -= grant(section, remaining) if section.allotted.positive? }
    end

    def grant(section, available)
      wanted = section.text.length - section.allotted
      return 0 if wanted <= 0

      cost = section.allotted.zero? ? SEPARATOR.length : 0
      chars = [ wanted, available - cost ].min
      return 0 if chars <= 0 || (section.allotted.zero? && chars < [ MIN_SECTION_CHARS, wanted ].min)

      section.allotted += chars
      chars + cost
    end

    def render(sections, body_index)
      sections
        .select { |section| section.body_index == body_index && section.allotted.positive? }
        .map { |section| section.text.truncate(section.allotted) }
        .join(SEPARATOR)
    end
  end
end
