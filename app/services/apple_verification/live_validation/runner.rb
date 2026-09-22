# frozen_string_literal: true

module AppleVerification
  module LiveValidation
    # Executes the acceptance suite and records fail-closed evidence: a
    # scenario passes only when the live run observed the expected outcome,
    # and anything not executable on this host is a gap, never a pass.
    # @spec APPLE-LIVE-002
    # @spec APPLE-LIVE-004
    # @spec APPLE-LIVE-005
    # @spec APPLE-LIVE-006
    class Runner
      MIN_DISK_FREE_GIB = 60
      MIN_MEMORY_FREE_PERCENT = 25
      MAX_ACTIVE_VMS = 1
      MIN_AGENT_CONTAINERS = 3
      # A sample missing any of these figures is degraded (incomplete host
      # readiness) and cannot be compared against the thresholds.
      CAPACITY_KEYS = %w[agent_containers disk_free_gib memory_free_percent active_apple_vms].freeze
      RUNBOOK = "docs/rdrs/live-validation-runbook-rdr-068.md"

      RECOVERY_CHOREOGRAPHY = {
        "recovery-cancellation" => :converge_cancellation,
        "recovery-timeout" => :converge_timeout,
        "recovery-control-plane-restart" => :converge_control_plane_restart,
        "recovery-host-restart" => :converge_host_restart,
        "recovery-partial-provisioning" => :converge_partial_provisioning,
        "recovery-orphan-discovery" => :converge_orphan_discovery
      }.freeze

      def initialize(config)
        @config = config
        @seen_vm_ids = Hash.new { |hash, key| hash[key] = [] }
        @capacity_samples = []
        @started_at = Time.current
      end

      def run
        evidence = [
          *functional_evidence,
          *recovery_evidence,
          *network_evidence,
          *isolation_evidence,
          *capacity_evidence,
          archive_gap
        ]
        Result.new(started_at: @started_at, finished_at: Time.current, repeats: @config.repeats,
          environment: @config.environment, evidence:)
      end

      private

      attr_reader :config

      def ports = config.ports

      def suite = config.suite

      def functional_evidence
        suite.group(:functional).flat_map { |scenario| (1..config.repeats).map { |repeat| functional_repeat(scenario, repeat) } }
      end

      def functional_repeat(scenario, repeat)
        request_id = "#{config.run_key}:#{scenario.id}:r#{repeat}"
        identifier = nil
        problem = nil
        begin
          identifier = provision_vm(scenario, request_id)
          problem = reuse_problem(scenario, identifier) || dispatch_problem(scenario)
        rescue StandardError => error
          problem = "#{error.class.name}: #{error.message}"
        end
        # Teardown is unconditional: an earlier failure in the repeat must
        # not leak the clean-clone VM for the next repeat.
        teardown_problem = identifier ? teardown_vm(identifier, request_id) : nil
        problem ||= teardown_problem || inventory_problem
        record(scenario.id, problem ? :failed : :passed,
          problem ? "#{problem} (vm=#{identifier})" : "clean clone vm=#{identifier}: build, test, launch, capture, export succeeded")
      end

      def provision_vm(scenario, request_id)
        handle = ports.lifecycle.provision(
          agent_run: config.agent_run, image_id: config.image_id, profile_id: config.profile_id, request_id:
        )
        sample_capacity
        identifier_for(handle)
      end

      def identifier_for(handle)
        handle.respond_to?(:identifier) ? handle.identifier : handle.to_s
      end

      def reuse_problem(scenario, identifier)
        seen = @seen_vm_ids[scenario.id]
        problem = "provider reused VM #{identifier} for a new repeat; not a clean clone" if seen.include?(identifier)
        seen << identifier
        problem
      end

      def dispatch_problem(scenario)
        operations = ports.dispatcher.call(
          scenario_id: scenario.id,
          manifest: FunctionalManifests.for(scenario.id, source_digest: config.source_digest),
          agent_run: config.agent_run
        )
        failure = operations.find { |operation| operation["status"] != "succeeded" }
        "operation #{failure.fetch('type')} reported #{failure.fetch('status')}" if failure
      end

      def teardown_vm(identifier, request_id)
        ports.lifecycle.destroy(agent_run: config.agent_run, vm_id: identifier, request_id: "#{request_id}:destroy")
        nil
      rescue StandardError => error
        "teardown failed: #{error.class.name}: #{error.message}"
      end

      def inventory_problem
        inventory_problem_for(config.agent_run)
      end

      def recovery_evidence
        suite.group(:recovery).map do |scenario|
          method(RECOVERY_CHOREOGRAPHY.fetch(scenario.id)).call
        rescue StandardError => error
          record(scenario.id, :failed, "#{error.class.name}: #{error.message}")
        end
      end

      def converge_cancellation
        run = fresh_run
        provision_recovery_vm(run, "recovery-cancellation")
        # The reconciler's tag discovery never claims a resource whose run
        # is still capacity-in-flight, so the choreography must move the run
        # out of the in-flight set first, mirroring the production
        # cancellation lane.
        run.update!(status: "cancelled", completed_at: Time.current)
        ports.lifecycle.request_cleanup!(agent_run: run)
        problem = convergence_problem(run)
        record("recovery-cancellation", problem ? :failed : :passed,
          problem || "VM destroyed; ledger entries deleted; inventory empty", ledger_references(run))
      end

      def converge_timeout
        if ports.timeout_policy.nil?
          record("recovery-timeout", :gap,
            "no timeout policy configured; attempt timeout enforcement ships with #3936 and must be live-tested once it lands")
        else
          record("recovery-timeout", :gap,
            "timeout policy configured but the live timeout choreography needs an operator-interrupted attempt; see #{RUNBOOK}")
        end
      end

      def converge_control_plane_restart
        run = fresh_run
        request_id = "#{config.run_key}:recovery-control-plane-restart"
        first = provision_recovery_vm(run, "recovery-control-plane-restart", request_id:)
        second = provision_recovery_vm(run, "recovery-control-plane-restart", request_id:)
        problem = "re-provision returned #{second} after #{first}" unless first == second
        problem ||= "intent not linked after re-provision" unless intent_linked?(run, request_id)
        problem ||= "ledger entry not active after re-provision" if active_entries(run).empty?
        # The re-linked VM must not leak: finish the run so the reconciler
        # can claim the resource, then converge through the cleanup lane.
        run.update!(status: "completed", completed_at: Time.current)
        ports.lifecycle.request_cleanup!(agent_run: run)
        problem ||= convergence_problem(run)
        record("recovery-control-plane-restart", problem ? :failed : :passed,
          problem || "re-linked #{first}; intent linked; ledger entry active; VM reconciled after teardown",
          ledger_references(run))
      end

      def converge_host_restart
        run = fresh_run
        identifier = provision_recovery_vm(run, "recovery-host-restart")
        ports.lifecycle.stop(agent_run: run, vm_id: identifier, request_id: "#{config.run_key}:recovery-host-restart:stop")
        # As with cancellation: reconciliation can only claim the stopped
        # VM once the run leaves the capacity-in-flight set.
        run.update!(status: "cancelled", completed_at: Time.current)
        ports.lifecycle.request_cleanup!(agent_run: run)
        problem = convergence_problem(run)
        record("recovery-host-restart", problem ? :failed : :passed,
          problem || "stopped VM destroyed through reconciliation; ledger entries deleted; inventory empty",
          ledger_references(run))
      end

      def converge_partial_provisioning
        run = fresh_run
        failure = provisioning_failure_for(run)
        problem = "ledger entries left active" if active_entries(run).any?
        problem ||= inventory_problem_for(run)
        # No VM exists, but the run must still leave the in-flight set so
        # it stops counting against the project's capacity.
        run.update!(status: "failed", completed_at: Time.current)
        record("recovery-partial-provisioning", problem ? :failed : :passed,
          problem || "provisioning failure converged (#{failure.class.name}): no VM left; no active ledger entry",
          ledger_references(run))
      end

      def provisioning_failure_for(run)
        provision_recovery_vm(run, "recovery-partial-provisioning", profile_id: "#{config.profile_id}-missing")
        "accepting an invalid profile"
      rescue StandardError => error
        error
      end

      def converge_orphan_discovery
        run = fresh_run
        provision_recovery_vm(run, "recovery-orphan-discovery")
        run.update!(status: "completed", completed_at: Time.current)
        if ports.reconciler.nil?
          return record("recovery-orphan-discovery", :gap, "no reconciler configured; orphan discovery needs the shipped reconciler")
        end

        ports.reconciler.call
        problem = "ledger entries not deleted" if entries_for(run).where.not(status: "deleted").exists?
        record("recovery-orphan-discovery", problem ? :failed : :passed,
          problem || "orphaned VM reconciled after its run completed; ledger entries deleted", ledger_references(run))
      end

      def provision_recovery_vm(run, scenario_id, request_id: "#{config.run_key}:#{scenario_id}", profile_id: config.profile_id)
        identifier_for(ports.lifecycle.provision(agent_run: run, image_id: config.image_id, profile_id:, request_id:))
      end

      def convergence_problem(run)
        return "ledger entries not deleted" if entries_for(run).where.not(status: "deleted").exists?

        inventory_problem_for(run)
      end

      def inventory_problem_for(run)
        remaining = ports.lifecycle.inventory(agent_run: run)
        "VM left in inventory after teardown: #{remaining.inspect}" if remaining.any?
      end

      def network_evidence
        contract = AgentRuns::AppleVerification::ResolveGuestContract.call(agent_run: config.agent_run)
        config.network_probes.run(agent_run: config.agent_run, contract:)
      rescue StandardError => error
        suite.group(:network_policy).map do |scenario|
          record(scenario.id, :gap, "guest contract resolution failed: #{error.class.name}: #{error.message}")
        end
      end

      def isolation_evidence
        suite.group(:isolation).map { |scenario| isolation_row(scenario) }
      end

      def isolation_row(scenario)
        provider = ports.diagnostics
        if provider.nil?
          return record(scenario.id, :gap,
            "no guest diagnostics provider configured; collect via the guest executor's diagnostics on the macOS host (see #{RUNBOOK})")
        end

        result = provider.call(probe_id: scenario.id)
        case result["status"]
        when "denied" then record(scenario.id, :passed, "guest denied: #{result["detail"]}")
        when "exposed" then record(scenario.id, :failed, "guest exposure observed: #{result["detail"]}")
        else record(scenario.id, :gap, "probe unavailable: #{result["detail"]}")
        end
      rescue StandardError => error
        record(scenario.id, :gap, "diagnostics provider failed: #{error.class.name}: #{error.message}")
      end

      def capacity_evidence
        scenario = suite.group(:capacity).first
        if ports.capacity_sampler.nil?
          return [ record(scenario.id, :gap, "no capacity sampler configured; see #{RUNBOOK}") ]
        end
        if @capacity_samples.empty?
          return [ record(scenario.id, :gap, "no capacity samples collected; run functional scenarios with a sampler wired") ]
        end

        samples = complete_capacity_samples
        if samples.empty?
          return [ record(scenario.id, :gap, "capacity samples were degraded (incomplete host readiness); no complete sample to evaluate") ]
        end

        problems = threshold_problems(samples)
        record(scenario.id, problems.empty? ? :passed : :failed, "#{capacity_figure(samples)}; #{problems.join('; ')}")
      end

      def complete_capacity_samples
        @capacity_samples.select { |sample| CAPACITY_KEYS.all? { |key| sample.key?(key) } }
      end

      def threshold_problems(samples)
        problems = samples.filter_map do |sample|
          disk = sample.fetch("disk_free_gib").to_f
          memory = sample.fetch("memory_free_percent").to_f
          vms = sample.fetch("active_apple_vms").to_i
          if disk < MIN_DISK_FREE_GIB
            "disk free #{disk} GiB below the #{MIN_DISK_FREE_GIB} GiB admission threshold"
          elsif memory < MIN_MEMORY_FREE_PERCENT
            "memory free #{memory}% below the #{MIN_MEMORY_FREE_PERCENT}% admission threshold"
          elsif vms > MAX_ACTIVE_VMS
            "#{vms} active Apple VMs exceed the #{MAX_ACTIVE_VMS} VM limit"
          end
        end
        containers = samples.map { |sample| sample.fetch("agent_containers").to_i }.min
        problems << "only #{containers} agent containers active; three required" if containers < MIN_AGENT_CONTAINERS
        problems
      end

      def capacity_figure(samples)
        format("agent containers: %s; disk free: %s GiB; memory free: %s%%; active Apple VMs: %s",
          integer_range(samples, "agent_containers"), decimal_range(samples, "disk_free_gib"),
          decimal_range(samples, "memory_free_percent"), integer_range(samples, "active_apple_vms"))
      end

      def integer_range(samples, key)
        values = samples.map { |sample| sample.fetch(key).to_i }
        "#{values.min}-#{values.max}"
      end

      def decimal_range(samples, key)
        values = samples.map { |sample| sample.fetch(key).to_f }
        format("%.1f-%.1f", values.min, values.max)
      end

      def sample_capacity
        sample = ports.capacity_sampler&.call
        @capacity_samples << sample if sample.is_a?(Hash)
      end

      def archive_gap
        record("report-archived-under-docs-rdrs", :gap,
          "report not yet written; the harness records this row as passed only after the archive file is written under docs/rdrs/")
      end

      def fresh_run
        factory = ports.run_factory
        raise "no run factory configured for recovery choreographies" if factory.nil?

        factory.call
      end

      def intent_linked?(run, request_id)
        ProvisioningIntent.where(agent_run: run, runner_type: "apple_tart", request_id:, status: "linked").exists?
      end

      def active_entries(run)
        entries_for(run).where(status: "active")
      end

      def entries_for(run)
        ExecutionResourceLedgerEntry.where(agent_run: run, runner_type: "apple_tart")
      end

      def ledger_references(run)
        entries_for(run).pluck(:id).map { |id| { "kind" => "execution_resource_ledger_entry", "id" => id } }
      end

      def record(scenario_id, status, detail, references = [])
        Evidence.new(scenario_id:, status:, detail:, references:, recorded_at: Time.current)
      end
    end
  end
end
