# frozen_string_literal: true

require "open3"
require "rails_helper"

class RepositorySelectorControllerNodeHarness
  SCRIPT = <<~JAVASCRIPT
    const fs = require("node:fs");

    const source = fs.readFileSync("app/javascript/controllers/repository_selector_controller.js", "utf8");
    const form = fs.readFileSync("app/views/projects/new.html.erb", "utf8");
    const transformed = source
      .replace('import { Controller } from "@hotwired/stimulus"', "class Controller {}")
      .replace("export default class extends Controller {", "return class RepositorySelectorController extends Controller {");
    const RepositorySelectorController = new Function(transformed)();

    function target(value = "") {
      return {
        value,
        disabled: false,
        classList: { add() {}, remove() {}, toggle() {} },
        setAttribute() {},
        focus() {},
        dispatchEvent() {}
      };
    }

    function controllerWith(repositories) {
      const controller = Object.create(RepositorySelectorController.prototype);
      controller.repositories = repositories;
      controller.filteredRepositories = repositories;
      controller.activeIndex = -1;
      controller.repoSelectTarget = target();
      controller.repoListTarget = target();
      controller.repoClearTarget = target();
      controller.ownerTarget = target();
      controller.repoTarget = target();
      controller.githubIdTarget = target();
      controller.defaultBranchTarget = target();
      controller.hasLoadingTarget = false;
      controller.hasRepoStatusTarget = true;
      controller.repoStatusTarget = target();
      controller.hasSortSelectTarget = true;
      controller.sortSelectTarget = target("name");
      controller.hasTokenSelectTarget = true;
      controller.tokenSelectTarget = { value: "1" };
      controller.hasInstallationSelectTarget = false;
      controller.renderRepoList = () => {};
      controller.updateRepoClearState = () => {};
      controller.openRepoList = () => {};
      controller.closeRepoList = () => {};
      return controller;
    }

    const repositories = [
      { full_name: "Acme/Api-Server", owner: "Acme", name: "Api-Server", id: 1, default_branch: "main", created_at: "2026-09-01T12:00:00Z" },
      { full_name: "octo/website", owner: "octo", name: "website", id: 2, default_branch: "trunk", created_at: "2026-09-02T12:00:00Z" },
      { full_name: "beta/numeric-cache", owner: "beta", name: "numeric-cache", id: 3, default_branch: "main", created_at: 0 },
      { full_name: "zeta/legacy", owner: "zeta", name: "legacy", id: 4, default_branch: "main" },
      { full_name: "gamma/invalid-date", owner: "gamma", name: "invalid-date", id: 5, default_branch: "main", created_at: "2026-02-31T12:00:00Z" }
    ];

    function run() {
      const controller = controllerWith(repositories);

      if (!form.includes("blur->repository-selector#closeRepoList")) {
        throw new Error("Expected the repository combobox to close its list on blur");
      }

      if (!source.includes('option.dataset.action = "mousedown->repository-selector#repoOptionSelected"')) {
        throw new Error("Expected pointer selection to occur before input blur closes the list");
      }

      controller.repoSelectTarget.value = "SERVER";
      controller.inputChanged();
      if (controller.filteredRepositories.length !== 1 || controller.filteredRepositories[0].full_name !== "Acme/Api-Server") {
        throw new Error("Expected case-insensitive substring filtering by full name");
      }

      controller.repoSelectTarget.value = "octo";
      controller.inputChanged();
      if (controller.filteredRepositories.length !== 1 || controller.filteredRepositories[0].name !== "website") {
        throw new Error("Expected filtering by owner");
      }

      controller.repoSelectTarget.value = "api";
      controller.inputChanged();
      controller.repoKeydown({ key: "ArrowDown", preventDefault() {} });
      controller.repoKeydown({ key: "Enter", preventDefault() {} });
      if (controller.ownerTarget.value !== "Acme" || controller.repoTarget.value !== "Api-Server" || controller.githubIdTarget.value !== 1 || controller.defaultBranchTarget.value !== "main") {
        throw new Error("Expected keyboard selection to synchronize hidden fields");
      }

      controller.clearRepository();
      if (controller.repoSelectTarget.value || controller.ownerTarget.value || controller.repoTarget.value || controller.githubIdTarget.value || controller.defaultBranchTarget.value) {
        throw new Error("Expected clearing the picker to clear selection metadata");
      }

      controller.filteredRepositories = [repositories[1]];
      controller.repoOptionSelected({ currentTarget: { dataset: { repositoryIndex: 0 } } });
      if (controller.ownerTarget.value !== "octo" || controller.repoTarget.value !== "website") {
        throw new Error("Expected pointer selection to synchronize hidden fields");
      }
      controller.repoKeydown({ key: "Escape", preventDefault() {} });
      if (controller.repoSelectTarget.value || controller.ownerTarget.value || controller.repoTarget.value || controller.githubIdTarget.value || controller.defaultBranchTarget.value) {
        throw new Error("Expected Escape to clear selection metadata");
      }

      controller.loading = true;
      controller.updateRepoDisabledState();
      if (!controller.repoSelectTarget.disabled) throw new Error("Expected picker to disable while loading");
      controller.loading = false;
      controller.updateRepoDisabledState();
      if (controller.repoSelectTarget.disabled) throw new Error("Expected picker to enable after loading for a selected credential");

      const restored = controllerWith(repositories);
      restored.hasSelectedRepositoryValue = true;
      restored.selectedRepositoryValue = "octo/website";
      restored.sortSelectTarget.disabled = true;
      restored.populateRepoSelect(repositories);
      if (restored.sortSelectTarget.disabled) {
        throw new Error("Expected sort control to enable when repositories finish loading");
      }
      if (restored.repoSelectTarget.value !== "octo/website" || restored.ownerTarget.value !== "octo" || restored.defaultBranchTarget.value !== "trunk") {
        throw new Error("Expected a re-rendered form to restore its repository selection");
      }

      restored.showError("Failed to load repositories.");
      if (restored.repoStatusTarget.textContent !== "Failed to load repositories.") {
        throw new Error("Expected repository load failures to remain visible to the user");
      }

      controller.sortSelectTarget.value = "recent";
      controller.sortChanged();
      if (controller.filteredRepositories.map((repo) => repo.full_name).join(",") !== "octo/website,Acme/Api-Server,beta/numeric-cache,gamma/invalid-date,zeta/legacy") {
        throw new Error("Expected recent sorting to place repositories with unusable timestamps after dated repositories, including invalid calendar dates");
      }
    }

    try {
      run();
    } catch (error) {
      console.error(error);
      process.exit(1);
    }
  JAVASCRIPT

  def self.run
    Open3.capture3("node", "-e", SCRIPT, chdir: Rails.root.to_s)
  end
end

RSpec.describe RepositorySelectorControllerNodeHarness, :no_db do
  # @spec PROJECT-CREATION-013 PROJECT-CREATION-014
  it "filters, selects, clears, and disables the existing-repository combobox" do
    stdout, stderr, status = described_class.run

    expect(status.success?).to be(true), <<~MESSAGE
      Node regression harness failed.
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MESSAGE
  end
end
