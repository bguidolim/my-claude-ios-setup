import Foundation

/// Bash script fragments injected into hooks by the iOS tech pack.
enum IOSHookFragments {
    /// Fragment for session_start hook: checks for a booted iOS simulator
    /// and outputs its UUID into the session context.
    static let simulatorCheck = #"""
        # === iOS SIMULATOR STATUS ===
        if command -v xcrun >/dev/null 2>&1; then
            booted_sim=$(xcrun simctl list devices booted -j 2>/dev/null \
                | jq -r '[.devices[][] | select(.state == "Booted")] | first // empty' 2>/dev/null)
            if [ -n "$booted_sim" ]; then
                sim_name=$(echo "$booted_sim" | jq -r '.name' 2>/dev/null)
                sim_udid=$(echo "$booted_sim" | jq -r '.udid' 2>/dev/null)
                sim_runtime=$(echo "$booted_sim" | jq -r '.runtime' 2>/dev/null \
                    | sed 's/com.apple.CoreSimulator.SimRuntime.//;s/-/./g')
                context+="\nSimulator: $sim_name ($sim_runtime) [$sim_udid]"
            fi
        fi
    """#
}
