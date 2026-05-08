# frozen_string_literal: true

module Automation
  module Strategies
    # Thread-safe registry of strategy classes keyed by scope.
    #
    # Strategies can be registered at four scope levels, checked in
    # descending precedence during lookup:
    #
    #   1. +:task+    — keyed by (strategy_type, task_type)
    #   2. +:project+ — keyed by (strategy_type, project_id)
    #   3. +:account+ — keyed by (strategy_type, account_id)
    #   4. +:global+  — keyed by (strategy_type)
    #
    # Each registration stores the strategy class and an optional hash of
    # constructor keyword arguments, so the caller gets a ready-to-use
    # strategy instance from {#resolve}.
    class Registry
      Registration = Data.define(:strategy_class, :constructor_args)

      def initialize
        @mutex = Mutex.new
        @global = {}
        @account = {}
        @project = {}
        @task = {}
      end

      # Register a strategy at the global scope (lowest precedence).
      def register_global(strategy_type, strategy_class, **constructor_args)
        @mutex.synchronize do
          @global[strategy_type.to_s] = Registration.new(
            strategy_class: strategy_class,
            constructor_args: constructor_args
          )
        end
      end

      # Register a strategy scoped to a specific account.
      def register_account(strategy_type, account_id, strategy_class, **constructor_args)
        @mutex.synchronize do
          @account[[ strategy_type.to_s, account_id ]] = Registration.new(
            strategy_class: strategy_class,
            constructor_args: constructor_args
          )
        end
      end

      # Register a strategy scoped to a specific project.
      def register_project(strategy_type, project_id, strategy_class, **constructor_args)
        @mutex.synchronize do
          @project[[ strategy_type.to_s, project_id ]] = Registration.new(
            strategy_class: strategy_class,
            constructor_args: constructor_args
          )
        end
      end

      # Register a strategy scoped to a specific task type.
      def register_task(strategy_type, task_type, strategy_class, **constructor_args)
        @mutex.synchronize do
          @task[[ strategy_type.to_s, task_type.to_s ]] = Registration.new(
            strategy_class: strategy_class,
            constructor_args: constructor_args
          )
        end
      end

      # Look up the highest-precedence registration for the given
      # {SelectionContext}. Returns +nil+ when nothing matches.
      def resolve(selection_context)
        @mutex.synchronize do
          find_task(selection_context) ||
            find_project(selection_context) ||
            find_account(selection_context) ||
            find_global(selection_context)
        end
      end

      # Remove all registrations. Primarily useful in tests.
      def clear!
        @mutex.synchronize do
          @global.clear
          @account.clear
          @project.clear
          @task.clear
        end
      end

      private

      def find_task(ctx)
        return nil unless ctx.task_type

        @task[[ ctx.strategy_type, ctx.task_type ]]
      end

      def find_project(ctx)
        return nil unless ctx.project

        @project[[ ctx.strategy_type, ctx.project.id ]]
      end

      def find_account(ctx)
        return nil unless ctx.account

        @account[[ ctx.strategy_type, ctx.account.id ]]
      end

      def find_global(ctx)
        @global[ctx.strategy_type]
      end
    end
  end
end
