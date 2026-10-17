# frozen_string_literal: true

FactoryBot.define do
  factory :chat_diagram do
    chat_session
    question_key { "authentication-flow" }
    question_title { "How should authentication work?" }
    summary { "A browser exchanges credentials for a session." }
    text_equivalent { "Client sends credentials to the application, which creates a session." }
    description do
      {
        "elements" => [
          { "id" => "client", "label" => "Client", "description" => "The person using the application." },
          { "id" => "app", "label" => "Application", "description" => "The Paid application." }
        ],
        "relationships" => [ { "from" => "client", "to" => "app", "label" => "sends credentials" } ]
      }
    end
  end

  factory :chat_diagram_comment do
    chat_diagram
    actor { chat_diagram.chat_session.created_by }
    question_key { chat_diagram.question_key }
    body { "Please explain this part." }
  end
end
