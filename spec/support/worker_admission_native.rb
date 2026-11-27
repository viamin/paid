# frozen_string_literal: true

require "bundler/setup"
require "json"
require "tmpdir"
require "securerandom"
require "temporalio/client"
require "temporalio/testing"
require "temporalio/worker"
require_relative "../../bin/lib/worker_admission_slot_supplier"
require_relative "../../lib/paid/temporal_data_converter"

module WorkerAdmissionNative
  class Collect < Temporalio::Activity::Definition
    def execute(value)
      3.times do
        GC.start
        Temporalio::Activity::Context.current.heartbeat(value)
      end
      value
    end
  end

  class Lifecycle < Temporalio::Workflow::Definition
    def execute(value)
      remote = Temporalio::Workflow.execute_activity(Collect, value,
        start_to_close_timeout: 15, heartbeat_timeout: 5)
      Temporalio::Workflow.execute_local_activity(Collect, remote, start_to_close_timeout: 15)
    end
  end

  class AwaitCancellation < Temporalio::Activity::Definition
    def initialize(started)
      super()
      @started = started
    end

    def execute
      @started << true
      context = Temporalio::Activity::Context.current
      wakeup = Queue.new
      context.cancellation.add_cancel_callback { wakeup << true }
      loop do
        context.heartbeat
        context.cancellation.check!
        wakeup.pop(timeout: 0.05)
      end
    end
  end

  class CancelLifecycle < Temporalio::Workflow::Definition
    def execute
      Temporalio::Workflow.execute_activity(AwaitCancellation, start_to_close_timeout: 15)
    end
  end

  def self.run
    Dir.mktmpdir("paid-native-slots") do |directory|
      readiness_file = File.join(directory, "ready")
      started = Queue.new
      Temporalio::Testing::WorkflowEnvironment.start_local(
        data_converter: Paid::TemporalDataConverter.new,
        dev_server_existing_path: ENV["TEMPORAL_CLI_PATH"],
        dev_server_startup_timeout: 30
      ) do |environment|
        queue = "paid-native-slots-#{SecureRandom.uuid}"
        worker = Temporalio::Worker.new(
          client: environment.client, task_queue: queue,
          activities: [ Collect, AwaitCancellation.new(started) ],
          workflows: [ Lifecycle, CancelLifecycle ],
          tuner: Paid::WorkerAdmission.tuner(workflow_slots: 4, activity_slots: 4,
            local_activity_slots: 4, workflow_task_polls: 4, activity_task_polls: 4, readiness_file:),
          **Paid::WorkerAdmission::WORKFLOW_POLLER_OPTIONS,
          **Paid::WorkerAdmission.poller_options(workflow_task_polls: 4, activity_task_polls: 4)
        )
        worker.run do
          8.times do |batch|
            handles = 4.times.map do |index|
              value = batch * 4 + index
              environment.client.start_workflow(Lifecycle, value, id: "lifecycle-#{value}",
                task_queue: queue, execution_timeout: 30)
            end
            handles.each_with_index do |handle, index|
              raise "incorrect activity result" unless handle.result == batch * 4 + index
            end
          end
          handle = environment.client.start_workflow(CancelLifecycle,
            id: "cancel-lifecycle", task_queue: queue, execution_timeout: 30)
          started.pop
          handle.cancel
          begin
            handle.result
            raise "workflow ignored cancellation"
          rescue Temporalio::Error::WorkflowFailedError => error
            raise unless error.cause.is_a?(Temporalio::Error::CanceledError)
          end
        end
      end
      GC.start
      File.open(Paid::WorkerAdmission.lock_path(readiness_file), File::RDWR) do |lock|
        raise "admission lock leaked" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      end
      puts JSON.generate(sdk: Temporalio::VERSION, workflows_completed: 32, cancellation: true, admission_released: true) # rubocop:disable RSpec/Output -- Subprocess acceptance result.
    end
  end
end

WorkerAdmissionNative.run if $PROGRAM_NAME == __FILE__
