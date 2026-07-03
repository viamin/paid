# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
ENV["PAID_SKIP_DATABASE_RUNTIME_ROLE_GUARD"] = "true"

require_relative "../../config/environment"
require "fileutils"
require "temporalio/testing"
require "temporalio/worker"

Rails.application.eager_load!

module Script
  module Temporal
    class ExportReplayHistories
      FIXTURE_DIR = Rails.root.join("spec/fixtures/temporal/replay_histories")
      TASK_QUEUE = Paid::AGENT_TASK_QUEUE

      def self.call
        new.call
      end

      def call
        FileUtils.mkdir_p(FIXTURE_DIR)

        Temporalio::Testing::WorkflowEnvironment.start_time_skipping do |environment|
          worker = Temporalio::Worker.new(
            client: environment.client,
            task_queue: TASK_QUEUE,
            activities: WorkflowReplayFixtures.activity_definitions,
            workflows: WorkflowReplayFixtures.workflow_classes,
            workflow_failure_exception_types: [ Exception ]
          )

          worker_thread = Thread.new { worker.run }
          export_histories(environment)
        ensure
          worker_thread&.kill
          worker_thread&.join
        end
      end

      private

      def export_histories(environment)
        WorkflowReplayFixtures.workflow_classes.each do |workflow_class|
          scenario = WorkflowReplayFixtures.scenario_for(workflow_class)
          workflow_id = "replay-history-#{workflow_class.name.demodulize.underscore}"
          handle = environment.client.start_workflow(
            workflow_class,
            scenario.input,
            id: workflow_id,
            task_queue: TASK_QUEUE
          )

          handle.result

          fixture_path_for(workflow_class).write(handle.fetch_history.to_history_json)
        end
      end

      def fixture_path_for(workflow_class)
        FIXTURE_DIR.join("#{workflow_class.name.demodulize.underscore}.json")
      end
    end
  end
end

Script::Temporal::ExportReplayHistories.call
