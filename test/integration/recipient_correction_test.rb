require "test_helper"
require_relative "../support/google_sign_in_test_helper"

# Correcting a lead's wrong address must redirect future sends to the new
# address (envelope and headers), while past messages keep the old address
# and intentionally different recipients stay exactly as addressed.
class RecipientCorrectionTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    Setting.current.update!(sender_name: "Sam", email_signature: "Sam Sherpa")
  end

  test "reply defaults and stale submits follow the corrected lead email" do
    lead = Lead.create!(name: "Test Lead", email: "old-wrong@example.test", source: "manual")
    first = Outbound::Composer.call(owner: lead,
      params: { to: "old-wrong@example.test", subject: "Hello", body: "First" })
    conversation = first.conversation

    lead.update!(email: "new-correct@example.test")

    # Empty-To fallback (the reply box default) goes to the correction.
    followup = Outbound::Composer.call(owner: lead.reload, conversation: conversation,
      params: { to: "", subject: "Follow", body: "Second" })
    assert_equal "new-correct@example.test", followup.to_addrs
    assert_equal [ "new-correct@example.test" ], followup.recipients
    assert_equal [ "new-correct@example.test" ], ClientMailer.outbound(followup).to

    # A stale cached form still carrying the old address follows the edit.
    stale = Outbound::Composer.call(owner: lead.reload, conversation: conversation,
      params: { to: "old-wrong@example.test", subject: "Hi", body: "Cached" })
    assert_equal "new-correct@example.test", stale.to_addrs
    assert_equal [ "new-correct@example.test" ], ClientMailer.outbound(stale).to

    # History keeps its attribution; nothing rewrites the first send.
    assert_equal "old-wrong@example.test", first.reload.to_addrs
  end

  test "intentionally different recipients are preserved after a correction" do
    client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    client.people.create!(name: "Pemba", email: "pemba@example.com")
    thread = Outbound::Composer.call(owner: client,
      params: { to: "pemba@example.com", subject: "Hi", body: "Hello" }).conversation

    client.update!(email: "maya-new@example.com")

    followup = Outbound::Composer.call(owner: client.reload, conversation: thread,
      params: { to: "", subject: "Hi", body: "Follow" })
    assert_equal "pemba@example.com", followup.to_addrs

    stranger = Outbound::Composer.call(owner: client.reload, conversation: thread,
      params: { to: "stranger@example.com", subject: "Hi", body: "Hello" })
    assert_equal "stranger@example.com", stranger.to_addrs
  end

  test "a corrected contact address follows the same person" do
    client = Client.create!(name: "Maya Gurung", email: "maya@example.com")
    person = client.people.create!(name: "Pemba", email: "pemba-old@example.com")
    thread = Outbound::Composer.call(owner: client,
      params: { to: "pemba-old@example.com", subject: "Hi", body: "Hello" }).conversation

    person.update!(email: "pemba-new@example.com")

    stale = Outbound::Composer.call(owner: client.reload, conversation: thread,
      params: { to: "pemba-old@example.com", subject: "Hi", body: "Cached" })
    assert_equal "pemba-new@example.com", stale.to_addrs
    assert_equal [ "pemba-new@example.com" ], ClientMailer.outbound(stale).to
  end

  test "composer and saved drafts show the correction, not the old address" do
    lead = Lead.create!(name: "Test Lead", email: "old-wrong@example.test", source: "manual")
    conversation = Outbound::Composer.call(owner: lead,
      params: { to: "old-wrong@example.test", subject: "Hello", body: "First" }).conversation
    conversation.create_draft!(owner: lead, to_addrs: "old-wrong@example.test",
      subject: "Re: Hello", body: "Half written")
    lead.update!(email: "new-correct@example.test")

    sign_in
    get lead_path(lead)
    assert_response :success
    assert_select "input[name='message[to]'][value='new-correct@example.test']"

    patch lead_draft_path(lead), params: {
      conversation_id: conversation.id,
      message: { to: "old-wrong@example.test", subject: "Re: Hello", body: "Half written" }
    }
    assert_equal "new-correct@example.test", conversation.reload.draft.to_addrs
  end
end
