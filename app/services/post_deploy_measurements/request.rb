# frozen_string_literal: true

module PostDeployMeasurements
  # Creates (idempotently) a trusted post-deploy measurement request bound
  # to an issue, an exact acceptance criterion, and — when supplied — the
  # prerequisite occurrence the evidence may release. Only allowlisted
  # checks are requestable; duplicate requests and events converge on the
  # existing pending row, guarded by the table's unique idempotency key.
  # @spec POST-DEPLOY-001 @spec POST-DEPLOY-004
  class Request
    class Unauthorized < StandardError; end

    Result = Data.define(:measurement, :created) do
      def created? = created
    end

    def self.call(...) = new(...).call

    def initialize(issue:, check_key:, criterion:, actor: nil, prerequisite_identity: nil)
      @issue = issue
      @check_key = check_key.to_s
      @criterion = criterion.to_s.strip
      @actor = actor
      @prerequisite_identity = prerequisite_identity.presence
    end

    def call
      validate!
      # Pending rows hold the empty-revision sentinel, so every duplicate
      # request or event while a generation is unmeasured lands on one row;
      # an executed row keeps its stamped revision and a new deployment
      # generation starts a fresh evidence record instead of overwriting.
      measurement = PostDeployMeasurement.create_or_find_by!(
        issue: issue, check_key: check_key, check_version: check.version, deployed_revision: ""
      ) { |record| assign_new(record) }
      created = measurement.previously_new_record?
      measurement.update!(
        criterion: criterion,
        prerequisite_identity: prerequisite_identity || measurement.prerequisite_identity,
        requested_by: actor || measurement.requested_by
      )
      Result.new(measurement: measurement, created: created)
    end

    private

    attr_reader :issue, :check_key, :criterion, :actor, :prerequisite_identity

    def validate!
      raise Registry::UnknownCheck, "check #{check_key.inspect} is not allowlisted" unless check
      raise ArgumentError, "criterion is required" if criterion.blank?
      if actor && actor.account_id != issue.project.account_id
        raise Unauthorized, "actor is not a member of the measurement's account"
      end
    end

    def check
      @check ||= Registry.find(check_key)
    end

    def assign_new(record)
      record.attributes = {
        project: issue.project, account: issue.project.account,
        criterion: criterion, prerequisite_identity: prerequisite_identity,
        requested_by: actor, status: "pending",
        details: { "check" => check_descriptor,
                   "next_action" => "Runs automatically once the target revision is deployed." }
      }
    end

    def check_descriptor
      { "key" => check.key, "version" => check.version, "baseline" => check.baseline,
        "target" => check.target, "criterion" => check.criterion }
    end
  end
end
