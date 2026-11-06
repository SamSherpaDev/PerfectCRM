require "test_helper"
require "minitest/mock"

class LeadsMailDomainTest < ActiveSupport::TestCase
  class Resolver
    attr_reader :closed, :queries

    def initialize(records = {}, error: nil)
      @records, @error, @queries = records, error, []
    end

    def query(domain, type)
      @queries << [ domain, type ]
      raise @error if @error
      Struct.new(:answer).new(Array(@records[type]).map { |value| Dnsruby::RR.create(value) })
    end

    def close = @closed = true
  end

  def check(records = {}, error: nil, email: "visitor@mail.example.org")
    resolver = Resolver.new(records, error: error)
    factory = ->(**options) {
      assert_equal 1, options[:query_timeout]
      assert_equal 1, options[:packet_timeout]
      assert_equal 1, options[:retry_times]
      resolver
    }
    result = Dnsruby::Resolver.stub(:new, factory) { Leads::MailDomain.status(email) }
    assert resolver.closed
    [ result, resolver ]
  end

  test "MX and standard IPv4 and IPv6 fallback accept a mail-capable domain" do
    assert_equal :valid, check({ "MX" => [ "mail.example.org. 60 IN MX 10 mx.example.org." ] }).first
    assert_equal :valid, check({ "A" => [ "mail.example.org. 60 IN A 192.0.2.1" ] }).first
    assert_equal :valid, check({ "AAAA" => [ "mail.example.org. 60 IN AAAA 2001:db8::1" ] }).first
  end

  test "null MX cannot fall back to address records and NXDOMAIN is definitive" do
    result, resolver = check({ "MX" => [ "mail.example.org. 60 IN MX 0 ." ], "A" => [ "mail.example.org. 60 IN A 192.0.2.1" ] })
    assert_equal :invalid, result
    assert_equal 1, resolver.queries.size
    assert_equal :invalid, check.first
    assert_equal :invalid, check(error: Dnsruby::NXDomain.new).first
  end

  test "resolver timeout SERVFAIL refusal and unavailable network are temporary never valid" do
    [ Dnsruby::ResolvTimeout.new, Dnsruby::ServFail.new, Dnsruby::Refused.new, Dnsruby::DecodeError.new,
      Dnsruby::VerifyError.new, Errno::ENETUNREACH.new ].each do |error|
      assert_equal :temporary, check(error: error).first
    end
  end

  test "the real resolver is bounded to one second per query with no retries or DNSSEC validation" do
    resolver = Leads::MailDomain.resolver
    assert_instance_of Dnsruby::Resolver, resolver
    assert_equal 1, resolver.query_timeout
    assert_equal 1, resolver.packet_timeout
    assert_equal 1, resolver.retry_times
    assert_equal false, resolver.dnssec
    assert_equal false, resolver.do_validation
  ensure
    resolver&.close
  end

  test "invalid format and reserved names never query DNS" do
    Dnsruby::Resolver.stub(:new, ->(*) { flunk "unexpected DNS" }) do
      [ "bad", "a@@example.org", "a@-invalid.org", "a..b@example.org", "a@example.invalid", "a@localhost", "a@192.0.2.1" ].each do |email|
        assert_equal :invalid, Leads::MailDomain.status(email), email
      end
    end
  end
end
