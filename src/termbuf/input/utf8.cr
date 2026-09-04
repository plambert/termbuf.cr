module TermBuf::Input
  # As much of UTF-8 as decoding a keystroke needs.
  #
  # A deliberate copy of the one thing `TermBuf::Unicode` offers that the
  # decoder uses, so that the input side carries no dependency on the width and
  # grapheme machinery it has no use for.
  module Utf8
    # How many bytes the character starting with *lead* takes, or zero if
    # *lead* is not a lead byte at all.
    #
    # The over-long and surrogate ranges are excluded, so a byte this accepts
    # begins a character that can exist.
    def self.length(lead : UInt8) : Int32
      return 1 if lead < 0x80
      return 2 if 0xC2 <= lead <= 0xDF
      return 3 if 0xE0 <= lead <= 0xEF
      return 4 if 0xF0 <= lead <= 0xF4

      0
    end
  end
end
