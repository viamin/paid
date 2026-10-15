# @spec CHAT-API-025
class SyncChatSystemPromptNavigationGuidance < ActiveRecord::Migration[8.1]
  CHANGE_NOTES = "Add in-chat navigation guidance for Paid pages"
  PROMPT_SLUG = ChatSessions::BuildSystemPrompt::CHAT_SYSTEM_PROMPT_SLUG

  def up
    TenantContext.with_system_access do
      prompt = Prompt.global.find_by(slug: PROMPT_SLUG)
      next unless prompt
      next if synced?(prompt.current_version)

      prompt.create_version!(
        template: ChatSessions::BuildSystemPrompt::DEFAULT_BASE_IDENTITY,
        variables: [],
        created_by: "migration",
        change_notes: CHANGE_NOTES
      )
    end
  end

  def down
  end

  private

  def synced?(version)
    return false unless version

    version.template.to_s.strip == ChatSessions::BuildSystemPrompt::DEFAULT_BASE_IDENTITY &&
      version.variables == []
  end
end
