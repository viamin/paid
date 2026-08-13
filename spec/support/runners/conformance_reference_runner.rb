# frozen_string_literal: true

# Reference implementation of the {ExecutionRunners::Base} contract for the
# RDR-055 no-shared-filesystem conformance suite
# (spec/services/execution_runners/base_no_shared_filesystem_conformance_spec.rb).
#
# Stands in for a future remote runner — Fly machine, Kubernetes job, remote
# Docker — whose only durable link to Paid is the persisted
# {ExecutionRunners::RunnerHandle}. Every byte of state lives in the handle
# plus a runner-owned hash; nothing on this code path touches the host
# filesystem. That makes it a conformance harness for the contract itself: it
# fails if the interface, the value objects, or the handle-persistence lane
# ever grow a host-storage assumption that only a same-host runner could
# satisfy.
class ConformanceReferenceEnvironment
  def initialize
    @state = :provisioned
    @exit_code = nil
    @watchdog = nil
    @released = false
  end

  attr_reader :state, :exit_code, :watchdog

  def start!(watchdog:)
    @state = :running
    @watchdog = watchdog
    self
  end

  def exit!(exit_code:)
    @state = :exited
    @exit_code = exit_code
    self
  end

  def cancel
    return self if @state == :exited

    @state = :exited
    @exit_code = 143
    self
  end

  def release
    @released = true
    self
  end

  def released?
    @released
  end

  def running?
    @state == :running
  end
end

# The reference runner is loaded by spec/rails_helper.rb's spec/support autoload
# and instantiated per example via +let(:runner)+ in
# spec/services/execution_runners/base_no_shared_filesystem_conformance_spec.rb.
class ConformanceReferenceRunner < ExecutionRunners::Base
  def initialize
    super
    @environments = {}
  end

  def self.compatible?(spec:, backend:)
    rejections = []
    rejections << "workspace requires shared host storage" if spec.workspace&.bind_mount?
    rejections << "backend exposes host paths" if backend.supports_host_paths?

    ExecutionRunners::CompatibilityResult.new(
      compatible: rejections.empty?, error_message: rejections.presence&.join("; ")
    )
  end

  def self.ping
    true
  end

  def provision(spec:)
    raise ExecutionRunners::ProvisionError, "workspace requires shared host storage" if spec.workspace&.bind_mount?

    handle = ExecutionRunners::RunnerHandle.new(
      runner_type: :conformance_reference,
      identifier: "conformance-#{SecureRandom.hex(8)}",
      host: "conformance-platform",
      workspace_ref: "conformance-workspace-#{spec.agent_run&.id}",
      metadata: { "agent_run_id" => spec.agent_run&.id, "environment" => spec.environment || {} }
    )
    @environments[handle.identifier] = ConformanceReferenceEnvironment.new
    handle
  end

  # The watchdog parameters (timeout, startup_timeout, idle_timeout,
  # abort_patterns, preparation, heartbeat_path) arrive as one hash: the runner
  # owns watchdog enforcement (RDR-054), so the reference runner records the
  # policy it accepted instead of arming real timers.
  def start(handle:, command:, **watchdog)
    environment = environment_for!(handle).start!(watchdog: watchdog)
    stdout = "#{command}\n"
    yield(:stdout, stdout) if block_given?
    environment.exit!(exit_code: 0)

    ExecutionRunners::ExecutionResult.success(stdout: stdout, stderr: "", exit_code: 0)
  end

  def running?(handle:)
    @environments[handle.identifier]&.running? || false
  end

  def reconnect(handle:)
    environment_for!(handle)
    self
  end

  # A provisioned-but-not-yet-started environment is live, so it reports
  # +:running+; only a released environment is +:not_found+.
  def status(handle:)
    environment = @environments[handle.identifier]
    return ExecutionRunners::ExecutionStatus.not_found if environment.nil? || environment.released?

    ExecutionRunners::ExecutionStatus.new(
      state: environment.state == :exited ? :exited : :running,
      exit_code: environment.exit_code, oom_killed: false, memory_limit: nil
    )
  end

  def cancel(handle:)
    environment = @environments[handle.identifier]
    return nil if environment.nil? || environment.state == :exited

    environment.cancel
    nil
  end

  # A graceful teardown stops the workload first; a forced teardown releases
  # the environment outright. Both are idempotent and need nothing but the
  # handle.
  def cleanup(handle:, force: false)
    environment = @environments[handle.identifier]
    return nil if environment.nil?

    environment.cancel unless force
    environment.release
    @environments.delete(handle.identifier)
    nil
  end

  private

  def environment_for!(handle)
    @environments.fetch(handle.identifier) do
      raise ExecutionRunners::ProvisionError, "no execution environment for #{handle.identifier}"
    end
  end
end
