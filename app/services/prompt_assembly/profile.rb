# frozen_string_literal: true

require "digest"

module PromptAssembly
  # A prompt assembly profile: which optional sections a caller suppresses,
  # the order of optional sections, and budgets for optional context.
  #
  # Safety-critical (required) sections are never suppressed, reordered to
  # weaken safety, or budget-constrained. The assembler enforces this via
  # +section_enabled?+ and +ordered_sections+.
  #
  # @spec PROMPT-ASSEMBLY-005, PROMPT-ASSEMBLY-012
  class Profile
    # Sections whose budgets are configurable.
    BUDGETABLE_SECTIONS = %i[knowledge style_guides marketplace].freeze

    # Default budgets for optional context sections.
    DEFAULT_BUDGETS = {
      knowledge: { tokens: 4000 },
      style_guides: { bytes: 32_000 }
    }.freeze

    attr_reader :disabled_sections, :section_order, :budgets

    def initialize(disabled_sections: [], section_order: [], budgets: {})
      @disabled_sections = Array(disabled_sections).map(&:to_sym).freeze
      @section_order = Array(section_order).map(&:to_sym).freeze
      @budgets = normalize_budgets(budgets)
      freeze
    end

    def section_enabled?(section)
      section.required? || !disabled_sections.include?(section.key)
    end

    # Reorder optional (non-required) sections according to +section_order+.
    # Required sections keep their original relative order; optional sections
    # are sorted by their position in +section_order+. Sections not listed in
    # +section_order+ keep their original relative order at the end of the
    # optional group.
    def ordered_sections(sections)
      return sections if section_order.empty?

      required, optional = sections.partition(&:required?)
      indexed = section_order.each_with_index.to_h
      tail_index = section_order.size
      sorted_optional = optional.sort_by.with_index do |section, i|
        [ indexed.fetch(section.key, tail_index), i ]
      end
      required + sorted_optional
    end

    def budget_for(key)
      budgets.fetch(key.to_sym, DEFAULT_BUDGETS[key.to_sym])
    end

    # Content-addressable fingerprint of the profile's effective configuration.
    # Two profiles with identical settings produce the same fingerprint.
    def fingerprint
      Digest::SHA256.hexdigest(to_fingerprint_json)
    end

    def to_h
      {
        disabled_sections: disabled_sections,
        section_order: section_order,
        budgets: budgets.transform_keys(&:to_s)
      }
    end

    # Merge two profiles for inheritance resolution. +other+ takes precedence
    # for every field it sets.
    def merge(other)
      self.class.new(
        disabled_sections: (disabled_sections + other.disabled_sections).uniq,
        section_order: other.section_order.empty? ? section_order : other.section_order,
        budgets: budgets.merge(other.budgets)
      )
    end

    def self.default
      new(budgets: DEFAULT_BUDGETS)
    end

    private

    def normalize_budgets(raw)
      return DEFAULT_BUDGETS.dup if raw.blank?

      Array(raw).each_with_object({}) do |(key, value), result|
        sym_key = key.to_sym
        next unless BUDGETABLE_SECTIONS.include?(sym_key)

        result[sym_key] = value.is_a?(Hash) ? value : value.to_h
      end.freeze
    end

    def to_fingerprint_json
      JSON.generate({
        "disabled_sections" => disabled_sections.map(&:to_s).sort,
        "section_order" => section_order.map(&:to_s),
        "budgets" => budgets.transform_keys(&:to_s)
      })
    end
  end
end
