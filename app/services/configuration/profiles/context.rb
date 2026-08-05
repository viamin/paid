# frozen_string_literal: true

module Configuration
  module Profiles
    class Context < Data.define(:project, :user_setting, :tenant_setting)
      def self.build(project:, actor:, materialize_missing: false)
        new(
          project: project,
          user_setting: resolve_user_setting(actor, materialize_missing:),
          tenant_setting: resolve_tenant_setting(project.account, materialize_missing:)
        )
      end

      def self.resolve_user_setting(actor, materialize_missing:)
        return if actor.blank?

        materialize_missing ? actor.settings : (actor.user_setting || actor.build_user_setting)
      end

      def self.resolve_tenant_setting(account, materialize_missing:)
        materialize_missing ? account.tenant_setting! : (account.tenant_setting || account.build_tenant_setting)
      end
    end
  end
end
