# frozen_string_literal: true

Rails.application.routes.draw do
  mount SolidObjects::Engine => "/solid_objects"
end
