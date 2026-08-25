require "./policy"

module TermBuf::Unicode
  # The `TERMBUF_WIDTHS` escape hatch, which has the last word over whatever
  # the terminal said when it was measured.
  #
  #     TERMBUF_WIDTHS=off                      # skip the probe, keep the tables
  #     TERMBUF_WIDTHS=+ambiguous_wide          # a CJK terminal, said not measured
  #     TERMBUF_WIDTHS=-joined_emoji,-emoji_presentation
  #
  # A bare name turns a rule on, a leading `-` turns it off, and anything not
  # mentioned keeps whatever was measured. `off` skips the measurement.
  #
  # Names are the `WidthPolicy` rules. An unknown one is reported rather than
  # raised on, for the same reason `TERMBUF_CAPS` does it: a typo in an
  # environment variable should not stop an application from starting, and the
  # complaint must not reach the screen the application is about to take over.
  module WidthOverrides
    extend self

    # The variable itself, deliberately not application specific.
    VARIABLE = "TERMBUF_WIDTHS"

    # What the variable asked for, and anything in it that made no sense.
    record Result, policy : WidthPolicy, probe : Bool, warnings : Array(String)

    # Whether *env* asks for the measurement to be skipped.
    def probe?(env : Hash(String, String)) : Bool
      probe? env[VARIABLE]?
    end

    # :ditto:
    def probe?(spec : String?) : Bool
      return true unless spec

      !spec.split(/[,\s]+/, remove_empty: true).any? { |token| token.downcase == "off" }
    end

    # Applies `VARIABLE` from *env* to *base*.
    def apply(base : WidthPolicy, env : Hash(String, String) = ENV.to_h) : Result
      apply base, env[VARIABLE]?
    end

    # Applies a `+name,-name` list to *base*. A `nil` or empty *spec* changes
    # nothing.
    def apply(base : WidthPolicy, spec : String?) : Result
      warnings = [] of String
      return Result.new base, true, warnings if spec.nil? || spec.blank?

      policy = base
      probe = true

      spec.split(/[,\s]+/, remove_empty: true).each do |token|
        if token.downcase == "off"
          probe = false
          next
        end

        policy = apply_token policy, token, warnings
      end

      Result.new policy, probe, warnings
    end

    private def apply_token(policy : WidthPolicy, token : String,
                            warnings : Array(String)) : WidthPolicy
      enabled = !token.starts_with? '-'
      name = token.lstrip("+-").downcase

      return policy.with name, enabled if name.in? WidthPolicy::NAMES

      warnings << "#{VARIABLE}: unknown width rule #{token.inspect}"
      policy
    end
  end
end
