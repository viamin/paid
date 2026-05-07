# frozen_string_literal: true

Rails.application.routes.draw do
  devise_for :users
  root "home#index"
  get "dashboard", to: "dashboard#show"
  resources :reports, only: [ :index ]
end
