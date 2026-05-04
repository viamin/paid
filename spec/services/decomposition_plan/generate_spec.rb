# frozen_string_literal: true

require "rails_helper"

RSpec.describe DecompositionPlan::Generate, :no_db do
  describe ".call" do
    subject(:result) do
      described_class.call(
        title: title,
        description: description,
        sub_components: sub_components
      )
    end

    context "with a multi-layer feature" do
      let(:title) { "User notification system" }
      let(:description) { "Build a full notification system with database, services, API, and UI." }
      let(:sub_components) do
        [ "database", "models", "service layer", "background jobs", "api endpoints", "web controllers", "views", "ui" ]
      end

      it "generates a valid plan" do
        expect(result.valid?).to be true
      end

      it "produces multiple tasks" do
        expect(result.task_count).to be > 1
      end

      it "assigns scope labels to each task" do
        scopes = result.tasks.map { |t| t[:scope] }
        expect(scopes).to all(be_a(String))
      end

      it "follows layer ordering: model before service" do
        model_task = result.tasks.find { |t| t[:scope] == "model" }
        service_task = result.tasks.find { |t| t[:scope] == "service" }
        expect(model_task).not_to be_nil, "expected a model-scoped task"
        expect(service_task).not_to be_nil, "expected a service-scoped task"

        expect(model_task[:index]).to be < service_task[:index]
      end

      it "follows layer ordering: service before controller" do
        service_task = result.tasks.find { |t| t[:scope] == "service" }
        controller_task = result.tasks.find { |t| t[:scope] == "controller" }
        expect(service_task).not_to be_nil, "expected a service-scoped task"
        expect(controller_task).not_to be_nil, "expected a controller-scoped task"

        expect(service_task[:index]).to be < controller_task[:index]
      end

      it "follows layer ordering: controller before view" do
        controller_task = result.tasks.find { |t| t[:scope] == "controller" }
        view_task = result.tasks.find { |t| t[:scope] == "view" }
        expect(controller_task).not_to be_nil, "expected a controller-scoped task"
        expect(view_task).not_to be_nil, "expected a view-scoped task"

        expect(controller_task[:index]).to be < view_task[:index]
      end

      it "has model tasks with no dependencies" do
        model_tasks = result.tasks.select { |t| t[:scope] == "model" }
        expect(model_tasks).not_to be_empty, "expected at least one model-scoped task"
        model_tasks.each do |task|
          expect(task[:deps]).to be_empty
        end
      end

      it "has later-layer tasks depending on earlier layers" do
        service_task = result.tasks.find { |t| t[:scope] == "service" }
        model_task = result.tasks.find { |t| t[:scope] == "model" }
        expect(service_task).not_to be_nil, "expected a service-scoped task"
        expect(model_task).not_to be_nil, "expected a model-scoped task"

        expect(service_task[:deps]).to include(model_task[:index])
      end

      it "produces a valid DAG" do
        validation = DecompositionPlan::ValidateDag.call(tasks: result.tasks)
        expect(validation.valid?).to be true
      end
    end

    context "with only model-layer components" do
      let(:title) { "Add user preferences table" }
      let(:description) { "Create migration and model for user preferences." }
      let(:sub_components) { [ "database", "migrations", "models" ] }

      it "generates a valid plan" do
        expect(result.valid?).to be true
      end

      it "scopes tasks as model" do
        expect(result.tasks.first[:scope]).to eq("model")
      end
    end

    context "with only service-layer components" do
      let(:title) { "Background job for emails" }
      let(:description) { "Add async email delivery." }
      let(:sub_components) { [ "background jobs", "email", "notifications" ] }

      it "generates a valid plan" do
        expect(result.valid?).to be true
      end

      it "scopes all tasks as service" do
        scopes = result.tasks.map { |t| t[:scope] }
        expect(scopes).to all(eq("service"))
      end
    end

    context "with empty sub_components" do
      let(:title) { "Simple bug fix" }
      let(:description) { "Fix the login button." }
      let(:sub_components) { [] }

      it "generates a single task" do
        expect(result.task_count).to eq(1)
      end

      it "is valid" do
        expect(result.valid?).to be true
      end

      it "uses the original title" do
        expect(result.tasks.first[:title]).to eq(title)
      end
    end

    context "with nil inputs" do
      let(:title) { nil }
      let(:description) { nil }
      let(:sub_components) { nil }

      it "does not raise" do
        expect { result }.not_to raise_error
      end

      it "generates at least one task" do
        expect(result.task_count).to be >= 1
      end

      it "is valid" do
        expect(result.valid?).to be true
      end
    end

    context "with unknown components" do
      let(:title) { "Custom feature" }
      let(:description) { "Implement custom logic." }
      let(:sub_components) { [ "custom_thing", "unknown_widget" ] }

      it "classifies unknown components as service layer" do
        scopes = result.tasks.map { |t| t[:scope] }
        expect(scopes).to include("service")
      end

      it "is valid" do
        expect(result.valid?).to be true
      end
    end

    context "with a very long title" do
      let(:title) { "A" * 500 }
      let(:description) { "Description" }
      let(:sub_components) { [ "database" ] }

      it "truncates titles to MAX_TITLE_LENGTH" do
        result.tasks.each do |task|
          expect(task[:title].length).to be <= DecompositionPlan::Generate::MAX_TITLE_LENGTH
        end
      end
    end

    context "with cross-cutting concerns spanning all layers" do
      let(:title) { "Role-based access control" }
      let(:description) { "Add RBAC across the application." }
      let(:sub_components) do
        [ "database", "authentication", "authorization", "api endpoints", "ui", "caching" ]
      end

      it "produces tasks across multiple layers" do
        scopes = result.tasks.map { |t| t[:scope] }.uniq
        expect(scopes.size).to be > 1
      end

      it "provides topological ordering" do
        expect(result.sorted_indices).not_to be_empty
      end

      it "sorted indices cover all tasks" do
        expect(result.sorted_indices.sort).to eq((0...result.task_count).to_a)
      end
    end
  end

  describe DecompositionPlan::Generate::Result do
    it "exposes task_count" do
      result = described_class.new(
        tasks: [ { title: "t1" }, { title: "t2" } ],
        valid: true,
        sorted_indices: [ 0, 1 ],
        errors: []
      )
      expect(result.task_count).to eq(2)
    end

    it "exposes valid?" do
      result = described_class.new(tasks: [], valid: false, sorted_indices: [], errors: [ "err" ])
      expect(result.valid?).to be false
      expect(result.errors).to eq([ "err" ])
    end
  end
end
