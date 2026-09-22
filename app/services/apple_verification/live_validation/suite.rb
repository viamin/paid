# frozen_string_literal: true

module AppleVerification
  module LiveValidation
    # Frozen acceptance-scenario matrix for issue #3978. The suite is data:
    # the runner, probes, and report key off these ids, so a scenario can be
    # added or renamed only here.
    # @spec APPLE-LIVE-001
    module Suite
      CRITERIA = {
        "AC1" => "Clean VM clones repeatedly build, test, launch, and capture the smoke iOS app through the shipped control plane.",
        "AC2" => "Clean VM clones repeatedly build, test, launch, and capture viamin/ColorMatching-iOS through the shipped control plane.",
        "AC3" => "A representative native macOS GUI application builds, tests, launches, and produces an app-window screenshot.",
        "AC4" => "Cancellation, timeout, control-plane restart, host restart, partial provisioning, and orphan-discovery scenarios converge to audited ledger states during the live runs.",
        "AC5" => "Adversarial isolation evidence collected on the live host: guest cannot reach host SSH, host filesystem, personal data, keychain, devices, or container runtime.",
        "AC6" => "Adversarial network-policy evidence collected on the live guest: direct IP, alternate DNS, project-supplied proxy override, and unsupported protocol attempts are denied and audited.",
        "AC7" => "One Apple worker operates alongside three active paid-agent containers within the accepted host capacity thresholds; the figure is recorded.",
        "AC8" => "The live-validation report is archived under docs/rdrs/ and cross-referenced from the next RDR-068 closeout."
      }.freeze

      SCENARIOS = [
        Scenario.new(id: "functional-smoke-ios-app", criterion: "AC1", group: :functional,
          description: "Smoke iOS app: repeated clean-clone build, test, launch, and Simulator capture.",
          expectation: :build_test_launch_capture),
        Scenario.new(id: "functional-colormatching-ios", criterion: "AC2", group: :functional,
          description: "viamin/ColorMatching-iOS: repeated clean-clone build, test, launch, and Simulator capture.",
          expectation: :build_test_launch_capture),
        Scenario.new(id: "functional-macos-gui-app", criterion: "AC3", group: :functional,
          description: "Native macOS GUI app: build, test, launch, and app-window capture.",
          expectation: :build_test_launch_capture),

        Scenario.new(id: "recovery-cancellation", criterion: "AC4", group: :recovery,
          description: "Cancelling a provisioned VM converges the ledger to deleted with an empty inventory.",
          expectation: :ledger_converged),
        Scenario.new(id: "recovery-timeout", criterion: "AC4", group: :recovery,
          description: "An attempt exceeding the timeout deadline converges to a terminal ledger state.",
          expectation: :ledger_converged),
        Scenario.new(id: "recovery-control-plane-restart", criterion: "AC4", group: :recovery,
          description: "Re-provisioning after a control-plane restart re-links the same VM idempotently.",
          expectation: :ledger_converged),
        Scenario.new(id: "recovery-host-restart", criterion: "AC4", group: :recovery,
          description: "A VM stopped by a host restart is cleaned through reconciliation with ledger convergence.",
          expectation: :ledger_converged),
        Scenario.new(id: "recovery-partial-provisioning", criterion: "AC4", group: :recovery,
          description: "A provisioning failure before start leaves no VM, no active ledger entry, and a terminal intent.",
          expectation: :ledger_converged),
        Scenario.new(id: "recovery-orphan-discovery", criterion: "AC4", group: :recovery,
          description: "A VM orphaned after its run stops being in flight is discovered and reconciled to deletion.",
          expectation: :ledger_converged),

        Scenario.new(id: "isolation-host-ssh", criterion: "AC5", group: :isolation,
          description: "Guest cannot reach the host SSH service.", expectation: :denied_on_live_host),
        Scenario.new(id: "isolation-host-filesystem", criterion: "AC5", group: :isolation,
          description: "Guest cannot reach the host filesystem.", expectation: :denied_on_live_host),
        Scenario.new(id: "isolation-personal-data", criterion: "AC5", group: :isolation,
          description: "Guest cannot reach host personal data directories.", expectation: :denied_on_live_host),
        Scenario.new(id: "isolation-keychain", criterion: "AC5", group: :isolation,
          description: "Guest cannot reach the host keychain.", expectation: :denied_on_live_host),
        Scenario.new(id: "isolation-devices", criterion: "AC5", group: :isolation,
          description: "Guest cannot reach host devices.", expectation: :denied_on_live_host),
        Scenario.new(id: "isolation-container-runtime", criterion: "AC5", group: :isolation,
          description: "Guest cannot reach the host container runtime socket.", expectation: :denied_on_live_host),

        Scenario.new(id: "network-direct-ip", criterion: "AC6", group: :network_policy,
          description: "Direct IP connection attempt is denied and audited.", expectation: :denied_and_audited),
        Scenario.new(id: "network-alternate-dns", criterion: "AC6", group: :network_policy,
          description: "Alternate DNS server attempt is denied and audited.", expectation: :denied_and_audited),
        Scenario.new(id: "network-proxy-override", criterion: "AC6", group: :network_policy,
          description: "Project-supplied proxy override attempt is denied and audited.", expectation: :denied_and_audited),
        Scenario.new(id: "network-unsupported-protocol", criterion: "AC6", group: :network_policy,
          description: "Unsupported protocol attempt is denied and audited.", expectation: :denied_and_audited),
        Scenario.new(id: "network-compliant-request", criterion: "AC6", group: :network_policy,
          description: "A compliant HTTP(S) request to an allowed destination is permitted.", expectation: :permitted),

        Scenario.new(id: "capacity-alongside-three-agent-containers", criterion: "AC7", group: :capacity,
          description: "Host stays within admission thresholds while one Apple VM runs alongside three paid-agent containers.",
          expectation: :within_thresholds),

        Scenario.new(id: "report-archived-under-docs-rdrs", criterion: "AC8", group: :reporting,
          description: "The generated report is archived under docs/rdrs/ for the next RDR-068 closeout.",
          expectation: :report_written)
      ].freeze

      SCENARIOS_BY_ID = SCENARIOS.index_by(&:id).freeze
      GROUPS = SCENARIOS.group_by(&:group).transform_values(&:freeze).freeze

      module_function

      def for_criterion(criterion)
        GROUPS.values.flatten.select { |scenario| scenario.criterion == criterion }
      end

      def group(group)
        GROUPS.fetch(group, []).freeze
      end

      def find(scenario_id)
        SCENARIOS_BY_ID.fetch(scenario_id)
      end
    end
  end
end
