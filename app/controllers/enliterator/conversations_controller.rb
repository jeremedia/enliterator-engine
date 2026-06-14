# frozen_string_literal: true

module Enliterator
  # v0.39: browse and label retained conversations.
  # Gated on config.chat_retention — 404 when off (always-draw + controller-gate
  # convention, mirroring DesksController / chat_persona_editing).
  class ConversationsController < ApplicationController
    before_action :require_retention!

    def index
      @conversations = Enliterator::Chat::Conversation
                         .order(updated_at: :desc)
                         .includes(:turns)
    end

    def label
      conv = Enliterator::Chat::Conversation.find(params[:id])
      conv.update!(label: params[:label].to_s.strip.presence)
      redirect_to conversations_path, notice: "Label saved."
    rescue ActiveRecord::RecordNotFound
      redirect_to conversations_path, alert: "Conversation not found."
    end

    def destroy
      conv = Enliterator::Chat::Conversation.find(params[:id])
      conv.destroy!
      redirect_to conversations_path, notice: "Conversation deleted."
    rescue ActiveRecord::RecordNotFound
      redirect_to conversations_path, alert: "Conversation not found."
    end

    private

    def require_retention!
      head :not_found unless Enliterator.configuration.chat_retention
    end
  end
end
