# frozen_string_literal: true

module Configuration
  module Profiles
    class Context < Data.define(:project, :user_setting, :tenant_setting)
      def self.build(project:, actor:)
        new(
          project: project,
          user_setting: actor&.settings,
          tenant_setting: project.account.tenant_setting!
        )
      end
    end
  end
end
