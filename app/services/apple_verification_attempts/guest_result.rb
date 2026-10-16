# frozen_string_literal: true

module AppleVerificationAttempts
  # Reduces closed-protocol guest operation results to an attempt terminal
  # outcome. Transport acceptance is deliberately not a verification result:
  # every operation required by the approved revision must have been dispatched
  # and must report success before an attempt can satisfy a completion gate.
  # Advisory operations still run and remain in the guest's result, but their
  # failure cannot turn a successful required verification into a gate failure.
  # @spec APPLE-ATTEMPT-009
  # @spec APPLE-ATTEMPT-012
  class GuestResult
    Outcome = Data.define(:status, :failure_classification)

    SUCCESS = "succeeded"
    REQUIRED_OPERATION_TYPES = {
      "test" => "test"
    }.freeze

    def self.call(revision:, manifest:, operations:)
      new(revision:, manifest:, operations:).call
    end

    def initialize(revision:, manifest:, operations:)
      @revision = revision
      @manifest = manifest
      @operations = operations
    end

    def call
      operation_with_failure = failed_required_operation
      return failed(classification_for(operation_with_failure)) if operation_with_failure

      return failed("worker_infrastructure") unless required_operations_reported?
      return failed("project_configuration") unless required_operations_dispatched?

      succeeded
    end

    private

    def required_operations_dispatched?
      required_operation_types.all? { |type| required_manifest_operation_types.include?(type) }
    end

    def required_operations_reported?
      required_operation_results.all? do |manifest_operation, result_operation|
        result_operation.is_a?(Hash) && result_operation["type"] == manifest_operation["type"]
      end
    end

    def required_operation_types
      Array(@revision.required_checks).map { |check| operation_type_for(check) }.uniq
    end

    def operation_type_for(check)
      return REQUIRED_OPERATION_TYPES.fetch(check.to_s) if REQUIRED_OPERATION_TYPES.key?(check.to_s)

      check.to_s.end_with?(".tests") ? "test" : "capture"
    end

    def required_manifest_operation_types
      required_manifest_operations.filter_map { |operation| operation["type"] if operation.is_a?(Hash) }
    end

    def manifest_operations
      Array(@manifest["operations"])
    end

    def required_operation_results
      manifest_operations.zip(Array(@operations)).select { |operation, _| required?(operation) }
    end

    def required_manifest_operations
      manifest_operations.select { |operation| required?(operation) }
    end

    def failed_required_operation
      required_operation_results.map(&:last).find { |operation| operation_failed?(operation) }
    end

    def required?(operation)
      operation.is_a?(Hash) && operation.fetch("required", true)
    end

    def operation_failed?(operation)
      !operation.is_a?(Hash) || operation["status"] != SUCCESS
    end

    def classification_for(operation)
      return "worker_infrastructure" unless operation.is_a?(Hash)

      case operation["type"]
      when "build" then "compile_or_link"
      when "test" then "test_assertion"
      when "capture" then "required_capture"
      when "boot_simulator", "install_app", "launch_app", "ui_action" then "launch_or_ui_flow"
      else "worker_infrastructure"
      end
    end

    def succeeded
      Outcome.new(status: "succeeded", failure_classification: nil)
    end

    def failed(classification)
      Outcome.new(status: "failed", failure_classification: classification)
    end
  end
end
