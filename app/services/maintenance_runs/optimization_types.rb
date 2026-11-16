# frozen_string_literal: true

module MaintenanceRuns
  # Curated, code-defined presentation catalog for RDR-075 optimization
  # investigations. The raw selected key remains a run snapshot, so callers
  # can retain values introduced by a newer catalog without a contract change.
  # @spec MAINT-OPT-001 MAINT-OPT-002 MAINT-OPT-003
  module OptimizationTypes
    Type = Data.define(
      :key,
      :name,
      :investigation_description,
      :metric_hints,
      :recipe_key,
      :repair_standing
    ) do
      def to_menu
        {
          key:,
          name:,
          description: investigation_description,
          metric_hints:,
          recipe_key:,
          repair_standing:
        }
      end
    end

    ALL = [
      Type.new("performance", "Performance", "Find latency, throughput, and responsiveness opportunities.", [ "latency reduction", "throughput increase" ], nil, "default_deny"),
      Type.new("design_architecture", "Design / Architecture", "Find structural simplifications and architectural boundary improvements.", [ "complexity decrease", "dependency reduction" ], nil, "default_deny"),
      Type.new("code_duplication", "Code Duplication", "Find duplicated behavior while preserving intentional independence.", [ "duplicated lines removed", "shared behavior candidates" ], nil, "default_deny"),
      Type.new("security_hardening", "Security Hardening", "Find hardening opportunities and security weaknesses for review.", [ "attack surface reduction", "vulnerabilities addressed" ], nil, "manual_only"),
      Type.new("cost_resource_efficiency", "Cost / Resource Efficiency", "Find avoidable compute, memory, storage, and external-service cost.", [ "resource reduction", "cost reduction" ], nil, "default_deny"),
      Type.new("maintainability_readability", "Maintainability / Readability", "Find opportunities to improve clarity, complexity, and maintainability.", [ "complexity decrease", "readability improvements" ], nil, "default_deny"),
      Type.new("test_coverage_quality", "Test Coverage & Quality", "Find missing, weak, or misleading test coverage and quality gaps.", [ "coverage improvement", "test quality improvement" ], nil, "default_deny")
    ].freeze

    BY_KEY = ALL.index_by(&:key).freeze

    class << self
      def entries = ALL
      def keys = BY_KEY.keys
      def fetch(key) = BY_KEY[key.to_s]
      def menu = ALL.map(&:to_menu)
    end
  end
end
