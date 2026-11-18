# frozen_string_literal: true

module LayeredVerification
  module ReviewPackages
    # Shared, bounded representation for the web JSON, bearer API, and MCP
    # review-package inspection surfaces.
    # @spec LAYERED-VERIFY-023
    module Representation
      module_function

      def package(package)
        {
          id: package.id,
          project_id: package.project_id,
          agent_run_id: package.agent_run_id,
          revision_number: package.revision_number,
          package_digest: package.package_digest,
          bound_inputs: package.bound_inputs,
          approvals: package.approvals.map { |approval| self.approval(approval) }
        }
      end

      def approval(approval)
        {
          id: approval.id,
          approved_by_id: approval.approved_by_id,
          approved_at: approval.approved_at.iso8601,
          provenance: approval.provenance
        }
      end
    end
  end
end
