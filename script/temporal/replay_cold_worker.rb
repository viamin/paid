# frozen_string_literal: true

# Cold-worker replay verification for the evolution workflows.
#
# Boots a fresh Ruby process the way `bin/temporal_worker` does — Rails
# environment without eager loading, then explicit requires of the activity
# and workflow files — and replays the checked-in evolution histories with
# `Paid::TemporalDataConverter`. Resolving autoload-managed constants (for
# example `CoordinationPolicyEvolution::PrepareInputs::POLICY_TYPE`) from
# inside workflow execution instead makes Zeitwerk run its Monitor-locked
# directory autoload on the workflow thread, which Temporal's illegal-call
# tracer rejects as nondeterminism; the workflow task then keeps retrying.
#
# The reported namespaces must still be pending autoloads before the
# workflow files are required, proving the process is actually cold rather
# than accidentally warmed by application boot.
#
# Run manually with:
#
#     bundle exec ruby script/temporal/replay_cold_worker.rb
#
# The JSON report on stdout doubles as the input for
# `spec/temporal/workflow_replay_fixtures_cold_worker_spec.rb`.

ENV["RAILS_ENV"] = "test"
ENV.delete("CI")
ENV["PAID_SKIP_DATABASE_RUNTIME_ROLE_GUARD"] = "true"

require_relative "../../config/environment"

begin
  original_verbose = $VERBOSE
  $VERBOSE = nil
  require "temporalio/client"
  require "temporalio/worker"
  require "temporalio/worker/workflow_replayer"
  require "temporalio/workflow_history"
ensure
  $VERBOSE = original_verbose
end
require "paid/temporal_data_converter"

module Script
  module Temporal
    class ReplayColdWorker # @spec TEMPORAL-ORCHESTRATION-023
      FIXTURE_DIR = Rails.root.join("spec/fixtures/temporal/replay_histories")
      EVOLUTION_WORKFLOWS = %w[
        coordination_policy_evolution_workflow
        prompt_evolution_workflow
        strategy_evolution_workflow
      ].freeze
      COLD_NAMESPACES = %w[CoordinationPolicyEvolution PromptEvolution StrategyEvolution].freeze

      def self.call
        new.call
      end

      # @return [Boolean] true when every namespace stayed cold and every
      #   history replayed without a replay failure.
      def call
        cold = pending_autoload_namespaces
        require_worker_files
        replays = EVOLUTION_WORKFLOWS.to_h { |name| [ name, replay_failure_for(name) ] }
        puts JSON.pretty_generate({ "cold" => cold, "replays" => replays })
        replays.values.none? && cold.values.all?
      end

      private

      # Mirror `bin/temporal_worker` boot: plain Rails boot (no eager load),
      # then explicit requires of every activity and workflow file.
      def require_worker_files
        Dir[Rails.root.join("app/temporal/activities/**/*.rb")].each { |f| require f }
        Dir[Rails.root.join("app/temporal/workflows/**/*.rb")].each { |f| require f }
      end

      # `Module#autoload?` reports a pending autoload without triggering it,
      # unlike `const_defined?`.
      def pending_autoload_namespaces
        COLD_NAMESPACES.to_h { |name| [ name, !Object.autoload?(name.to_sym).nil? ] }
      end

      def replay_failure_for(name)
        history = Temporalio::WorkflowHistory.from_history_json(
          FIXTURE_DIR.join("#{name}.json").read
        )
        Temporalio::Worker::WorkflowReplayer.new(
          workflows: [ "Workflows::#{name.camelize}".constantize ],
          data_converter: Paid::TemporalDataConverter.new,
          logger: Logger.new(nil),
          workflow_failure_exception_types: [ Exception ]
        ).replay_workflow(history, raise_on_replay_failure: false).replay_failure
      end
    end
  end
end

exit(Script::Temporal::ReplayColdWorker.call ? 0 : 1)
