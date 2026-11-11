# frozen_string_literal: true

require_relative "worker_readiness"

module Paid
  module TemporalWorkerShutdown
    module_function

    # @spec TEMPORAL-ORCHESTRATION-013
    def install(request_shutdown:, forced_exit_timeout:)
      shutdown_started = false
      readiness_path = Paid::WorkerReadiness.file_path

      %w[INT TERM].each do |signal|
        Signal.trap(signal) do
          if shutdown_started
            begin
              File.delete(readiness_path)
            rescue SystemCallError
              # A concurrent shutdown thread may already have removed it.
            end
            exit! 1
          end

          shutdown_started = true
          Thread.new do
            warn "Received #{signal}, shutting down Temporal workers gracefully"
            Paid::WorkerReadiness.mark_not_ready!
            Thread.new do
              sleep(forced_exit_timeout)
              warn "Temporal workers did not exit within #{forced_exit_timeout}s, forcing exit"
              exit! 1
            end
            request_shutdown.call(reason: "#{signal} received")
          end
        end
      end
    end
  end
end
