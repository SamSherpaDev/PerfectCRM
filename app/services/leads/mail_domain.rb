# Quiz-only receivable-domain check. No mailbox probing and no fail-open.
# dnsruby, not stdlib Resolv: Resolv#getresources returns [] for NXDOMAIN,
# SERVFAIL, refusal and (on some versions) timeouts alike, so it cannot tell a
# domain that cannot receive mail from a check that is temporarily unavailable.
module Leads::MailDomain
  module_function

  def status(email)
    return :invalid unless email.is_a?(String) && email.bytesize <= 254 && email.match?(URI::MailTo::EMAIL_REGEXP)

    local, domain = email.split("@", -1)
    return :invalid unless local.present? && local.bytesize <= 64 && domain.present?
    return :invalid if local.start_with?(".") || local.end_with?(".") || local.include?("..")
    return :invalid unless domain.match?(/\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i)
    return :invalid if domain.downcase.end_with?(".invalid", ".example", ".test", ".localhost")

    # At most three queries, each with a one-second overall deadline and one
    # attempt per configured resolver. No unbounded retry or external service.
    resolver = self.resolver
    mx = records(resolver, domain, "MX")
    unless mx.empty?
      return :invalid if mx.any? { |record| record.exchange.to_s.sub(/\.$/, "").empty? }
      return :valid
    end
    return :valid if records(resolver, domain, "A").any?
    return :valid if records(resolver, domain, "AAAA").any?

    :invalid
  rescue Dnsruby::NXDomain
    :invalid
  rescue Dnsruby::ResolvError, Dnsruby::ResolvTimeout, IOError, SocketError, SystemCallError
    :temporary
  ensure
    resolver&.close
  end

  def resolver
    Dnsruby::Resolver.new(query_timeout: 1, packet_timeout: 1, retry_times: 1)
  end

  def records(resolver, domain, type)
    resolver.query(domain, type).answer.select { |record| record.type.to_s == type }
  end
end
