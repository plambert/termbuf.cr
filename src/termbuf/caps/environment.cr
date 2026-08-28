require "./capability"

module TermBuf
  # Guesses what a terminal can do from the environment it was started in.
  #
  # This runs before anything is written to the terminal, and it is all a
  # non-interactive session ever gets. It is deliberately pessimistic: a name
  # nobody recognises comes back with nothing, because a screen full of escape
  # sequences is worse than plain text.
  #
  # Probing runs afterwards and overrides whatever this decided, so being wrong
  # here costs accuracy only where a terminal cannot be asked directly.
  module EnvironmentDetector
    extend self

    # What kitty and its imitators add on top of a current terminal.
    KITTY_EXTRAS = Capability::KittyGraphics | Capability::KittyKeyboard |
                   Capability::KittyColorStack

    # Blinking text, which some current terminals parse and then ignore.
    #
    # There is no query for this and terminfo is no help: ghostty's own entry
    # declares `blink=\E[5m` and nothing on screen blinks. An attribute that
    # is inert rather than harmful is exactly the kind nobody bothers to
    # report accurately, so the only evidence is having looked.
    BLINKING = Capability::Blink | Capability::RapidBlink

    # A current terminal that does not blink. `Capabilities.normalize` drops
    # the rapid variant along with the slow one, so taking both off here is
    # belt and braces.
    GHOSTTY = (Capabilities::MODERN.flags | KITTY_EXTRAS) & ~BLINKING

    # Matched against `TERM`, most specific first.
    TERM_PATTERNS = [
      {/\Adumb/, Capability::None},
      {/kitty/, Capabilities::MODERN.flags | KITTY_EXTRAS},
      {/ghostty/, GHOSTTY},
      {/wezterm/, Capabilities::MODERN.flags | Capability::KittyGraphics},
      {/alacritty/, Capabilities::MODERN.flags},
      {/\Afoot/, Capabilities::MODERN.flags},
      {/\Acontour/, Capabilities::MODERN.flags},
      {/\Ario/, Capabilities::MODERN.flags},
      {/(256color|direct)/, Capabilities::XTERM.flags},
      {/\A(xterm|screen|tmux|rxvt|vte|gnome|konsole|st|ansi|linux|putty|eterm)/,
       Capabilities::ANSI.flags},
      {/\Avt(2|3|4|5)\d\d/, Capabilities::ANSI.flags},
      {/\Avt100/, Capability::Bold | Capability::Underline | Capability::Reverse |
                  Capability::Blink | Capability::ScrollRegion | Capability::AltScreen},
    ]

    # Matched against `TERM_PROGRAM`. These beat the `TERM` guess, since the
    # terminal names itself here rather than naming its terminfo entry.
    PROGRAM_PATTERNS = [
      {"ghostty", GHOSTTY},
      {"WezTerm", Capabilities::MODERN.flags | Capability::KittyGraphics},
      {"iTerm.app", Capabilities::MODERN.flags},
      {"vscode", Capabilities::MODERN.flags},
      {"Hyper", Capabilities::XTERM.flags | Capability::TrueColor},
      {"rio", Capabilities::MODERN.flags},
      {"alacritty", Capabilities::MODERN.flags},
      # Terminal.app 470.2, measured: a smooth 24 bit ramp, bracketed paste,
      # blink, and conceal, but SGR 9 draws no line through anything.
      {"Apple_Terminal", Capabilities::XTERM.flags | Capability::TrueColor |
                         Capability::BracketedPaste},
    ]

    # Set by a terminal that has no `TERM_PROGRAM` of its own, or as well as
    # one. Each carries the name of the terminal that sets it, so a marker
    # inherited from whatever opened the window can be told from one the
    # terminal reading the output set itself.
    MARKER_VARIABLES = [
      {"KITTY_WINDOW_ID", "kitty", Capabilities::MODERN.flags | KITTY_EXTRAS},
      {"GHOSTTY_RESOURCES_DIR", "ghostty", GHOSTTY},
      {"WEZTERM_PANE", "wezterm", Capabilities::MODERN.flags | Capability::KittyGraphics},
      {"WEZTERM_EXECUTABLE", "wezterm", Capabilities::MODERN.flags | Capability::KittyGraphics},
      {"ALACRITTY_WINDOW_ID", "alacritty", Capabilities::MODERN.flags},
      {"KONSOLE_VERSION", "konsole", Capabilities::XTERM.flags | Capability::TrueColor |
                                     Capability::Osc8Links},
      {"ITERM_SESSION_ID", "iterm", Capabilities::MODERN.flags},
    ]

    # A multiplexer sits between the application and the terminal and does not
    # forward everything. The kitty protocols in particular are swallowed,
    # so they come off until a probe says otherwise.
    THROUGH_MULTIPLEXER = KITTY_EXTRAS | Capability::KittyGraphicsTempFile |
                          Capability::SynchronizedOutput

    # Guesses from `TERM`, `TERM_PROGRAM`, `COLORTERM`, `VTE_VERSION`, and the
    # marker variables terminals set for themselves.
    def detect(env : Hash(String, String)) : Capabilities
      # A terminal that says it is dumb is taken at its word. Nothing else in
      # the environment gets a say, since anything that follows would only be
      # inherited from whatever launched it.
      return Capabilities::NONE if dumb? env

      flags = from_term env["TERM"]?
      flags |= from_program env
      flags |= from_markers env
      flags |= from_colorterm env
      flags |= from_vte env

      flags &= ~denied(env)
      flags &= ~THROUGH_MULTIPLEXER if multiplexed? env
      flags = strip_color flags if no_color? env

      Capabilities.new flags
    end

    # Capabilities a name is known not to imply, however much the rest of the
    # environment says otherwise.
    #
    # Separate from the pattern tables because composition is additive: under
    # ghostty with a `TERM` of `xterm-256color`, the xterm entry would put
    # blink back after the ghostty entry left it out, and the `256color`
    # pattern puts strike-through back on Terminal.app. A name that identifies
    # the terminal outranks one that only describes a family.
    DENIALS = [
      {"ghostty", BLINKING},
      # Terminal.app takes SGR 9 and draws the text unchanged.
      {"apple_terminal", Capability::Strike},
    ]

    # :ditto:
    def denials(name : String?) : Capability
      return Capability::None unless name

      lowered = name.downcase
      flags = Capability::None

      DENIALS.each do |(candidate, denied)|
        flags |= denied if lowered.includes? candidate
      end

      flags
    end

    private def denied(env : Hash(String, String)) : Capability
      denials(env["TERM"]?) | denials(identified(env))
    end

    # Which terminal is reading the output, as far as the environment says.
    #
    # `TERM_PROGRAM` wins, because a terminal writing its own name there is
    # saying what it is; a marker variable naming something else was inherited
    # from whatever opened the window and describes a terminal that is no
    # longer in the picture. With no `TERM_PROGRAM`, a marker is the best name
    # there is.
    private def identified(env : Hash(String, String)) : String?
      program = program_name env
      return program if program

      MARKER_VARIABLES.each do |(variable, terminal, _)|
        return terminal if present? env, variable
      end

      nil
    end

    # The `TERM_PROGRAM` entry this environment matches, by the name the table
    # knows it as.
    private def program_name(env : Hash(String, String)) : String?
      name = env["TERM_PROGRAM"]?
      return unless name

      PROGRAM_PATTERNS.each do |(candidate, _)|
        return candidate.downcase if name.compare(candidate, case_insensitive: true).zero?
      end

      nil
    end

    private def dumb?(env : Hash(String, String)) : Bool
      term = env["TERM"]?
      return false unless term

      term.starts_with?("dumb") || term == "unknown"
    end

    private def from_term(term : String?) : Capability
      return Capability::None unless term

      TERM_PATTERNS.each do |(pattern, flags)|
        return flags if pattern.matches? term
      end

      Capability::None
    end

    private def from_program(env : Hash(String, String)) : Capability
      name = env["TERM_PROGRAM"]?
      return Capability::None unless name

      PROGRAM_PATTERNS.each do |(candidate, flags)|
        return flags if name.compare(candidate, case_insensitive: true).zero?
      end

      Capability::None
    end

    # Marker variables, less any that name a terminal other than the one
    # reading the output. Starting Terminal.app from a shell that had ghostty's
    # environment leaves `GHOSTTY_RESOURCES_DIR` set, and taking that at face
    # value hands Terminal.app the kitty graphics protocol.
    private def from_markers(env : Hash(String, String)) : Capability
      named = identified env
      flags = Capability::None

      MARKER_VARIABLES.each do |(variable, terminal, capability)|
        next unless present? env, variable
        next if named && !named.includes?(terminal)

        flags |= capability
      end

      flags
    end

    private def from_colorterm(env : Hash(String, String)) : Capability
      value = env["COLORTERM"]?
      return Capability::None unless value
      return Capability::TrueColor if value.in? "truecolor", "24bit"

      Capability::None
    end

    # VTE gained 24 bit colour in 0.36 and hyperlinks in 0.50.
    private def from_vte(env : Hash(String, String)) : Capability
      version = env["VTE_VERSION"]?.try(&.to_i?)
      return Capability::None unless version

      flags = Capability::None
      flags |= Capabilities::XTERM.flags | Capability::TrueColor if version >= 3600
      flags |= Capability::Osc8Links if version >= 5000
      flags
    end

    private def multiplexed?(env : Hash(String, String)) : Bool
      return true if present? env, "TMUX"
      return true if present? env, "STY"

      term = env["TERM"]?
      return false unless term

      term.starts_with?("screen") || term.starts_with?("tmux")
    end

    # The `NO_COLOR` convention: set to anything non-empty, and colour goes.
    private def no_color?(env : Hash(String, String)) : Bool
      present? env, "NO_COLOR"
    end

    private def strip_color(flags : Capability) : Capability
      flags & ~(Capability::Color16 | Capability::Color256 | Capability::TrueColor |
                Capability::BrightColors | Capability::UnderlineColor)
    end

    private def present?(env : Hash(String, String), name : String) : Bool
      value = env[name]?
      !value.nil? && !value.empty?
    end
  end
end
