# frozen_string_literal: true

module WorkItems
  module Trust
    # Whether a provider team/user identity is trusted for a project. This is
    # an additional admission path for non-GitHub providers; it never widens
    # or replaces the existing GitHub allowlist/`issue.trusted?` gate.
    #
    # @spec UNIFIED-WORK-ITEMS-005 UNIFIED-WORK-ITEMS-009
    module Admit
      module_function

      def trusted?(project:, provider:, identity_type:, external_id:)
        return false unless Automation::Providers::UnifiedWorkItemsRolloutGuard.enabled?(project)

        trusted_identity?(project:, provider:, identity_type:, external_id:) || mapped_user?(project:, provider:,
          identity_type:, external_id:)
      end

      def trusted_identity?(project:, provider:, identity_type:, external_id:)
        TrustedProviderIdentity.for_project(project)
          .exists?(account_id: project.account_id, provider:, identity_type:, external_id:)
      end

      def mapped_user?(project:, provider:, identity_type:, external_id:)
        identity_type == "user" && ProviderIdentityMapping.user_for(account: project.account, provider:, external_id:).present?
      end
    end
  end
end
