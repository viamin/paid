# frozen_string_literal: true

FactoryBot.define do
  factory :chat_investigation do
    association :account
    project { association(:project, account:) }
    created_by { association(:user, account:) }
    transient do
      issue { association(:issue, project:) }
    end
    chat_session { association(:chat_session, account:, project:, created_by:, clarifying_question_issue: issue) }
    clarifying_question_progress { association(:clarifying_question_progress, account:, project:, issue:, chat_session:) }
    kind { "research" }
    status { "queued" }
    prompt { "Compare the options" }
  end
end
