# frozen_string_literal: true

module PromptEvolution
  # Selects the best-performing prompt version from a prompt's population via
  # tournament selection, retires underperforming variants, and optionally
  # rolls back to a previous generation if the current version's fitness has
  # regressed.
  #
  # Fitness is the mean composite_score across the version's automated
  # QualityMetrics that have a composite_score recorded. Tournament
  # selection randomly samples k candidates per round and picks the
  # fittest; the overall winner is the fittest version across all rounds.
  #
  # Generation depth is derived from the parent_version_id chain on
  # PromptVersion, which is already tracked when mutations are created.
  #
  # The service preserves minimum diversity — it will not retire so many
  # versions that fewer than `min_diversity` remain active, even if their
  # fitness is below the retirement threshold.
  #
  # @example
  #   result = PromptEvolution::Select.call(prompt: prompt)
  #   result.winner              # => PromptVersion selected as fittest
  #   result.retired             # => [PromptVersion, ...] underperformers retired
  #   result.rolled_back         # => true if the winner is an ancestor of the prior current version
  #   result.generations         # => { prompt_version_id => generation_depth, ... }
  class Select
    Result = Struct.new(
      :winner,
      :promoted,
      :retired,
      :rolled_back,
      :fitness,
      :generations,
      :reason,
      keyword_init: true
    )

    DEFAULT_TOURNAMENT_SIZE = 3
    DEFAULT_ROUNDS = 5
    DEFAULT_MIN_SAMPLES = 3
    DEFAULT_MIN_DIVERSITY = 2
    DEFAULT_RETIREMENT_THRESHOLD = 0.5
    DEFAULT_ROLLBACK_DROP = 0.1

    attr_reader :prompt

    def initialize(
      prompt:,
      tournament_size: DEFAULT_TOURNAMENT_SIZE,
      rounds: DEFAULT_ROUNDS,
      min_samples: DEFAULT_MIN_SAMPLES,
      min_diversity: DEFAULT_MIN_DIVERSITY,
      retirement_threshold: DEFAULT_RETIREMENT_THRESHOLD,
      rollback_drop: DEFAULT_ROLLBACK_DROP,
      random: Random.new
    )
      @prompt = prompt
      @tournament_size = Integer(tournament_size).clamp(2, 10)
      @rounds = Integer(rounds).clamp(1, 50)
      @min_samples = Integer(min_samples).clamp(1, 1_000)
      @min_diversity = Integer(min_diversity).clamp(0, 100)
      @retirement_threshold = Float(retirement_threshold).clamp(0.0, 1.0)
      @rollback_drop = Float(rollback_drop).clamp(0.0, 1.0)
      @random = random
    end

    def self.call(...)
      new(...).select
    end

    def select
      candidates = eligible_candidates
      fitness_map = build_fitness_map(candidates)
      generations = build_generation_map

      if fitness_map.empty?
        return Result.new(
          winner: nil,
          promoted: false,
          retired: [],
          rolled_back: false,
          fitness: {},
          generations: generations,
          reason: :insufficient_data
        )
      end

      winner = tournament_winner(candidates, fitness_map)
      rolled_back, rollback_target = evaluate_rollback(winner, fitness_map)
      winner = rollback_target if rolled_back

      promoted = promote_if_changed(winner)
      retired = retire_underperformers(candidates, fitness_map, winner)

      log_selection(winner: winner, promoted: promoted, rolled_back: rolled_back, retired: retired)

      Result.new(
        winner: winner,
        promoted: promoted,
        retired: retired,
        rolled_back: rolled_back,
        fitness: fitness_map,
        generations: generations,
        reason: rolled_back ? :rolled_back : :selected
      )
    end

    private

    # PromptVersions that are active and have enough samples to score.
    def eligible_candidates
      @eligible_candidates ||= begin
        candidates = prompt.prompt_versions.active.includes(:quality_metrics).to_a
        candidates.select { |v| sample_count(v) >= @min_samples }
      end
    end

    def sample_count(version)
      scored_metrics(version).size
    end

    def scored_metrics(version)
      version.quality_metrics.select do |metric|
        metric.metric_type == "automated" && metric.composite_score.present?
      end
    end

    # Mean composite_score across automated metrics referencing this version.
    def fitness_for(version)
      scores = scored_metrics(version).map { |m| m.composite_score.to_f }
      return nil if scores.empty?

      (scores.sum / scores.size).round(6)
    end

    def build_fitness_map(candidates)
      candidates.each_with_object({}) do |version, map|
        score = fitness_for(version)
        map[version.id] = score if score
      end
    end

    # Tournament selection: play `@rounds` tournaments, each picking the best
    # of `@tournament_size` random candidates; return the best winner across
    # all tournaments. Ties are broken by higher version number so newer
    # mutations are preferred when fitness matches.
    def tournament_winner(candidates, fitness_map)
      Tournament.call(
        candidates: candidates,
        fitness_map: fitness_map,
        tournament_size: @tournament_size,
        rounds: @rounds,
        random: @random
      )
    end

    # Pure function: plays `rounds` tournaments, each picking the best of
    # `tournament_size` random candidates; returns the best winner across all
    # tournaments. Extracted so tests can stub it via `allow(Tournament)`.
    class Tournament
      def self.call(candidates:, fitness_map:, tournament_size:, rounds:, random:)
        scored = candidates.select { |v| fitness_map.key?(v.id) }
        return nil if scored.empty?

        round_winners = rounds.times.map do
          contenders = scored.sample(tournament_size, random: random)
          contenders.max_by { |v| [ fitness_map[v.id], v.version ] }
        end

        round_winners.max_by { |v| [ fitness_map[v.id], v.version ] }
      end
    end

    # Rollback when the winner's fitness is significantly worse than its
    # ancestor's. Walks up the parent_version chain to find the best-performing
    # ancestor; if the drop exceeds @rollback_drop, we treat the ancestor as
    # the effective winner.
    def evaluate_rollback(winner, fitness_map)
      return [ false, winner ] unless winner

      winner_fitness = fitness_map[winner.id]
      return [ false, winner ] if winner_fitness.nil?

      best_ancestor = fittest_ancestor(winner, fitness_map)
      return [ false, winner ] unless best_ancestor

      ancestor_fitness = fitness_map[best_ancestor.id]
      return [ false, winner ] if ancestor_fitness.nil?
      return [ false, winner ] if ancestor_fitness - winner_fitness < @rollback_drop

      [ true, best_ancestor ]
    end

    def fittest_ancestor(version, fitness_map)
      ancestors = []
      current = versions_by_id[version.parent_version_id]
      visited = Set.new([ version.id ])

      while current && !visited.include?(current.id)
        visited << current.id
        ancestors << current if fitness_map.key?(current.id)
        current = versions_by_id[current.parent_version_id]
      end

      ancestors.max_by { |v| [ fitness_map[v.id], v.version ] }
    end

    def promote_if_changed(winner)
      return false unless winner
      return false if prompt.current_version_id == winner.id

      prompt.with_lock do
        prompt.update!(current_version: winner)
      end
      true
    end

    # Retire versions whose fitness is below @retirement_threshold, while
    # preserving the winner and at least @min_diversity active versions. The
    # worst performers are retired first.
    def retire_underperformers(candidates, fitness_map, winner)
      # Never retire the winner or the current version.
      protected_ids = Set.new([ winner&.id, prompt.current_version_id ].compact)

      active_count = prompt.prompt_versions.active.count

      below = candidates
              .select { |v| fitness_map.key?(v.id) }
              .reject { |v| protected_ids.include?(v.id) }
              .select { |v| fitness_map[v.id] < @retirement_threshold }
              .sort_by { |v| [ fitness_map[v.id], v.version ] }

      retired = []
      below.each do |version|
        break if active_count - retired.size <= @min_diversity

        version.update!(retired_at: Time.current)
        retired << version
      end

      retired
    end

    # Map of prompt_version_id => generation depth (0 for versions with no
    # parent in this prompt's tree). Depth is capped to avoid runaway
    # recursion on circular data.
    def versions_by_id
      @versions_by_id ||= prompt.prompt_versions.to_a.index_by(&:id)
    end

    def build_generation_map
      by_id = versions_by_id
      memo = {}

      by_id.values.each_with_object({}) do |version, map|
        map[version.id] = depth_for(version, by_id, memo)
      end
    end

    MAX_DEPTH = 100

    def depth_for(version, by_id, memo, seen = Set.new)
      return memo[version.id] if memo.key?(version.id)
      return 0 if version.parent_version_id.nil?
      return memo[version.id] = 0 if seen.include?(version.id)
      return memo[version.id] = MAX_DEPTH if seen.size >= MAX_DEPTH

      parent = by_id[version.parent_version_id]
      return memo[version.id] = 0 unless parent

      seen << version.id
      memo[version.id] = 1 + depth_for(parent, by_id, memo, seen)
    end

    def log_selection(winner:, promoted:, rolled_back:, retired:)
      Rails.logger.info(
        message: "prompt_evolution.select",
        prompt_id: prompt.id,
        winner_id: winner&.id,
        winner_version: winner&.version,
        promoted: promoted,
        rolled_back: rolled_back,
        retired_ids: retired.map(&:id),
        retired_count: retired.size
      )
    end
  end
end
