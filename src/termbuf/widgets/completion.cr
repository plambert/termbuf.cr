module TermBuf
  # What an application is asked when someone presses the completion key, and
  # what it answers.
  #
  # A hook rather than a mechanism: the shard knows where the word is and what
  # to do with the candidates, and nothing at all about what they should be.
  module Completion
    # What is being completed. Indices are cluster indices into the line, the
    # same ones `LineBuffer` counts in.
    record Request,
      # The whole line, since a completion often depends on what came before.
      text : String,
      # Where the cursor is.
      cursor : Int32,
      # The word the field thinks is being completed.
      word : String,
      # Where that word sits, which is what a `Result` replaces by default.
      range : Range(Int32, Int32)

    # What to offer.
    record Result,
      candidates : Array(String),
      # What to replace, or `nil` for the word the request named.
      range : Range(Int32, Int32)? = nil do
      def empty? : Bool
        candidates.empty?
      end
    end

    # A hook returns one of these for a request.
    alias Hook = Request -> Result

    # The longest run every candidate begins with, which is as much as can be
    # inserted without choosing between them.
    def self.common_prefix(candidates : Array(String)) : String
      first = candidates.first?
      return "" unless first
      return first if candidates.size == 1

      length = first.size

      candidates.each do |candidate|
        limit = Math.min length, candidate.size
        index = 0

        while index < limit && candidate[index] == first[index]
          index += 1
        end

        length = index
      end

      first[0, length]
    end
  end
end
