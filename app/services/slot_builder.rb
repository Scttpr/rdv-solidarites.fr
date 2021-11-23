# frozen_string_literal: true

module SlotBuilder
  # À faire avant, au moment de jouer avec le motifs
  # @for_agents ? motifs : motifs.reservable_online
  # Ce filtre est lié à la recherche de plage d'ouverture à partir d'un nom de motif... Est-ce vraiment nécessaire dans notre cas ?
  #
  # @for_agents sert aussi pour « limiter » l'afficahge des créneaux. Je pense que c'est à faire sur la vue.
  # uniq_by = @for_agents ? ->(c) { [c.starts_at, c.agent_id] } : ->(c) { c.starts_at }
  #  creneaux.uniq(&uniq_by).sort_by(&:starts_at)
  #
  # L'option agent_name n'est pas reproduite ici.
  # Cet élément est dépendant de l'affichage, du motif et de l'agent
  # (ces deux dernier sont présent dans l'object Creneau, il est donc facile de faire la demande de nom court plus tard.

  def self.available_slots(motif, lieu, date_range, off_days, options = {})
    # options : { agents: [] }
    plage_ouvertures = plage_ouvertures_for(motif, lieu, date_range, options)
    free_times_po = free_times_from(plage_ouvertures, date_range, off_days) # dépendance sur RDV et Absence
    slots_for(free_times_po, motif)
  end

  def self.plage_ouvertures_for(motif, lieu, date_range, options = {})
    lieu.plage_ouvertures.for_motif_object(motif).not_expired.in_range(date_range)
      .where(({ agent_id: options[:agent_ids] } unless options[:agent_ids].nil?))
  end

  def self.free_times_from(plage_ouvertures, date_range, off_days)
    free_times = {}
    plage_ouvertures.each do |plage_ouverture|
      free_times[plage_ouverture] = calculate_free_times(plage_ouverture, date_range, off_days)
    end
    free_times.select { |_, v| v&.any? }
  end

  def self.calculate_free_times(plage_ouverture, date_range, _off_days)
    ranges = ranges_for(plage_ouverture, date_range)

    return [] if ranges.empty?

    ranges = ranges.map { |range| split_range_recursively(range, BusyTime.busy_times_for(range, plage_ouverture)) }.flatten
    ranges.select { |r| ((r.end.to_i - r.begin.to_i) / 60).positive? } || []
  end

  def self.ranges_for(plage_ouverture, date_range)
    date_range = date_range.begin.beginning_of_day..date_range.end.end_of_day
    date_range = Time.zone.now..date_range.end.end_of_day if date_range.begin < Time.zone.now

    occurrences = plage_ouverture.occurrences_for(date_range)

    occurrences.map do |occurrence|
      next if occurrence.ends_at < Time.zone.now

      (plage_ouverture.start_time.on(occurrence.starts_at)..plage_ouverture.end_time.on(occurrence.ends_at))
    end.compact
  end

  def self.split_range_recursively(range, busy_times)
    return [range] if busy_times.empty?

    busy_time = busy_times.first

    if busy_time_include_in_range?(busy_time, range)
      [range.begin..busy_time.starts_at] + split_range_recursively(busy_time.ends_at..range.end, busy_times - [busy_time])
    elsif rdv_overlap_begin_of_range?(busy_time, range)
      split_range_recursively(busy_time.ends_at..range.end, busy_times - [busy_time])
    elsif rdv_overlap_end_of_range?(busy_time, range)
      split_range_recursively(range.begin..busy_time.starts_at, busy_times - [busy_time])
    else
      [range]
    end
  end

  def self.busy_time_include_in_range?(busy_time, range)
    debut_dedans = range.begin < busy_time.starts_at
    # Les absences n'ont pas forcement de ends_at... ?
    fin_dedans = (busy_time.ends_at && busy_time.ends_at <= range.end)
    debut_dedans && fin_dedans
  end

  def self.rdv_overlap_begin_of_range?(rdv, range)
    rdv.starts_at <= range.begin
  end

  def self.rdv_overlap_end_of_range?(rdv, range)
    range.end <= rdv.ends_at
  end

  def self.slots_for(plage_ouverture_free_times, motif)
    slots = []
    plage_ouverture_free_times.each do |plage_ouverture, free_times|
      free_times.each do |free_time|
        slots += calculate_slots(free_time, motif) do |starts_at|
          Creneau.new(
            starts_at: starts_at,
            motif: motif,
            lieu_id: plage_ouverture.lieu_id,
            agent_id: plage_ouverture.agent_id
          )
        end
      end
    end
    slots
  end

  def self.calculate_slots(free_time, motif, &build_creneau)
    slots = []
    possible_slot_time = free_time.begin..(free_time.begin + motif.default_duration_in_min.minutes)
    while possible_slot_time.end <= free_time.end
      slots << build_creneau.call(possible_slot_time.begin)
      possible_slot_time = possible_slot_time.end..(possible_slot_time.end + motif.default_duration_in_min.minutes)
    end
    slots
  end

  class BusyTime
    attr_reader :starts_at, :ends_at

    def initialize(object)
      case object
      when Rdv || Recurrence::Occurrence
        @starts_at = object.starts_at
        @ends_at = object.ends_at
      when Absence
        @starts_at = object.start_time.on(object.first_day)
        @ends_at = if object.end_day.present?
                     object.end_time.on(object.end_day)
                   else
                     object.end_time.on(object.first_day)
                   end
      else
        raise ArgumentError, "busytime can't be build with a #{object.class}"
      end
    end

    def self.busy_times_for(range, plage_ouverture)
      # c'est là que l'on execute le SQL
      # TODO : Peut-être cacher la récupération de l'ensemble des RDV et absences concernées (pour n'avoir que deux requêtes) puis faire des selections dessus pour le filtre sur le range

      busy_times = busy_times_from_rdvs(range, plage_ouverture)
      busy_times += busy_times_from_absences(range, plage_ouverture)

      # Le tri est nécessaire, surtout pour les surcharges.
      busy_times.sort_by(&:starts_at)
    end

    def self.busy_times_from_rdvs(range, plage_ouverture)
      plage_ouverture.agent.rdvs.not_cancelled.where(starts_at: range).or(plage_ouverture.agent.rdvs.not_cancelled.where(ends_at: range)).map do |rdv|
        BusyTime.new(rdv)
      end
    end

    def self.busy_times_from_absences(range, plage_ouverture)
      absences = plage_ouverture.agent.absences.where(organisation: plage_ouverture.organisation).in_range(range)
      busy_times = []
      absences.each do |absence|
        if absence.recurrence
          absence.occurrences_for(range).each do |absence_occurrence|
            busy_times << BusyTime.new(absence_occurrence)
          end
        else
          busy_times << BusyTime.new(absence)
        end
      end
      busy_times
    end
  end
end
