# frozen_string_literal: true

# Test doubles for the Apple verification live-validation runner specs.
# They mimic the production port contracts: FakeLifecycle mirrors
# AppleVerification::Lifecycle provisioning semantics (idempotent by
# request id, fresh identifier otherwise) and the shipped cleanup lane
# (request_cleanup! then mark_deleted!), and FakeReconciler mirrors the
# reconciler's tag-discovery convergence for runs that are no longer
# capacity-in-flight.
module AppleLiveValidationFakes
  class FakeLifecycle
    attr_reader :destroyed

    def initialize(identifiers)
      @identifiers = identifiers.dup
      @provisioned = Hash.new { |hash, key| hash[key] = [] }
      @by_request = {}
      @attempts = Hash.new(0)
      @recorded_identifiers = []
      @destroyed = []
      @leaked = []
      @cleaned = []
    end

    def provision(agent_run:, image_id:, profile_id:, request_id:)
      raise ArgumentError, "Unknown Apple worker profile: #{profile_id}" if profile_id.end_with?("-missing")
      return @by_request.fetch(request_id) if @by_request.key?(request_id)

      identifier = @identifiers.shift || "vm-extra-#{@by_request.size}"
      @provisioned[request_id.split(":")[1]] << identifier
      @by_request[request_id] = identifier
      create_records(agent_run:, request_id:, identifier:)
      identifier
    end

    def stop(agent_run:, vm_id:, request_id:)
      "stopped"
    end

    def destroy(agent_run:, vm_id:, request_id:)
      @destroyed << vm_id
      "destroyed"
    end

    def inventory(agent_run:)
      (@provisioned.values.flatten - @destroyed - @cleaned) + @leaked
    end

    def request_cleanup!(agent_run:)
      @cleaned = @provisioned.values.flatten - @destroyed
      entries(agent_run).each do |entry|
        next if entry.status == "deleted"

        entry.request_cleanup! unless entry.cleanup_pending?
        entry.mark_deleted!
      end
      @cleaned
    end

    def provisioned_identifiers(scenario_id)
      @provisioned[scenario_id]
    end

    def leak_vm(vm_id)
      @leaked << vm_id
    end

    private

    def entries(agent_run)
      ExecutionResourceLedgerEntry.where(agent_run: agent_run, runner_type: "apple_tart")
    end

    def create_records(agent_run:, request_id:, identifier:)
      return if @recorded_identifiers.include?(identifier)

      @recorded_identifiers << identifier
      intent = FactoryBot.create(:provisioning_intent, agent_run: agent_run, runner_type: "apple_tart",
        resource_kind: "apple_vm", request_id: request_id, attempt: (@attempts[agent_run.id] += 1),
        provider_resource_id: identifier, status: "linked")
      FactoryBot.create(:execution_resource_ledger_entry, account: agent_run.project.account,
        project: agent_run.project, agent_run: agent_run, runner_type: "apple_tart", backend: "tart",
        resource_kind: "verification_vm", tags: intent.ownership_tags, provider_resource_id: identifier,
        status: "active")
    end
  end

  class FakeDispatcher
    def initialize
      @failure = nil
    end

    def fail_operation_for(scenario_id, operation_type)
      @failure = [ scenario_id, operation_type ]
    end

    def call(scenario_id:, manifest:, agent_run:)
      manifest.fetch("operations").map do |operation|
        status = "succeeded"
        if @failure == [ scenario_id, operation.fetch("type") ]
          status = "failed"
          @failure = nil
        end
        { "type" => operation.fetch("type"), "status" => status }
      end
    end
  end

  class FakeReconciler
    def call
      ExecutionResourceLedgerEntry.where(runner_type: "apple_tart").where.not(status: "deleted").find_each do |entry|
        next if AgentRun.capacity_inflight.exists?(entry.agent_run_id)

        entry.request_cleanup! unless entry.cleanup_pending?
        entry.mark_deleted!
      end
      { enqueued: 0, cleaned: 0, failed: 0 }
    end
  end

  class FakeDiagnostics
    def initialize(results)
      @results = results
    end

    def call(probe_id:)
      @results.fetch(probe_id, { "status" => "unavailable" })
    end
  end

  class FakeCapacitySampler
    def initialize(samples)
      @samples = samples.dup
      @last = nil
    end

    def call
      @last = @samples.shift unless @samples.empty?
      @last
    end
  end
end
