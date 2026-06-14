# frozen_string_literal: true

module Enliterator
  # v0.37: the persona-editing surface. Edits each registered desk's persona,
  # stored versioned via Chat::Persona; tier/tools/routes and the register stay
  # code-owned and read-only here. Gated on config.chat_persona_editing (404 off).
  class DesksController < ApplicationController
    before_action :require_editing!

    def index
      @desks = Enliterator::Chat.agents.sort_by(&:name)
    end

    def update
      desk = desk_or_redirect or return
      text = params[:system_prompt].to_s
      if text.strip.empty?
        redirect_to(desks_path, alert: "Persona text can't be blank."); return
      end
      Enliterator::Chat::Persona.record(
        desk_name: desk.name, system_prompt: text,
        editor: resolve_editor, note: params[:note].presence)
      redirect_to desks_path, notice: "Saved a new persona version for #{desk.name}."
    end

    def rollback
      desk = desk_or_redirect or return
      version = Enliterator::Chat::Persona.where(desk_name: desk.name).find_by(id: params[:version_id])
      unless version
        redirect_to(desks_path, alert: "That version no longer exists."); return
      end
      Enliterator::Chat::Persona.record(
        desk_name: desk.name, system_prompt: version.system_prompt,
        editor: resolve_editor, note: "rolled back to the #{version.created_at.to_date} version")
      redirect_to desks_path, notice: "Rolled #{desk.name} back to an earlier version (saved as the latest)."
    end

    private

    def require_editing!
      head :not_found unless Enliterator.configuration.chat_persona_editing
    end

    def desk_or_redirect
      desk = Enliterator::Chat.registry[params[:desk].to_s]
      redirect_to(desks_path, alert: "No such desk: #{params[:desk]}.") unless desk
      desk
    end

    # Auth-agnostic: use the host's editor resolver if configured, else nil.
    def resolve_editor
      r = Enliterator.configuration.chat_editor
      return nil unless r.respond_to?(:call)
      r.call(request).presence
    rescue StandardError => e
      Enliterator.logger&.warn("[enliterator] chat_editor resolver raised: #{e.class}")
      nil
    end
  end
end
