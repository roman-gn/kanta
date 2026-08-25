Application.ensure_all_started(:kanta)

Kanta.Test.Repo.start_link()

Kanta.start_link(
  endpoint: Kanta.Test.Endpoint,
  repo: Kanta.Test.Repo,
  otp_name: :kanta,
  plugins: []
)

# The extractor agent runs its first extraction in a `handle_continue`, so wait
# for that to finish while the repo still checks out connections automatically.
# Matching on the result fails the run loudly if that extraction did not succeed,
# rather than leaving the agent to retry against the manual-mode sandbox mid-suite.
%{stale_detection_result: %Kanta.PoFiles.Services.StaleDetection.Result{}} =
  :sys.get_state(Kanta.PoFiles.MessagesExtractorAgent, :infinity)

ExUnit.start()

# clear translations cache
Kanta.Cache.delete_all()

Ecto.Adapters.SQL.Sandbox.mode(Kanta.Test.Repo, :manual)
