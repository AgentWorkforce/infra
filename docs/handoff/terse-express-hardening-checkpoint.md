# terse-express-hardening: checkpoint before reset (2026-11-22)

1. **Working on:** S3 Express plus an async regional checkpoint for durable-actors (Terse migration). Nothing is in progress now; the last task was the 10k-actor soak (done, torn down).
2. **PRs and branches:**
   - AgentWorkforce/durable-actors#4: MERGED into selfhost/aws-s3 at 08b1cc8e. The branch feat/express-standard-checkpoint is at 1e03efdb.
   - AgentWorkforce/infra#328: MERGED (head 0b68c4e6).
   - AgentWorkforce/durable-actors branch upstream/express-checkpoint-on-273 at b81e1701: the upstream follow-up stacked on TerseAI#273. Held for Olivier; not opened upstream.
   - AgentWorkforce/infra branch bench/express-checkpoint-soak-wip at 7e7a654d: soak tooling (churn harness, chaos actions, overlays). WIP; no PR.
3. **Mid-run:** nothing. No AWS resources: scan was all zero at 2026-11-19T16:05Z. No builds or jobs running; the cost guard is stopped and the Budget deleted. Safe to interrupt.
4. **Waiting on Khaliq:**
   - (a) a PR so restore copies owner records first (restoring a live bucket left 3 of 12,112 actors unrestorable);
   - (b) whether to add the parallel-copy fallback for busy single actors (2-10 s lag);
   - (c) Stage A rollout, which needs an awf-v tag and image publish approval;
   - (d) a decision on the fork #4 ticket check (now moot, merged);
   - (e) the upstream follow-up for Olivier (he opens it; contributor agreement).
5. **To resume:**
   - worktrees under ~/Projects/AgentWorkforce/{durable-actors-worktrees,infra-worktrees};
   - reports in ~/relay-briefs/terse-express-*.md;
   - any AWS run needs a fresh SSO login (or laptop creds) for 805532413586 and Khaliq's direct approval for spend.
