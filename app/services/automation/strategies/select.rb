# frozen_string_literal: true

module Automation
  module Strategies
    # Selects a strategy instance based on project, task, and runtime
    # context. Implements a four-tier precedence lookup (task → project →
    # account → global) with a safe fallback to built-in defaults when
    # no specialized registration matches.
    #
    # == Usage
    #
    #   strategy = Automation::Strategies::Select.call(
    #     strategy_type: :auto_pick,
    #     project: project
    #   )
    #   result = strategy.evaluate(context)
    #
    # == Fallback behavior
    #
    # When the registry has no registration for the requested
    # +strategy_type+ at any scope, the service falls back to the
    # built-in default strategies. If no default exists either, it
    # returns a +NullStrategy+ that always produces a noop result,
    # ensuring callers never receive +nil+.
    class Select
      DEFAULTS = {
        "auto_pick" => AutoPick,
        "auto_continue" => AutoContinue,
        "auto_review" => AutoReview,
        "auto_merge" => AutoMerge
      }.freeze

      attr_reader :strategy_type, :project, :account, :task_type, :metadata

      def initialize(strategy_type:, project: nil, account: nil, task_type: nil, metadata: nil, registry: nil)
        @strategy_type = strategy_type.to_s
        @project = project
        @account = account
        @task_type = task_type
        @metadata = metadata
        @registry = registry
      end

      def self.call(**args)
        new(**args).call
      end

      # Returns a strategy instance ready for +#evaluate(context)+.
      def call
        selection_context = SelectionContext.build(
          strategy_type: strategy_type,
          project: project,
          account: account,
          task_type: task_type,
          metadata: metadata
        )

        registration = resolve_registration(selection_context)
        instantiate(registration)
      end

      private

      def resolve_registration(selection_context)
        registry.resolve(selection_context)
      end

      def registry
        @registry || self.class.default_registry
      end

      def instantiate(registration)
        if registration
          registration.strategy_class.new(**registration.constructor_args)
        else
          fallback_instance
        end
      end

      def fallback_instance
        klass = DEFAULTS[strategy_type]
        return NullStrategy.new unless klass

        klass.new
      end

      class << self
        def default_registry
          @default_registry ||= build_default_registry
        end

        # Replace the default registry. Returns the previous registry
        # so callers can restore it (useful in tests).
        def default_registry=(registry)
          @default_registry = registry
        end

        # Reset to built-in defaults. Primarily useful in tests.
        def reset_default_registry!
          @default_registry = build_default_registry
        end

        private

        def build_default_registry
          Registry.new.tap do |r|
            DEFAULTS.each do |type, klass|
              r.register_global(type, klass)
            end
          end
        end
      end
    end
  end
end
