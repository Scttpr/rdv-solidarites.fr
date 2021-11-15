# frozen_string_literal: true

describe NextAvailabilityService, type: :service do
  let(:today) { Date.new(2021, 3, 18) }
  let(:now) { Time.zone.parse("20210318 8:23") }

  before { travel_to(now) }

  describe "#perform" do
    subject { described_class.find(motif, lieu, today, agent_ids: wanted_agents) }

    let(:organisation) { create(:organisation) }
    let(:lieu) { create(:lieu, organisation: organisation) }
    let(:agent) { create(:agent, basic_role_in_organisations: [organisation]) }
    let(:motif) { create(:motif, name: "Vaccination", default_duration_in_min: 30, reservable_online: reservable_online, organisation: organisation) }

    let(:reservable_online) { true }
    let(:recurrence) { nil }
    let(:wanted_agents) { nil }

    before do
      create(:plage_ouverture,
             motifs: [motif], lieu: lieu, agent: agent, organisation: organisation,
             first_day: today + 1.day, start_time: Tod::TimeOfDay.new(9), end_time: Tod::TimeOfDay.new(11),
             recurrence: recurrence)
    end

    describe "regular case" do
      it { expect(subject.starts_at).to eq((today + 1.day).in_time_zone + 9.hours) }
    end

    describe "with not reservable_online motif" do
      let(:reservable_online) { false }

      it { is_expected.to eq(nil) }
    end

    describe "with an overlapping absence" do
      before do
        create(:absence,
               agent: agent, organisation: organisation,
               first_day: today + 1.day, start_time: Tod::TimeOfDay.new(9, 0), end_day: today + 1.day, end_time: Tod::TimeOfDay.new(12, 0))
      end

      context "planned" do
        it { is_expected.to eq(nil) }
      end

      context "when plage_ouverture is recurrence" do
        let(:recurrence) { Montrose.every(:month, starts: (today + 1.day)) }

        it { expect(subject.starts_at).to eq(today.in_time_zone + 1.month + 1.day + 9.hours) }
      end
    end

    describe "with an overlapping rdv" do
      let(:status) { "unknown" }

      before do
        create(:rdv,
               agents: [agent], organisation: organisation, lieu: lieu,
               starts_at: today.in_time_zone + 1.day + 9.hours, duration_in_min: 120,
               status: status)
      end

      context "planned" do
        it { is_expected.to be_nil }
      end

      context "cancelled" do
        let(:status) { "revoked" }

        it { expect(subject.starts_at).to eq(today.in_time_zone + 1.day + 9.hours) }
      end

      context "when plage_ouverture is recurrence" do
        let(:recurrence) { Montrose.every(:month, starts: today + 1.day) }

        it { expect(subject.starts_at).to eq(today.in_time_zone + 1.month + 1.day + 9.hours) }
      end
    end

    describe "with several agents" do
      let(:other_agent) { create(:agent, basic_role_in_organisations: [organisation]) }
      let(:other_agent_start_day) { today + 7.days }

      before do
        create(:plage_ouverture,
               motifs: [motif], lieu: lieu,
               first_day: other_agent_start_day, start_time: Tod::TimeOfDay.new(9), end_time: Tod::TimeOfDay.new(11),
               agent: other_agent, organisation: organisation)
      end

      context "for any agent" do
        let(:wanted_agents) { [agent.id, other_agent.id] }

        it "returns the first availability" do
          expect(subject.starts_at).to eq(today + 1.day + 9.hours)
        end
      end

      context "for a specific agent among two" do
        let(:wanted_agents) { [other_agent.id] }

        it "returns the availability of that agent only" do
          expect(subject.starts_at).to eq(other_agent_start_day + 9.hours)
        end
      end
    end
  end
end
