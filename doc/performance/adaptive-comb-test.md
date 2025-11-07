# adaptive-comb-test.slang — Performance Notes

Summary
- Testbed for adaptive comb filtering and related experiments. Intended for development and benchmarking.

Hot Parameters
- Any parameters controlling tap count or bandwidth will directly impact loop size and texture fetches.

Cost Drivers
- Expect multiple dependent texture reads per iteration plus carrier math if modulation is involved.

Tuning Strategy
- For general users, avoid this shader in runtime pipelines; prefer `composite.slang` with COMB_FILTER_TAPS tuning instead.

Quick Profiles
- Low: Use minimal tap settings; disable adaptive branches if exposed
- Med/High: For profiling only; adjust per test
