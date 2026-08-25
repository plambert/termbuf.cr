module TermBuf::Unicode
  # How many bytes the character starting with *lead* takes, or zero if *lead*
  # is not a lead byte at all.
  #
  # The over-long and surrogate ranges are excluded, so a byte this accepts
  # begins a character that can exist.
  def self.utf8_length(lead : UInt8) : Int32
    return 1 if lead < 0x80
    return 2 if 0xC2 <= lead <= 0xDF
    return 3 if 0xE0 <= lead <= 0xEF
    return 4 if 0xF0 <= lead <= 0xF4

    0
  end

  # Whether *byte* continues a character rather than beginning one.
  def self.utf8_continuation?(byte : UInt8) : Bool
    0x80 <= byte <= 0xBF
  end

  # How much of *bytes* forms whole characters.
  #
  # A write can end anywhere, including the middle of a character, so the tail
  # this leaves out has to be held until the rest of it arrives.
  def self.utf8_prefix(bytes : Bytes) : Int32
    offset = bytes.size - 1
    limit = Math.max bytes.size - 4, 0

    while offset >= limit
      byte = bytes[offset]

      unless utf8_continuation? byte
        needed = utf8_length byte
        return needed.zero? || bytes.size - offset >= needed ? bytes.size : offset
      end

      offset -= 1
    end

    bytes.size
  end
end
