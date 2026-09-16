# Counts each history message once across every run of one import.
#
# The history walk resumes on an inclusive boundary, so a resumed run
# replays every message that shares the second its cursor names. Holding the
# ids seen at the current cursor, and forgetting them the moment the walk
# moves past that second, keeps the replay from counting twice without ever
# holding the whole mailbox. Preview and import both walk the same history
# and both have to count it the same way, so the rule lives here once.
module Mail
  class HistoryTally
    attr_reader :cursor

    def initialize(cursor: nil, seen: nil)
      @cursor = cursor
      @seen = Set.new(Array(seen))
    end

    def seen
      @seen.to_a
    end

    # True the first time this item is offered at the cursor it carries.
    def count?(item)
      unless item.cursor == @cursor
        @cursor = item.cursor
        @seen.clear
      end
      !@seen.add?(item.provider[:message_id].to_s).nil?
    end
  end
end
