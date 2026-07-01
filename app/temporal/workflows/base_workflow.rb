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
    DECOMPOSITION_POLICY_METADATA_KEYS = %i[
      policy_source
      skip_reason
      policy_key
      coordination_policy_id
      coordination_policy_version_id
      coordination_policy_version
    ].freeze

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

    def run_cleanup_activity(activity_class, input, timeout: 300, **options)
      detached_cancellation, = Temporalio::Cancellation.new
      run_activity(activity_class, input, timeout: timeout, cancellation: detached_cancellation, **options)
    end

    private

    def raise_if_canceled!(error)
      raise error if error.is_a?(Temporalio::Error::CanceledError)

      cause = error.respond_to?(:cause) ? error.cause : nil
      raise error if cause.is_a?(Temporalio::Error::CanceledError)

      current_error = error
      while current_error
        raise error if current_error.class.name.end_with?("CanceledError")

        current_error = current_error.respond_to?(:cause) ? current_error.cause : nil
      end

      raise error if Temporalio::Error.canceled?(error)
    end

    def feature_flag_enabled?(flag_name, project_id:)
      snapshot = feature_flag_snapshot_for(project_id)
      return false if snapshot[:project_missing]

      snapshot.fetch(:flags, {}).fetch(flag_name.to_sym, false)
    end

    def feature_flag_snapshot_for(project_id)
      @feature_flags_by_project ||= {}
      @feature_flags_by_project[project_id] ||= begin
        run_activity(Activities::LoadFeatureFlagsActivity, { project_id: project_id }, timeout: 10)
      end
    end

    def deep_symbolize(obj)
      case obj
      when Hash then obj.deep_symbolize_keys
      when Array then obj.map { |item| deep_symbolize(item) }
      else obj
      end
    end

    def decomposition_policy_metadata(decompose_result)
      payload = decompose_result.to_h.deep_symbolize_keys
      top_level_metadata = payload.slice(*DECOMPOSITION_POLICY_METADATA_KEYS)
      nested_metadata = payload[:policy_metadata]

      return top_level_metadata.compact unless nested_metadata.respond_to?(:to_h)

      top_level_metadata.merge(
        nested_metadata.to_h.deep_symbolize_keys.slice(*DECOMPOSITION_POLICY_METADATA_KEYS)
      ).compact
    end

    def decomposition_policy_metadata_from_error(error)
      return {} unless error.is_a?(Temporalio::Error::ApplicationError)

      Array(error.details).each do |detail|
        next unless detail.respond_to?(:to_h)

        metadata = decomposition_policy_metadata(detail)
        return metadata if metadata.present?
      end

      {}
    end
  end
end
