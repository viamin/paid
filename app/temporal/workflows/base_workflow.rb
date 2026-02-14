# frozen_string_literal: true

require "temporalio/workflow"
require "temporalio/retry_policy"

module Workflows
  # Base class for all Temporal workflows in this application.
  #
  # Inherits from Temporalio::Workflow::Definition as per the temporalio gem v1.2.0 API.
  # Workflows must implement an `execute` method which will be called by the Temporal worker.
  #
  # Temporal serializes all data through JSON, converting symbol keys to strings.
  # InputNormalizer ensures subclasses always receive symbol-keyed hashes.
  # Use `run_activity` instead of `Temporalio::Workflow.execute_activity` to
  # automatically normalize activity return values as well.
  class BaseWorkflow < Temporalio::Workflow::Definition
    module InputNormalizer
      def execute(input)
        super(input.is_a?(Hash) ? input.deep_symbolize_keys : input)
      end
    end

    def self.inherited(subclass)
      super
      subclass.prepend(InputNormalizer)
    end

    DEFAULT_RETRY_POLICY = Temporalio::RetryPolicy.new(
      initial_interval: 1,
      max_interval: 60,
      max_attempts: 3
    )

    def activity_options(timeout: 300)
      {
        start_to_close_timeout: timeout,
        retry_policy: DEFAULT_RETRY_POLICY
      }
    end

    def run_activity(activity_class, input, timeout: 300, **options)
      result = Temporalio::Workflow.execute_activity(
        activity_class,
        input,
        **activity_options(timeout: timeout).merge(options)
      )
      deep_symbolize(result)
    end

    private

    def deep_symbolize(obj)
      case obj
      when Hash then obj.deep_symbolize_keys
      when Array then obj.map { |item| deep_symbolize(item) }
      else obj
      end
    end
  end
end
