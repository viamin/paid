# frozen_string_literal: true

module Experiments
  # Shared cached-analysis lifecycle for experiment models.
  #
  # Four experiment models (AbTest, ConfigurationExperiment,
  # StrategyExperiment, StyleGuideAbTest) repeat the same
  # `cached_or_compute_analysis` pattern: bucket current sample counts
  # into a stable key, return the cached payload when fresh, otherwise
  # recompute via the analyzer service and persist.
  #
  # The concern delegates variant / score collection to the analyzer
  # service so the cache key only depends on variant sample counts.
  #
  # Including models must expose:
  #   * `cached_analysis` (jsonb column) — last persisted analyzer result
  #   * `analysis_samples_key` (string column) — sample bucket signature
  #   * `samples_key` — instance method returning the current bucket signature
  #   * `<analyzer_class>.call(<keyword>: self)` — analyzer entry point
  #   * `<variants_association>` — association of variants to deserialize winner from
  #
  # Subclasses configure the analyzer class, the call keyword, and the
  # variants association via the `analysis_cache` DSL.
  module AnalysisCache
    extend ActiveSupport::Concern

    CACHE_BUCKET_SIZE = 5

    class_methods do
      # Configure how `cached_or_compute_analysis` finds its analyzer and the
      # association used to deserialize the winner variant.
      #
      # @param analyzer_class [Class] responds to `.call(<keyword>: <self>)`
      # @param variants_association [Symbol] association name whose records
      #   represent this experiment's variants
      # @param call_keyword [Symbol] keyword argument the analyzer class uses
      #   when invoked (defaults to `:ab_test` for AbTest, `:strategy_experiment`
      #   for StrategyExperiment, etc.)
      def analysis_cache(analyzer_class:, variants_association:, call_keyword:)
        @analyzer_class = analyzer_class
        @variants_association = variants_association
        @call_keyword = call_keyword
      end

      def analyzer_class
        @analyzer_class
      end

      def variants_association
        @variants_association
      end

      def call_keyword
        @call_keyword
      end
    end

    def cached_or_compute_analysis(persist: true)
      current_key = samples_key

      if cached_analysis.present?
        return deserialize_analysis if analysis_samples_key == current_key
        # On read paths, return the stale cached result rather than triggering an
        # expensive recomputation — the write path (RecordResult) will refresh
        # the cache at the next analysis interval.
        return deserialize_analysis unless persist
      end

      # Read paths never trigger expensive recomputation on cache miss.
      return nil unless persist

      self.class.analyzer_class.public_send(:call, **{ self.class.call_keyword => self }).tap do |result|
        persist_analysis!(result, current_key)
      end
    end

    private

    def persist_analysis!(result, key)
      update_columns(
        cached_analysis: {
          status: result.status.to_s,
          confidence: result.confidence&.to_f,
          improvement: result.improvement&.to_f,
          winner_id: result.winner&.id
        },
        analysis_samples_key: key
      )
    end

    def deserialize_analysis
      data = cached_analysis.symbolize_keys
      winner_id = data[:winner_id]
      winner = winner_id ? public_send(self.class.variants_association).find_by(id: winner_id) : nil

      self.class.analyzer_class::Result.new(
        status: data[:status]&.to_sym,
        winner: winner,
        confidence: data[:confidence],
        improvement: data[:improvement]
      )
    end
  end
end
