# frozen_string_literal: true

module Users::CreneauxSearchConcern
  extend ActiveSupport::Concern

  def next_availability
    return available_collective_rdvs.first if motif.collectif?

    NextAvailabilityService.find(motif, @lieu, attributed_agents, from: start_booking_delay, to: end_booking_delay)
  end

  def creneaux
    return available_collective_rdvs if motif.collectif?

    reduced_date_range = Lapin::Range.reduce_range_to_delay(motif, date_range) # réduit le range en fonction du délay
    return [] if reduced_date_range.blank?

    SlotBuilder.available_slots(motif, @lieu, reduced_date_range, attributed_agents)
  end

  def available_collective_rdvs
    rdvs = Rdv.collectif.future
      .with_remaining_seats
      .not_revoked
      .where(motif_id: motif.id)
      .where(lieu_id: lieu.id)
      .where(starts_at: start_booking_delay..end_booking_delay)
      .order(:starts_at)

    rdvs = rdvs.where.not(id: user.self_and_relatives.flat_map(&:rdv_ids)) if user
    rdvs = rdvs.joins(:agents).where(agents: attributed_agents) if attributed_agents.any?
    rdvs
  end

  protected

  def attributed_agents
    @attributed_agents ||= retrieve_attributed_agents
  end

  def retrieve_attributed_agents
    return @user.agents if motif.follow_up?
    return geo_attributed_agents if @geo_search.present? && motif.sectorisation_level_agent?

    []
  end

  def geo_attributed_agents
    @geo_search.attributed_agents_by_organisation[@motif.organisation]
  end
end
