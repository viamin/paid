# frozen_string_literal: true

module StrategyEvolution
  class CreateCandidates
    APPROVAL_STATE = {
      "required" => true,
      "status" => "pending_review",
      "auto_promote" => false
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(strategy_snapshot:, account:, mutations:, idempotency_key: nil)
      @strategy_snapshot = strategy_snapshot.deep_symbolize_keys
      @account = account
      @mutations = Array(mutations)
      @idempotency_key = idempotency_key
    end

    def call
      return [] if mutations.empty?

      ActiveRecord::Base.transaction do
        account.with_lock do
          next_version = next_version_number

          mutations.map.with_index do |mutation, index|
            candidate = find_existing_candidate(index)
            next candidate if candidate

            candidate = OrchestrationStrategy.create!(
              account: account,
              strategy_type: strategy_type,
              name: strategy_name,
              version: next_version,
              configuration: candidate_configuration(mutation),
              active: false,
              idempotency_key: candidate_idempotency_key(index)
            )
            next_version += 1
            candidate
          end
        end
      end
    end

    private

    attr_reader :strategy_snapshot, :account, :mutations, :idempotency_key

    # Idempotent on retry: when an idempotency key is supplied, reuse the
    # candidate a previous attempt already created for this mutation
    # position instead of inserting a duplicate (#2770).
    def find_existing_candidate(index)
      return unless idempotency_key

      account.orchestration_strategies.find_by(
        strategy_type: strategy_type,
        idempotency_key: candidate_idempotency_key(index)
      )
    end

    def candidate_idempotency_key(index)
      return nil unless idempotency_key

      Activities::IdempotencyKey.compute(idempotency_key, index)
    end

    def strategy_type
      strategy_snapshot.fetch(:strategy_type)
    end

    def strategy_name
      strategy_snapshot.fetch(:name)
    end

    def next_version_number
      current_max = OrchestrationStrategy.where(account:, strategy_type:).maximum(:version).to_i
      [ current_max + 1, 1 ].max
    end

    def candidate_configuration(mutation)
      mutation.configuration.deep_stringify_keys.merge(
        "_evolution" => {
          "source_strategy_id" => strategy_snapshot[:id],
          "source_version" => strategy_snapshot[:version],
          "generated_at" => Time.current.iso8601,
          "mutation_strategy" => mutation.strategy,
          "reasoning" => mutation.reasoning,
          "expected_improvement" => mutation.expected_improvement,
          "diff" => mutation.diff,
          "provenance" => mutation.provenance,
          "approval" => APPROVAL_STATE
        }
      )
    end
  end
end
