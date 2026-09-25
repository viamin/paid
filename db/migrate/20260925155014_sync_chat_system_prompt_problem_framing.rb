# frozen_string_literal: true

# @spec FEATURE-CREATION-005
class SyncChatSystemPromptProblemFraming < ActiveRecord::Migration[8.1]
  CHANGE_NOTES = "Preserve problem framing in chat-created feature briefs"
  PROMPT_SLUG = ChatSessions::BuildSystemPrompt::CHAT_SYSTEM_PROMPT_SLUG

  def up
    TenantContext.with_system_access do
      prompt = Prompt.global.find_by(slug: PROMPT_SLUG)
      next unless prompt
      next if synced?(prompt.current_version)

      prompt.create_version!(
        template: ChatSessions::BuildSystemPrompt::BASE_IDENTITY_TEMPLATE,
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

    version.template.to_s.strip == ChatSessions::BuildSystemPrompt::BASE_IDENTITY_TEMPLATE &&
      version.variables == []
  end
end
