# frozen_string_literal: true

require "digest"

FactoryBot.define do
  factory :clarifying_question_progress do
    account
    project { association :project, account: }
    issue { association :issue, project: }
    chat_session { association :chat_session, account:, project:, clarifying_question_issue: issue }
    question { "What should happen?" }
    question_digest { Digest::SHA256.hexdigest(question) }
    position { 1 }
    answer { "Keep the user on the current page." }
    evidence_context { "The operator confirmed this during exploration." }
    answered_by { association :user, account: }
    answered_at { Time.current }
  end
end
