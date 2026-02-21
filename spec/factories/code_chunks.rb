# frozen_string_literal: true

FactoryBot.define do
  factory :code_chunk do
    project

    sequence(:file_path) { |n| "app/models/model_#{n}.rb" }
    chunk_type { "function" }
    sequence(:identifier) { |n| "method_#{n}" }
    content { "def hello\n  puts 'hello'\nend" }
    language { "ruby" }
    start_line { 1 }
    end_line { 3 }

    trait :class_chunk do
      chunk_type { "class" }
      sequence(:identifier) { |n| "MyClass#{n}" }
      content { "class MyClass\n  def initialize\n  end\nend" }
      end_line { 4 }
    end

    trait :module_chunk do
      chunk_type { "module" }
      sequence(:identifier) { |n| "MyModule#{n}" }
      content { "module MyModule\nend" }
      end_line { 2 }
    end

    trait :file_chunk do
      chunk_type { "file" }
      sequence(:identifier) { |n| "model_#{n}.rb" }
      content { "# frozen_string_literal: true\n\nclass Model\nend" }
      end_line { 4 }
    end

    trait :with_embedding do
      embedding { Array.new(1536) { rand(-1.0..1.0) } }
    end

    trait :python do
      language { "python" }
      sequence(:file_path) { |n| "src/module_#{n}.py" }
      content { "def hello():\n    print('hello')" }
    end

    trait :javascript do
      language { "javascript" }
      sequence(:file_path) { |n| "src/module_#{n}.js" }
      content { "function hello() {\n  console.log('hello');\n}" }
    end
  end
end
