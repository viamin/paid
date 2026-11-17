# frozen_string_literal: true

module LayeredVerification
  module ReviewPackages
    # Records the authorized business reviewer's decision at the bound
    # revision. Approval never authorizes a repair, a release, or a canonical
    # clarification on its own; those remain separately performed operations.
    # @spec LAYERED-VERIFY-023
    class Approve
      class StalePackageError < StandardError; end

      def self.call(...) = new(...).call

      def initialize(package:, user:, provenance:)
        @package = package
        @user = user
        @provenance = provenance.to_h.deep_stringify_keys
      end

      def call
        AuditAccess.authorize!(user:, project: package.project)

        package.agent_run.with_lock do
          validate_bound_revisions!
          validate_current_revision!
          approval = package.approvals.create!(
            approved_by: user, approved_at: Time.current, provenance: approval_provenance
          )
          Capture.call(agent_run: package.agent_run)
          approval
        end
      end

      private

      attr_reader :package, :provenance, :user

      def validate_current_revision!
        return if package.current_revision.id == package.id

        raise StalePackageError,
              "A newer review package revision exists; refresh and review the updated inputs before approving."
      end

      def validate_bound_revisions!
        bound = bound_revisions_by_id
        live = package.project.layered_verification_obligations.where(id: bound.keys)
          .to_h { |obligation| [ obligation.id, obligation.external_revision.to_s ] }

        bound.each do |obligation_id, revision|
          next if live[obligation_id] == revision

          raise StalePackageError,
                "The obligation source changed since this package was captured; refresh and review the updated inputs."
        end
      end

      def bound_revisions_by_id
        Array(package.bound_inputs["obligations"])
          .to_h { |obligation| [ obligation["id"], obligation["external_revision"].to_s ] }
      end

      def bound_revisions
        Array(package.bound_inputs["obligations"])
          .to_h { |obligation| [ obligation["external_identity"], obligation["external_revision"].to_s ] }
      end

      def approval_provenance
        {
          "surface" => provenance["surface"].presence, "note" => provenance["note"].presence,
          "package_digest" => package.package_digest, "bound_revisions" => bound_revisions
        }.compact
      end
    end
  end
end
