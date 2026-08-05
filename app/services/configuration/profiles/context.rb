# frozen_string_literal: true

module Configuration
  module Profiles
    class Context < Data.define(:project, :user_setting, :tenant_setting)
      def self.build(project:, actor:)
        new(
          project: project,
          user_setting: resolve_user_setting(actor),
          tenant_setting: resolve_tenant_setting(project.account)
        )
      end

      def self.resolve_user_setting(actor)
        return if actor.blank?

        actor.user_setting || actor.build_user_setting
      end

      def self.resolve_tenant_setting(account)
        account.tenant_setting || account.build_tenant_setting
      end
    end
  end
end
