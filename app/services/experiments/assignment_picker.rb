# frozen_string_literal: true

module Experiments
  # Picks a variant for a subject (agent_run, workflow_id, project, ...)
  # using weighted random selection that balances assignment counts.
  #
  # Two strategies are supported, covering every existing assignment
  # service:
  #
  #   :inversely_weighted — each variant gets weight = (max_count - count) + 1
  #                         so underfilled variants are favoured (used by
  #                         ab_tests, configuration_experiments,
  #                         strategy_experiments, style_guide_ab_tests).
  #
  #   :hash_balanced      — deterministic min-fill selection seeded by a
  #                         workflow-scoped hash. Variants tied for the
  #                         minimum current count are candidates; the
  #                         subject's stable hash picks deterministically
  #                         (used by coordination_experiments,
  #                         scaling_experiments).
  #
  # The caller supplies the variants collection and the live assignment
  # count lookup (an `{ variant_id => count }` hash). The caller owns the
  # assignment-row creation so this service stays free of model-specific
  # SQL.
  module AssignmentPicker
    module_function

    # @param variants [Array<#id, #is_control>] experiment variants (any order)
    # @param counts [Hash{Integer => Integer}] variant id => live assignment count
    # @param strategy [Symbol] :inversely_weighted or :hash_balanced
    # @param subject_hash [String, nil] required for :hash_balanced; the
    #   stable per-subject hash used to break ties deterministically
    # @param random [Proc, nil] optional rand substitute (defaults to Kernel.rand).
    #   Tests inject deterministic randomness via this argument.
    def pick(variants:, counts:, strategy:, subject_hash: nil, random: nil)
      raise ArgumentError, "experiment has no variants" if variants.empty?
      return variants.first if variants.size == 1

      random ||= -> { rand }

      case strategy
      when :inversely_weighted then weighted_random(variants, counts, random)
      when :hash_balanced then hash_balanced(variants, counts, subject_hash)
      else raise ArgumentError, "unknown assignment strategy #{strategy.inspect}"
      end
    end

    def weighted_random(variants, counts, random)
      max_count = variants.map { |variant| counts.fetch(variant.id, 0) }.max
      weights = variants.map { |variant| (max_count - counts.fetch(variant.id, 0)) + 1 }
      total = weights.sum.to_f

      roll = random.call
      cumulative = 0.0
      variants.zip(weights).each do |variant, weight|
        cumulative += weight / total
        return variant if roll < cumulative
      end

      variants.last
    end

    def hash_balanced(variants, counts, subject_hash)
      raise ArgumentError, "subject_hash required for hash_balanced strategy" if subject_hash.nil?

      min_count = variants.map { |variant| counts.fetch(variant.id, 0) }.min
      candidates = variants.select { |variant| counts.fetch(variant.id, 0) == min_count }
      candidates[Zlib.crc32(subject_hash) % candidates.size]
    end
  end
end
