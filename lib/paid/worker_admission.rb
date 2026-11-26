# frozen_string_literal: true

require "securerandom"

module Paid
  module WorkerAdmission
    PROTOCOL = 1
    SCOPE = "paid-workflow-and-remote-activity"
    PROFILE_FIELDS = %w[activity_slots activity_task_polls local_activity_slots workflow_slots workflow_task_polls].freeze
    ROLE_SETS = [ [ "agent" ], [ "poll" ], [ "agent", "poll" ] ].freeze

    module_function

    def lock_path(readiness_file)
      "#{readiness_file}.admission.lock"
    end

    def request_path(readiness_file)
      "#{readiness_file}.admission.request"
    end

    # Capture once at worker boot, before readiness is published. A later
    # checkout or changing environment cannot rewrite this process identity.
    # @spec TEMPORAL-ORCHESTRATION-021
    def boot_identity(workspace:, revision:, profiles:)
      raise ArgumentError, "unknown boot revision" unless revision.to_s.match?(/\A[0-9a-f]{40}\z/)
      raise ArgumentError, "unknown worker roles" unless ROLE_SETS.include?(profiles.keys.sort)

      normalized_profiles = profiles.transform_values do |profile|
        raise ArgumentError, "incomplete worker profile" unless profile.keys.sort == PROFILE_FIELDS

        profile.transform_values do |value|
          Integer(value).tap { |count| raise ArgumentError, "worker profile must be positive" unless count.positive? }
        end.freeze
      end.freeze

      {
        "protocol" => PROTOCOL,
        "scope" => SCOPE,
        "boot_id" => SecureRandom.uuid.freeze,
        "pid" => Process.pid,
        "process_start_ticks" => process_start_ticks,
        "workspace" => File.realpath(workspace).freeze,
        "revision" => revision.dup.freeze,
        "profiles" => normalized_profiles
      }.freeze
    end

    def process_start_ticks
      # /proc stat's comm field may contain spaces or parentheses. Fields
      # after its final ')' begin with field 3; starttime is field 22.
      stat = File.read("/proc/self/stat")
      Integer(stat[(stat.rindex(")") + 2)..].split.fetch(19))
    end
  end
end
