require "./capability"

module TermBuf
  # The `TERMBUF_CAPS` escape hatch, which has the last word over everything
  # detection worked out.
  #
  #     TERMBUF_CAPS=+truecolor,-kitty_graphics,+osc8_links
  #     TERMBUF_CAPS=none,+color16
  #     TERMBUF_CAPS=all
  #
  # A bare name turns a capability on, a leading `-` turns it off, and anything
  # not mentioned keeps whatever it was detected as. `none` and `all` set a
  # starting point for the rest of the list.
  #
  # Names are the `Capability` members in snake case. An unknown one is
  # reported rather than raised on: a typo in an environment variable should
  # not stop an application from starting, and it must not print to the screen
  # the application is about to take over.
  module CapabilityOverrides
    extend self

    # The variable itself, deliberately not application specific.
    VARIABLE = "TERMBUF_CAPS"

    # What the variable asked for, and anything in it that made no sense.
    record Result, capabilities : Capabilities, warnings : Array(String)

    # Applies `VARIABLE` from *env* to *base*.
    def apply(base : Capabilities, env : Hash(String, String)) : Result
      apply base, env[VARIABLE]?
    end

    # Applies a `+name,-name` list to *base*. A `nil` or empty *spec* changes
    # nothing.
    def apply(base : Capabilities, spec : String?) : Result
      warnings = [] of String
      return Result.new base, warnings if spec.nil? || spec.blank?

      capabilities = base

      spec.split(/[,\s]+/, remove_empty: true).each do |token|
        capabilities = apply_token capabilities, token, warnings
      end

      Result.new capabilities, warnings
    end

    # Each step goes through `Capabilities`, so that the implications between
    # capabilities apply here too: turning 24 bit colour on brings the narrower
    # depths with it, and turning the 256 colour palette off takes 24 bit
    # colour with it rather than leaving a mask that claims both.
    private def apply_token(capabilities : Capabilities, token : String,
                            warnings : Array(String)) : Capabilities
      enable = true
      name = token

      case token[0]?
      when '+' then name = token[1..]
      when '-'
        enable = false
        name = token[1..]
      end

      case name.downcase
      when "none" then return Capabilities::NONE
      when "all"  then return Capabilities.new Capability::All
      end

      capability = Capability.parse? name

      unless capability
        warnings << "#{VARIABLE}: unknown capability #{token.inspect}"
        return capabilities
      end

      enable ? capabilities.with(capability) : capabilities.without(capability)
    end
  end
end
