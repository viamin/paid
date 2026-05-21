# frozen_string_literal: true

module TemporalPatchGuards
  GuardStatus = Data.define(:entry, :oldest_running_start_time, :eligible) do
    delegate :introduced_on, :name, :sunset_at, :workflow_type, to: :entry
  end

  Report = Data.define(:statuses) do
    def eligible_guards
      statuses.select(&:eligible)
    end

    def workflow_summaries
      statuses.group_by(&:workflow_type).map do |workflow_type, workflow_statuses|
        {
          workflow_type: workflow_type,
          oldest_running_start_time: workflow_statuses.first.oldest_running_start_time,
          eligible_guard_names: workflow_statuses.select(&:eligible).map(&:name),
          tracked_guard_names: workflow_statuses.map(&:name)
        }
      end.sort_by { |summary| summary[:workflow_type] }
    end

    def to_text
      workflow_summaries.map do |summary|
        oldest = summary[:oldest_running_start_time]&.utc&.iso8601 || "none"
        eligible = summary[:eligible_guard_names].presence || [ "none" ]
        tracked = summary[:tracked_guard_names].join(", ")
        <<~TEXT.chomp
          #{summary[:workflow_type]}
            oldest_running_start_time: #{oldest}
            tracked_guards: #{tracked}
            eligible_guards: #{eligible.join(", ")}
        TEXT
      end.join("\n")
    end
  end

  class Sweep
    def initialize(client: Paid.temporal_client, entries: Registry.entries)
      @client = client
      @entries = entries
    end

    def call
      oldest_running_by_workflow = @entries.map(&:workflow_type).uniq.index_with do |workflow_type|
        oldest_running_start_time_for(workflow_type)
      end

      statuses = @entries.map do |entry|
        oldest_running_start_time = oldest_running_by_workflow.fetch(entry.workflow_type)
        GuardStatus.new(
          entry: entry,
          oldest_running_start_time: oldest_running_start_time,
          eligible: oldest_running_start_time.nil? || oldest_running_start_time > entry.sunset_at
        )
      end

      Report.new(statuses:)
    end

    private

    def oldest_running_start_time_for(workflow_type)
      @client.list_workflows(running_workflow_query(workflow_type))
        .min_by(&:start_time)
        &.start_time
    end

    def running_workflow_query(workflow_type)
      sanitized_workflow_type = workflow_type.gsub("\\", "\\\\\\\\").gsub("'", "\\\\'")
      "WorkflowType = '#{sanitized_workflow_type}' AND ExecutionStatus = 'Running'"
    end
  end
end
