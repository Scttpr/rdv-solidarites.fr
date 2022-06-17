# frozen_string_literal: true

class StatsController < ApplicationController
  before_action :scope_rdv_to_departement

  def index
    @stats = Stat.new(agents: @agents, organisations: @organisations, rdvs: @rdvs, users: @users, receipts: @receipts)
  end

  def rdvs
    stats = Stat.new(rdvs: @rdvs)
    stats = if params[:by_departement].present?
              stats.rdvs_group_by_departement
            elsif params[:by_service].present?
              stats.rdvs_group_by_service
            elsif params[:by_location_type].present?
              stats.rdvs_group_by_type
            elsif params[:by_status].present?
              stats.rdvs_group_by_status
            else
              stats.rdvs_group_by_week_fr
            end
    render json: stats.chart_json
  end

  def receipts
    attribute = params[:group_by]&.to_sym
    attribute = :channel unless attribute.in?(%i[event channel result])
    render json: Stat.new(receipts: @receipts).receipts_group_by(attribute).chart_json
  end

  def scope_rdv_to_departement
    @departement = params[:departement]
    if @departement.present?
      @rdvs = Rdv.joins(organisation: :territory)
        .where(organisations: { territories: { departement_number: @departement } })
      @users = User.joins(organisations: :territory)
        .where(organisations: { territories: { departement_number: @departement } })
      @agents = Agent.joins(organisations: :territory)
        .where(organisations: { territories: { departement_number: @departement } })
      @organisations = Organisation.joins(:territory)
        .where(territories: { departement_number: @departement })
      @receipts = Territory.find_by(departement_number: @departement).receipts
    else
      @rdvs = Rdv.all
      @users = User.all
      @agents = Agent.all
      @organisations = Organisation.all
      @receipts = Receipt.all
    end

    @departements = Territory
      .order(:departement_number)
      .distinct(:departement_number)
      .pluck(:departement_number)
  end
end
