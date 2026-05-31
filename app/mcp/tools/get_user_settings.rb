# frozen_string_literal: true

module Tools
  class GetUserSettings < BaseTool
    authorize :edit?, ->(_args) { current_user.settings }

    def self.tool_name = "get_user_settings"

    def self.description
      "Read the current user's settings."
    end

    def perform
      current_user.settings.attributes.except("id", "user_id", "created_at", "updated_at", "log_data")
    end
  end
end
