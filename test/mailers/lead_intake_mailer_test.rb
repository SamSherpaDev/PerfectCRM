require "test_helper"

class LeadIntakeMailerTest < ActionMailer::TestCase
  test "inquiry copy goes to the copy-to address with reply-to the visitor" do
    lead = Lead.create!(
      name: "Anna Lindqvist", email: "anna@example.com", source: "google_ads",
      campaign_name: "private-nepal-us-2027", trip_title: "Private Nepal tour",
      message: "Two of us in spring.", placement: "landing",
      phone_raw: "+1 415 555 0134",
      metadata: {
        "attribution" => { "gclid" => "Cj0K-secret", "utm_campaign" => "private-nepal-us-2027" },
        "page" => { "url" => "https://www.sherpaholidays.com/pages/private-nepal-tours" }
      }
    )
    mail = LeadIntakeMailer.inquiry_copy(lead)

    assert_equal [ "info@sherpaholidays.com" ], mail.to
    assert_equal [ "anna@example.com" ], mail.reply_to
    assert_equal [ ENV.fetch("MAIL_FROM", "info@sherpaholidays.com") ], mail.from
    assert_equal "New inquiry from Anna Lindqvist: Private Nepal tour", mail.subject

    body = mail.body.to_s
    assert_includes body, "Anna Lindqvist"
    assert_includes body, "anna@example.com"
    assert_includes body, "+1 415 555 0134"
    assert_includes body, "Private Nepal tour"
    assert_includes body, "Two of us in spring."
    assert_includes body, lead.reference
    assert_includes body, "google_ads"
    assert_includes body, "private-nepal-us-2027"
    assert_includes body, "landing"
    assert_includes body, "https://www.sherpaholidays.com/pages/private-nepal-tours"
    assert_includes body, "/leads/#{lead.id}"
    assert_not_includes body, "Cj0K-secret"
  end

  test "suspected spam prefixes the subject with check" do
    lead = Lead.create!(name: "X", email: "x@example.com", source: "website_form", spam_score: 25)
    lead.tag_list = "suspected_spam"
    lead.save!
    mail = LeadIntakeMailer.inquiry_copy(lead)
    assert_match(/\A\[check\] New inquiry from X:/, mail.subject)
  end

  test "missing trip falls back to not sure yet" do
    lead = Lead.create!(name: "Anna Lindqvist", email: "anna@example.com", source: "website_form")
    mail = LeadIntakeMailer.inquiry_copy(lead)
    assert_equal "New inquiry from Anna Lindqvist: not sure yet", mail.subject
  end

  test "displayed page URL omits tracking parameters without changing metadata" do
    url = "https://www.sherpaholidays.com/contact?gclid=click-secret&gbraid=braid-secret&wbraid=web-secret&utm_source=google&utm_custom=custom-secret&%75tm_medium=cpc&lang=en&lang=fr#inquiry"
    metadata = { "page" => { "url" => url }, "attribution" => { "gclid" => "click-secret" } }
    lead = Lead.create!(name: "Visitor", email: "visitor@example.com", metadata: metadata)
    body = LeadIntakeMailer.inquiry_copy(lead).body.to_s
    assert_includes body, "Page: https://www.sherpaholidays.com/contact?lang=en&lang=fr#inquiry"
    %w[click-secret braid-secret web-secret custom-secret utm_source utm_medium].each do |value|
      assert_not_includes body, value
    end
    assert_equal metadata, lead.reload.metadata
  end

  test "a page URL containing only tracking parameters has no query in email" do
    lead = Lead.create!(name: "Visitor", metadata: { "page" => { "url" => "https://www.sherpaholidays.com/?gclid=secret&utm_campaign=trip" } })
    page_line = LeadIntakeMailer.inquiry_copy(lead).body.to_s.lines.find { |line| line.start_with?("Page:") }
    assert_equal "Page: https://www.sherpaholidays.com/", page_line.strip
  end

  test "invalid page URL is omitted from email" do
    lead = Lead.create!(name: "Visitor", metadata: { "page" => { "url" => "https://bad url/?gclid=secret" } })
    body = LeadIntakeMailer.inquiry_copy(lead).body.to_s
    assert_includes body, "Page: -"
    assert_not_includes body, "secret"
  end
end
