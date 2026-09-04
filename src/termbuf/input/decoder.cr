require "./scanner"
require "./utf8"
require "./event"
require "./patterns"
require "./key"

module TermBuf::Input
  # Turns the bytes a terminal sends into events.
  #
  # Three things arrive on the same stream and have to be told apart: replies
  # to queries the application made, text that was pasted rather than typed,
  # and key presses. The first is settled by whoever set `#on_sequence`, since
  # nothing about the bytes says whether a finger or a terminal produced them.
  # The second is settled by the bracketed paste markers. Everything left is a
  # key.
  #
  # State is carried between calls, because none of the three respects the
  # boundaries of a read: an escape sequence, a UTF-8 character, and a paste can
  # each be split across as many reads as the kernel feels like.
  class Decoder
    # Where a paste stops being a paste and starts being a denial of service.
    # Reached only by a terminal that sent an opening marker and no closing one.
    MAX_PASTE = 4 * 1024 * 1024

    # How long to wait for the rest of an escape sequence before deciding there
    # is no rest.
    #
    # The escape key sends one byte and so does the start of every arrow key,
    # so the two are indistinguishable until either more bytes arrive or enough
    # time passes that none will.
    ESCAPE_TIMEOUT = 25.milliseconds

    # How long a paste has to have been arriving before it is worth telling the
    # application about. Measured from the opening marker whether or not
    # anything followed it.
    PASTE_NOTICE = 300.milliseconds

    # How often the byte count is worth resending. A paste large enough to
    # notice arrives in hundreds of reads, and an application draining the
    # channel slowly should not be made to drain hundreds of notices.
    PASTE_PROGRESS = 100.milliseconds

    # How long a paste may go without a single byte before it is treated as
    # abandoned.
    #
    # Reset by every byte rather than measured from the opening marker, because
    # the question is whether the paste is slow or stopped and the only evidence
    # either way is whether anything is still arriving. A paste over a link with
    # seconds of latency stays alive as long as it makes progress; one whose
    # closing marker will never come ends here rather than swallowing every
    # keystroke after it.
    PASTE_STALL = 3.seconds

    # Never ask for a read deadline shorter than this. A deadline that has
    # already passed would otherwise become a zero or negative timeout.
    MINIMUM_DEADLINE = 1.millisecond

    PASTE_START = "\e[200~".to_slice
    PASTE_END   = "\e[201~".to_slice

    # See `ESCAPE_TIMEOUT`. Worth raising over a slow link, where a sequence can
    # take longer than that to arrive in full.
    property escape_timeout : Time::Span = ESCAPE_TIMEOUT

    # See `PASTE_NOTICE`.
    property paste_notice : Time::Span = PASTE_NOTICE

    # See `PASTE_PROGRESS`.
    property paste_progress : Time::Span = PASTE_PROGRESS

    # See `PASTE_STALL`.
    property paste_stall : Time::Span = PASTE_STALL

    # Whether the terminal is speaking the kitty keyboard protocol.
    #
    # Set by `Terminal` when the capability set says the protocol was asked
    # for. It changes nothing about how a sequence is read — a `CSI ... u` is
    # decoded either way, since a terminal left in that mode by whatever ran
    # before should still work — only about what waiting means.
    #
    # With the protocol on, the escape key arrives as `CSI 27 u`, so a lone
    # `ESC` is always the start of something longer and there is nothing to
    # time out. Held bytes are then held until the rest of them turn up, and
    # the decoder asks for no deadline of its own.
    property? kitty_keyboard : Bool = false

    # Asked what a complete escape sequence means before it is treated as a
    # key press, and answered with `nil` when it means nothing in particular.
    #
    # This is the seam the pattern registry hangs off. The decoder deliberately
    # does not own it: which replies an application is waiting for changes while
    # it runs, and the decoder's own state does not.
    property on_sequence : (Sequence -> Event?)? = nil

    def initialize
      @scanner = SequenceScanner.new
      @partial = IO::Memory.new
      @paste = IO::Memory.new
      @pasting = false
      @pending_since = nil.as(Time::Instant?)
      @paste_opened = nil.as(Time::Instant?)
      @paste_touched = nil.as(Time::Instant?)
      @notified = nil.as(Time::Instant?)
    end

    # Whether a paste is open, so that text is being collected rather than
    # delivered as keys.
    getter? pasting : Bool

    # Feeds bytes in, yielding whatever they completed.
    def feed(bytes : Bytes, &emit : Event ->) : Nil
      @scanner.feed(bytes) { |kind, chunk| dispatch kind, chunk, emit }
      mark_pending
    end

    # Whether anything is being held back for want of more bytes.
    #
    # What the escape timeout is for: a lone escape looks exactly like the start
    # of an arrow key until enough time passes that no arrow key is coming.
    def pending? : Bool
      @scanner.pending? || @partial.bytesize > 0
    end

    # How long the reader may wait before calling `#tick`, or `nil` when it may
    # block until something arrives.
    #
    # Every piece of held state is a bet that more bytes are coming, and each
    # one needs its losing case. With nothing held and no paste open there is
    # nothing to time, so an idle application costs nothing.
    def read_deadline : Time::Span?
      now = Time.instant
      soonest = nil.as(Time::Span?)

      # Nothing to time when the terminal spells the escape key out in full.
      # See `#kitty_keyboard?`.
      if !kitty_keyboard? && (since = @pending_since)
        soonest = @escape_timeout - (now - since)
      end

      if opened = @paste_opened
        soonest = sooner soonest, @paste_stall - (now - (@paste_touched || opened))
        soonest = sooner soonest, notice_due(opened) - now
      end

      return unless soonest

      soonest > MINIMUM_DEADLINE ? soonest : MINIMUM_DEADLINE
    end

    # Called when a read deadline expires. Works out which one it was.
    def tick(&emit : Event ->) : Nil
      now = Time.instant

      if !kitty_keyboard? && (since = @pending_since)
        flush { |event| emit.call event } if now - since >= @escape_timeout
      end

      return unless opened = @paste_opened
      return finish_paste false, emit if now - (@paste_touched || opened) >= @paste_stall

      notify now, opened, emit
    end

    # Gives up waiting and delivers what is held back for what it is: an escape
    # that begins nothing is the escape key, and a truncated character is a
    # broken one.
    def flush(&emit : Event ->) : Nil
      @scanner.flush { |kind, chunk| dispatch kind, chunk, emit }
      flush_partial emit
      mark_pending
    end

    # The escape deadline runs from the moment something was first held back,
    # not from the last read: waking up for a paste notice must not shorten it.
    private def mark_pending : Nil
      if pending?
        @pending_since ||= Time.instant
      else
        @pending_since = nil
      end
    end

    private def sooner(current : Time::Span?, candidate : Time::Span) : Time::Span
      current.nil? || candidate < current ? candidate : current
    end

    private def notice_due(opened : Time::Instant) : Time::Instant
      last = @notified
      last ? last + @paste_progress : opened + @paste_notice
    end

    private def notify(now : Time::Instant, opened : Time::Instant, emit : Event ->) : Nil
      return if now < notice_due opened

      @notified = now
      emit.call Events::Pasting.new(@paste.bytesize, now - opened)
    end

    # ------------------------------------------------------------ dispatch

    private def dispatch(kind : SequenceScanner::Kind, chunk : Bytes, emit : Event ->) : Nil
      # The scanner hands out slices of a buffer it reuses, so anything kept
      # past this call has to be copied.
      kind.sequence? ? sequence(chunk.dup, emit) : text(chunk, emit)
    end

    private def sequence(bytes : Bytes, emit : Event ->) : Nil
      # A character cannot be half-delivered across an escape sequence; if one
      # looks like it was, the stream is broken and saying so beats waiting.
      flush_partial emit

      return paste_marker bytes, emit if @pasting

      if handler = @on_sequence
        if event = handler.call Sequence.parse(bytes)
          emit.call event
          return
        end
      end

      return open_paste if bytes == PASTE_START

      # The tail of a paste this decoder already gave up on. `ESC [ 201 ~` is
      # never a keystroke, and reporting it as an unknown key would be an odd
      # end to an odd episode.
      return if bytes == PASTE_END

      emit.call Events::Key.new(decode(bytes), bytes)
    end

    private def open_paste : Nil
      now = Time.instant

      @pasting = true
      @paste.clear
      @paste_opened = now
      @paste_touched = now
      @notified = nil
    end

    private def finish_paste(complete : Bool, emit : Event ->) : Nil
      text = @paste.to_s

      @pasting = false
      @paste.clear
      @paste_opened = nil
      @paste_touched = nil
      @notified = nil

      emit.call Events::Paste.new(text, complete)
    end

    # Inside a paste, only the closing marker is a sequence. Anything else is
    # something that was on the clipboard, and terminals do not all strip it.
    private def paste_marker(bytes : Bytes, emit : Event ->) : Nil
      return collect bytes, emit unless bytes == PASTE_END

      finish_paste true, emit
    end

    private def text(chunk : Bytes, emit : Event ->) : Nil
      return collect chunk, emit if @pasting

      data = joined chunk
      offset = 0

      while offset < data.size
        consumed = character data, offset, emit
        break if consumed.zero?

        offset += consumed
      end

      @partial.clear
      @partial.write data[offset..]
    end

    private def collect(bytes : Bytes, emit : Event ->) : Nil
      @paste.write bytes
      # Progress, which is what keeps the stall deadline from running out.
      @paste_touched = Time.instant

      return if @paste.bytesize <= MAX_PASTE

      finish_paste false, emit
    end

    # What was held back last time, with the new bytes after it.
    private def joined(chunk : Bytes) : Bytes
      return chunk if @partial.bytesize.zero?

      held = @partial.to_slice
      combined = Bytes.new held.size + chunk.size
      held.copy_to combined
      chunk.copy_to combined + held.size
      combined
    end

    private def flush_partial(emit : Event ->) : Nil
      return if @partial.bytesize.zero?

      bytes = @partial.to_slice.dup
      @partial.clear
      emit.call Events::Key.new(Key.character(Char::REPLACEMENT), bytes)
    end

    # -------------------------------------------------------------- text

    # Decodes one character from *data* at *offset*, returning how many bytes it
    # took. Zero means the rest of it has yet to arrive.
    private def character(data : Bytes, offset : Int32, emit : Event ->) : Int32
      lead = data[offset]
      return control lead, emit if lead < 0x80

      length = Utf8.length lead
      return replacement(data, offset, 1, emit) if length.zero?
      return 0 if offset + length > data.size

      bytes = data[offset, length].dup
      text = String.new bytes
      emit.call Events::Key.new(Key.character(text[0]? || Char::REPLACEMENT), bytes)
      length
    end

    private def replacement(data : Bytes, offset : Int32, length : Int32, emit : Event ->) : Int32
      emit.call Events::Key.new(Key.character(Char::REPLACEMENT), data[offset, length].dup)
      length
    end

    private def control(byte : UInt8, emit : Event ->) : Int32
      emit.call Events::Key.new(control_key(byte), Bytes[byte])
      1
    end

    # The C0 controls, which is how a terminal in raw mode reports the keys
    # that predate escape sequences.
    #
    # The table lives on `Key`, because a binding table written as text is read
    # against the same one and the two agreeing is the whole point.
    private def control_key(byte : UInt8) : Key
      Key.from_control byte
    end

    # ---------------------------------------------------------- sequences

    # What one complete escape sequence means.
    def decode(bytes : Bytes) : Key
      return Key.named Key::Name::Escape if bytes.size <= 1

      case bytes[1]
      when '['.ord then csi bytes
      when 'O'.ord then ss3 bytes
      else              alt bytes
      end
    end

    # `ESC` then a character is that character with alt held: the terminal has
    # no other way to say so without the kitty protocol.
    private def alt(bytes : Bytes) : Key
      text = String.new bytes[1..]
      char = text[0]?
      return Key.named Key::Name::Unknown unless char

      base = char.ord < 0x80 ? control_key(char.ord.to_u8) : Key.character(char)
      Key.new base.name, base.char, base.modifiers | Modifiers::Alt
    end

    # `ESC O x`, which is the application keypad form of the arrows and the
    # first four function keys.
    private def ss3(bytes : Bytes) : Key
      return Key.named Key::Name::Unknown if bytes.size < 3

      name = SS3_KEYS[bytes[2].unsafe_chr]?
      name ? Key.named(name) : Key.named(Key::Name::Unknown)
    end

    SS3_KEYS = {
      'A' => Key::Name::Up, 'B' => Key::Name::Down,
      'C' => Key::Name::Right, 'D' => Key::Name::Left,
      'H' => Key::Name::Home, 'F' => Key::Name::End,
      'E' => Key::Name::Begin, 'M' => Key::Name::Enter,
      'P' => Key::Name::F1, 'Q' => Key::Name::F2,
      'R' => Key::Name::F3, 'S' => Key::Name::F4,
    }

    # Arrows, and everything sharing their shape, in the `ESC [ 1 ; m x` form.
    LETTER_KEYS = {
      'A' => Key::Name::Up, 'B' => Key::Name::Down,
      'C' => Key::Name::Right, 'D' => Key::Name::Left,
      'H' => Key::Name::Home, 'F' => Key::Name::End,
      'E' => Key::Name::Begin,
      'P' => Key::Name::F1, 'Q' => Key::Name::F2,
      'R' => Key::Name::F3, 'S' => Key::Name::F4,
    }

    # `ESC [ n ~`, where *n* names the key. The gaps are where DEC left room
    # for keys nobody built.
    TILDE_KEYS = {
      1 => Key::Name::Home, 2 => Key::Name::Insert,
      3 => Key::Name::Delete, 4 => Key::Name::End,
      5 => Key::Name::PageUp, 6 => Key::Name::PageDown,
      7 => Key::Name::Home, 8 => Key::Name::End,
      11 => Key::Name::F1, 12 => Key::Name::F2,
      13 => Key::Name::F3, 14 => Key::Name::F4,
      15 => Key::Name::F5, 17 => Key::Name::F6,
      18 => Key::Name::F7, 19 => Key::Name::F8,
      20 => Key::Name::F9, 21 => Key::Name::F10,
      23 => Key::Name::F11, 24 => Key::Name::F12,
      25 => Key::Name::F13, 26 => Key::Name::F14,
      28 => Key::Name::F15, 29 => Key::Name::F16,
      31 => Key::Name::F17, 32 => Key::Name::F18,
      33 => Key::Name::F19, 34 => Key::Name::F20,
    }

    # The kitty keyboard protocol's functional keys, which it reports as code
    # points in the Unicode private use area so that they cannot collide with
    # anything a person could type.
    #
    # Only the keys with no other encoding are here. Escape, enter, tab and
    # backspace arrive as their C0 bytes, `CSI 27 u` and the rest, and the
    # arrows and the first twelve function keys keep the shapes every terminal
    # has always used, so all of those go through `#control_key` and the tables
    # above instead. The gap below 57358 is unassigned by the protocol; a code
    # in it is delivered as the character it nominally is.
    #
    # See <https://sw.kovidgoyal.net/kitty/keyboard-protocol/>.
    KITTY_KEYS = {
      57358 => Key::Name::CapsLock,
      57359 => Key::Name::ScrollLock,
      57360 => Key::Name::NumLock,
      57361 => Key::Name::PrintScreen,
      57362 => Key::Name::Pause,
      57363 => Key::Name::Menu,
      57376 => Key::Name::F13,
      57377 => Key::Name::F14,
      57378 => Key::Name::F15,
      57379 => Key::Name::F16,
      57380 => Key::Name::F17,
      57381 => Key::Name::F18,
      57382 => Key::Name::F19,
      57383 => Key::Name::F20,
      57384 => Key::Name::F21,
      57385 => Key::Name::F22,
      57386 => Key::Name::F23,
      57387 => Key::Name::F24,
      57388 => Key::Name::F25,
      57389 => Key::Name::F26,
      57390 => Key::Name::F27,
      57391 => Key::Name::F28,
      57392 => Key::Name::F29,
      57393 => Key::Name::F30,
      57394 => Key::Name::F31,
      57395 => Key::Name::F32,
      57396 => Key::Name::F33,
      57397 => Key::Name::F34,
      57398 => Key::Name::F35,
      57399 => Key::Name::KP0,
      57400 => Key::Name::KP1,
      57401 => Key::Name::KP2,
      57402 => Key::Name::KP3,
      57403 => Key::Name::KP4,
      57404 => Key::Name::KP5,
      57405 => Key::Name::KP6,
      57406 => Key::Name::KP7,
      57407 => Key::Name::KP8,
      57408 => Key::Name::KP9,
      57409 => Key::Name::KPDecimal,
      57410 => Key::Name::KPDivide,
      57411 => Key::Name::KPMultiply,
      57412 => Key::Name::KPSubtract,
      57413 => Key::Name::KPAdd,
      57414 => Key::Name::KPEnter,
      57415 => Key::Name::KPEqual,
      57416 => Key::Name::KPSeparator,
      57417 => Key::Name::KPLeft,
      57418 => Key::Name::KPRight,
      57419 => Key::Name::KPUp,
      57420 => Key::Name::KPDown,
      57421 => Key::Name::KPPageUp,
      57422 => Key::Name::KPPageDown,
      57423 => Key::Name::KPHome,
      57424 => Key::Name::KPEnd,
      57425 => Key::Name::KPInsert,
      57426 => Key::Name::KPDelete,
      57427 => Key::Name::KPBegin,
      57428 => Key::Name::MediaPlay,
      57429 => Key::Name::MediaPause,
      57430 => Key::Name::MediaPlayPause,
      57431 => Key::Name::MediaReverse,
      57432 => Key::Name::MediaStop,
      57433 => Key::Name::MediaFastForward,
      57434 => Key::Name::MediaRewind,
      57435 => Key::Name::MediaTrackNext,
      57436 => Key::Name::MediaTrackPrevious,
      57437 => Key::Name::MediaRecord,
      57438 => Key::Name::LowerVolume,
      57439 => Key::Name::RaiseVolume,
      57440 => Key::Name::MuteVolume,
      57441 => Key::Name::LeftShift,
      57442 => Key::Name::LeftControl,
      57443 => Key::Name::LeftAlt,
      57444 => Key::Name::LeftSuper,
      57445 => Key::Name::LeftHyper,
      57446 => Key::Name::LeftMeta,
      57447 => Key::Name::RightShift,
      57448 => Key::Name::RightControl,
      57449 => Key::Name::RightAlt,
      57450 => Key::Name::RightSuper,
      57451 => Key::Name::RightHyper,
      57452 => Key::Name::RightMeta,
      57453 => Key::Name::IsoLevel3Shift,
      57454 => Key::Name::IsoLevel5Shift,
    }

    private def csi(bytes : Bytes) : Key
      body = String.new bytes[2..]
      return Key.named Key::Name::Unknown if body.empty?

      # A private parameter byte means this is a report of some kind — a mouse
      # position, a mode setting — rather than a key.
      return Key.named Key::Name::Unknown if body[0].in? '<', '?', '>', '='

      final = body[-1]
      numbers = parameters body[0, body.size - 1]

      case final
      when '~' then tilde numbers
      when 'u' then unicode numbers
      when 'Z' then Key.named Key::Name::Tab, modifiers(numbers) | Modifiers::Shift
      else          letter final, numbers
      end
    end

    # Splits the parameters of a control sequence. A colon introduces
    # subparameters, which nothing decoded here uses, so only the first counts.
    private def parameters(text : String) : Array(Int32)
      return [] of Int32 if text.empty?

      text.split(';').map { |part| part.split(':', 2).first.to_i? || 0 }
    end

    # Parameter two is the modifier set, one greater than the bits themselves so
    # that "nothing held down" is not an empty parameter.
    private def modifiers(numbers : Array(Int32), index : Int32 = 1) : Modifiers
      value = numbers[index]? || 1
      return Modifiers::None if value < 2

      Modifiers.new(((value - 1) & 0x0F).to_u8)
    end

    private def letter(final : Char, numbers : Array(Int32)) : Key
      name = LETTER_KEYS[final]?
      return Key.named Key::Name::Unknown unless name

      # `ESC [ R` on its own is a cursor position report that nobody registered,
      # not F3. The function keys only take this shape when modified, and then
      # the first parameter is always the 1 that leaves room for the second.
      if final.in?('P', 'Q', 'R', 'S') && (numbers.size < 2 || numbers[0] != 1)
        return Key.named Key::Name::Unknown
      end

      Key.named name, modifiers(numbers)
    end

    private def tilde(numbers : Array(Int32)) : Key
      code = numbers[0]? || 0

      # `ESC [ 27 ; m ; c ~` is xterm reporting a key it could not encode any
      # other way, with the character itself as the third parameter.
      if code == 27 && numbers.size >= 3
        return other_key numbers[2], modifiers(numbers)
      end

      name = TILDE_KEYS[code]?
      name ? Key.named(name, modifiers(numbers)) : Key.named(Key::Name::Unknown)
    end

    # `ESC [ c ; m u`, the kitty keyboard protocol's form for a character with
    # modifiers. Decoded whether or not the protocol was asked for, since a
    # terminal left in that mode by whatever ran before should still work.
    private def unicode(numbers : Array(Int32)) : Key
      code = numbers[0]? || 0
      other_key code, modifiers(numbers)
    end

    private def other_key(code : Int32, held : Modifiers) : Key
      return Key.named Key::Name::Unknown unless 0 <= code <= Char::MAX_CODEPOINT

      if name = KITTY_KEYS[code]?
        return Key.named name, held
      end

      char = code.chr
      return Key.character char, held if code >= 0x20 && code != 0x7F

      base = control_key code.to_u8
      Key.new base.name, base.char, base.modifiers | held
    end
  end
end
