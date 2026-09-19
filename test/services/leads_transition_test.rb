require "test_helper"

class LeadsTransitionTest < ActiveSupport::TestCase
  setup do
    @lead = Lead.create!(name: "Mover", source: "manual", status: "new")
  end

  test "captain moves through lead stages and records an event" do
    result = Leads::Transition.call(@lead, to: "chatting", actor: :captain)
    assert_equal "new", result.from
    assert_equal "chatting", result.to
    assert_equal "chatting", @lead.reload.status
    event = @lead.activity_events.find_by(kind: "stage_change")
    assert event.present?
    assert_equal({ "from" => "new", "to" => "chatting", "actor" => "captain" }, event.metadata)
  end

  test "automation may set new, chatting, and lost only" do
    Leads::Transition.call(@lead, to: "chatting", actor: :automation)
    assert_equal "chatting", @lead.reload.status

    error = assert_raises(ActiveRecord::RecordInvalid) do
      Leads::Transition.call(@lead, to: "quoted", actor: :automation)
    end
    assert_match(/stay yours/, error.record.errors.full_messages.to_sentence)
    assert_equal "chatting", @lead.reload.status

    error = assert_raises(ActiveRecord::RecordInvalid) do
      Leads::Transition.call(@lead, to: "nudged", actor: :automation)
    end
    assert_match(/stay yours/, error.record.errors.full_messages.to_sentence)
  end

  test "automation cannot convert" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      Leads::Transition.call(@lead, to: "won", actor: :automation)
    end
    assert_match(/stay yours/, error.record.errors.full_messages.to_sentence)
    assert_not @lead.reload.converted?
  end

  test "captain converting through won moves the timeline" do
    @lead.notes.create!(body: "Loves Everest")
    result = Leads::Transition.call(@lead, to: "won", actor: :captain)
    assert result.converted_client.present?
    assert @lead.reload.converted?
    assert_equal "won", result.to
  end

  test "lost requires a reason from the list" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      Leads::Transition.call(@lead, to: "lost", actor: :captain)
    end
    assert_match(/reason/i, error.record.errors.full_messages.to_sentence)

    error = assert_raises(ActiveRecord::RecordInvalid) do
      Leads::Transition.call(@lead.reload, to: "lost", actor: :captain, lost_reason: "aliens")
    end
    assert error.record.errors[:lost_reason].any?

    Leads::Transition.call(@lead.reload, to: "lost", actor: :captain, lost_reason: "dates", lost_note: "July only")
    assert_equal "dates", @lead.reload.lost_reason
    assert_equal "July only", @lead.reload.lost_note
  end

  test "leaving lost clears the reason" do
    Leads::Transition.call(@lead.reload, to: "lost", actor: :captain, lost_reason: "price")
    Leads::Transition.call(@lead, to: "new", actor: :captain)
    assert_nil @lead.reload.lost_reason
    assert_nil @lead.reload.lost_note
  end

  test "converted leads refuse every transition" do
    @lead.convert_to_client!
    assert_raises(ActiveRecord::RecordInvalid) do
      Leads::Transition.call(@lead.reload, to: "new", actor: :captain)
    end
  end

  test "unknown stages are rejected" do
    assert_raises(ActiveRecord::RecordInvalid) do
      Leads::Transition.call(@lead, to: "orbit", actor: :captain)
    end
  end

  test "stage changes call the landed tasks integration" do
    assert_no_difference "Task.count" do
      assert_equal "chatting", Leads::Transition.call(@lead, to: "chatting", actor: :captain).to
      assert_equal "quoted", Leads::Transition.call(@lead, to: "quoted", actor: :captain).to
    end
    assert_equal "quoted", @lead.reload.status
  end

  test "archived leads refuse every transition, captain or automation" do
    @lead.archive!
    %i[captain automation].each do |actor|
      error = assert_raises(ActiveRecord::RecordInvalid) do
        Leads::Transition.call(@lead, to: "chatting", actor: actor)
      end
      assert_match(/until restored/, error.record.errors.full_messages.to_sentence)
    end
    assert_equal "new", @lead.reload.status
  end
end
