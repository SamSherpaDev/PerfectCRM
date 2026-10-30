require "test_helper"
require_relative "../support/google_sign_in_test_helper"

class OrganizationsRequestsTest < ActionDispatch::IntegrationTest
  include GoogleSignInTestHelper

  setup do
    sign_in
  end

  test "show renders facts, referrals, notes, and timeline" do
    org = Organization.create!(name: "Himalayan Ground", kind: "operator", email: "ops@example.com", phone: "+16097810024", perfectbook_contact_id: 55)
    client = Client.create!(name: "Tashi", referred_by_organization: org)
    Note.create!(notable: org, body: "Reliable")
    get organization_path(org)
    assert_response :success
    assert_select "h1", "Himalayan Ground"
    assert_select "dd", text: "609-781-0024"
    assert_select "a", text: "Open in PerfectBook"
    assert_select "a", text: "Tashi"
    assert_select "h2", text: "Notes"
    assert_select "h2", text: "Timeline"
  end

  test "show leaves the CRM signature logo out of mail rows and the outbound timeline while listing real files" do
    logo = "\x89PNG\r\n\x1A\n".b + [ 13 ].pack("N") + "IHDR" + [ 120, 40 ].pack("NN") + "\x08\x02\x00\x00\x00org-logo".b
    Setting.current.signature_logo.attach(io: StringIO.new(logo), filename: "signature-logo.png", content_type: "image/png")
    org = Organization.create!(name: "Himalayan Ground", kind: "operator", email: "ops@example.com")
    conversation = Conversation.create!(subject: "Permits", linkable: org, last_message_at: Time.current)
    outbound = conversation.messages.create!(direction: "out", status: "sent", to_addrs: org.email,
      subject: "Permits", text_body: "Permit list attached.", sent_at: 2.days.ago)
    outbound.files.attach(io: StringIO.new("%PDF-1.4 permits"), filename: "permits.pdf", content_type: "application/pdf")
    outbound.files.attach(io: StringIO.new(logo), filename: "signature-logo.png", content_type: "image/png")
    reply = conversation.messages.create!(direction: "in", from_address: org.email,
      subject: "Re: Permits", text_body: "Received.", sent_at: 1.day.ago)
    reply.files.attach(io: StringIO.new(logo), filename: "signature-logo.png", content_type: "image/png")
    permits = outbound.reload.files.find { |file| file.filename.to_s == "permits.pdf" }
    logo_files = [ outbound.files.find { |file| file.filename.to_s == "signature-logo.png" }, reply.reload.files.first ]

    get organization_path(org)
    assert_response :success
    assert_select "ul.thread-attachments", count: 1
    assert_select "ul.thread-attachments li.attachment-row", count: 1
    assert_select "li.attachment-row a[href=?]", new_document_handoff_path(attachment_id: permits.id), count: 1
    assert_select ".reply-thread ul[aria-label='Attachments']", count: 1
    assert_select ".reply-thread ul[aria-label='Attachments'] a[href=?]", attachment_path(permits.id), text: "permits.pdf", count: 1
    logo_files.each do |file|
      assert_select "a[href=?]", attachment_path(file.id), count: 0
      assert_select "a[href=?]", new_document_handoff_path(attachment_id: file.id), count: 0
    end
  ensure
    Setting.current.signature_logo.purge if Setting.current.signature_logo.attached?
  end

  test "new and create" do
    get new_organization_path
    assert_response :success
    post organizations_path, params: {
      organization: { name: "Denver Travel", kind: "advisor", email: "hi@denver.example", tag_list: "advisor" }
    }
    assert_redirected_to organization_path(Organization.last)
    assert_equal "advisor", Organization.last.kind
  end

  test "edit and update" do
    org = Organization.create!(name: "Ops")
    get edit_organization_path(org)
    assert_response :success
    patch organization_path(org), params: { organization: { name: "Ops Updated" } }
    assert_redirected_to organization_path(org)
    assert_equal "Ops Updated", org.reload.name
  end
end
