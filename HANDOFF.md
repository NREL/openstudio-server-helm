# Handoff: Fix Upload Corruption, Reinstall, Resubmit

## Context / What's already fixed
Working directory: `/Users/achapin/179D/openstudio-server-helm` (branch `faster-scaleup`, 2 commits ahead of origin).
Gem repo: `~/179D/openstudio-bem-to-surrogate-gem` (submits via `bundle exec rake execute_sequential` against `http://localhost:61570` port-forwarded to the `web` service).

Over the course of this session we fixed several real infra bugs in the Helm chart (`openstudio-server/templates/...`, values in `openstack/values-openstack.yaml`):

1. **`OS_SERVER_PROJECT_PATH` env var** was missing on `web`, `web-background`, and `worker` deployments -> now set to `/mnt/openstudio` on all three, so `APP_CONFIG['server_asset_path']` resolves consistently across pods (previously each pod fell back to a different local default).
2. **Worker pods were using `emptyDir`** instead of the shared `nfs-pvc` for `/mnt/openstudio` -> changed `templates/worker/worker-deploy.yaml` to mount `nfs-pvc` (same as `web`/`web-background`), so workers can actually see uploaded analysis files. This is required — without it, extraction/simulation can never succeed.
3. **`web-background` wasn't listening to the `analysis_wrappers` Resque queue** -> added `analysis_wrappers` to its `QUEUES` env var, so `InitializeAnalysis`/`FinalizeAnalysis` jobs (queue `:analysis_wrappers`) actually get processed instead of sitting forever.
4. **Missing `high-priority`/`low-priority` PriorityClasses** caused `rserve`/other pods to fail scheduling (`FailedCreate: no PriorityClass ... found`) after some cluster churn — recreated manually; there was also a real bug in the chart (`priority_low.yaml` name lookup) that's already fixed on this branch per commit `28aefcc "Fix low-priority PriorityClass lookup bug in Helm chart"`. Verify `openstudio-server/templates/priority-class/*.yaml` render correctly after reinstall (`helm template ... | grep -A5 PriorityClass`).
5. **Chart-managed `metrics-server`** conflicted with a pre-existing hand-applied `kube-system/metrics-server` (different Helm ownership) -> disabled via `metricsServer.enabled: false` in `openstack/values-openstack.yaml`, and `templates/metrics-server/metrics-server-deploy.yaml` now respects that flag (wrapped in `{{- if .Values.metricsServer.enabled }}`).
6. **`redis` deployment had `strategy.type: Recreate` combined with a `rollingUpdate` block** which is an invalid k8s spec combo and caused `helm upgrade` to fail with a validation error on that Deployment -> removed the invalid `strategy:` block from `templates/redis/redis-deploy.yaml`.
7. **Worker CPU request** is confirmed correct at `cpu: 1` (1000m) in `openstack/values-openstack.yaml` — do NOT lower this further (I incorrectly tried 100m/10m earlier while chasing a red herring; reverted). The real reason CPU showed near-0% was NOT the resource request — see root cause below.
8. **`worker-hpa`**: currently exists with `minReplicas: 2`, `maxReplicas: 10000`, `targetCPUUtilizationPercentage: 25` (`openstack/values-openstack.yaml` `worker_hpa:` block). This is correct and should come back automatically on `helm install` — no manual `kubectl apply` needed this time since it's now in the chart/values correctly (verify after install: `kubectl get hpa -n openstudio-server`).

**None of the above (1-8) are the reason simulations are stalling right now.** Those were real bugs, now fixed, and worth keeping. The remaining, NOT-yet-fixed root cause is below and is the main thing this handoff is for.

## Root cause still unresolved: ~4-5% of uploaded seed zips are silently corrupted at rest on NFS

### Evidence
- Workers were stuck in `write_lock_file exists, checking & waiting for receipt file` loops for 20+ minutes on a specific analysis (`578d3cc1-e8b1-4a87-9dfe-35c3e6729d66`), burning near-zero CPU (`sleep 3` polling loop is the actual reason CPU showed 0-1% — NOT a metrics/HPA bug).
- The original `write_lock_file` holder had died mid-extraction without writing `analysis_zip.receipt` (likely killed by one of our earlier pod deletions/scale-downs during troubleshooting) or the extraction genuinely failed.
- After deleting the stale lock and even after fully restarting the worker pods (to rule out client-side NFS attribute-cache staleness — which IS a real, separate contributing factor: each pod has its own NFS client cache and won't see a lock file deleted via a different pod's mount until it re-mounts/re-stats), a **fresh** re-extraction attempt failed with:
  ```
  Error in initialize_worker ... message Extraction of the analysis.zip file failed 3 times with error zlib error while inflating
  ```
- Ran `unzip -t` directly against the **original uploaded seed_zip** (Paperclip attachment, `/mnt/openstudio/server/assets/analyses/<analysis_id>/original/*.zip`) — confirmed **the corruption is present in the originally uploaded file itself**, not introduced later by extraction.
- Swept **all 615** uploaded seed zips from this run with `unzip -tq`: **25 are corrupt (~4.1%)**. List saved during the session (not persisted to disk — re-derive with the command below if needed, since the cluster will be uninstalled):
  ```bash
  kubectl exec <any-pod-with-nfs-mount> -n openstudio-server -- \
    bash -c 'for f in /mnt/openstudio/server/assets/analyses/*/original/*.zip; do
      unzip -tq "$f" >/dev/null 2>&1 || dirname "$(dirname "$f")" | xargs basename
    done'
  ```
- Corrupt uploads are spread evenly throughout the run (roughly one every 100-300 seconds), not clustered — meaning this is a **per-upload probabilistic bug**, not a one-time event. **Expect it to recur at a similar rate on the next run** unless fixed.
- The `Analysis.seed_zip_error` validation (`server/app/models/analysis.rb:106`, called from `AnalysesController#upload` in `analyses_controller.rb` **before** `@analysis.seed_zip = params[:file]`) validates the **temp upload file** and is supposed to reject corrupt zips with a 422 at upload time (issue #841 fix). Since corrupt zips are ending up saved anyway, either:
  - (a) the validation is being bypassed/racing, or
  - (b) corruption happens **after** validation passes, during Paperclip's copy-to-final-NFS-path step.
- Circumstantial evidence pointing at (b): earlier in this session we saw repeated `web-background` log lines like:
  ```
  [paperclip] Link failed with Invalid cross-device link @ rb_file_s_link (...); copying link ...
  ```
  This shows Paperclip's `link`-then-fallback-to-`cp` behavior when source and destination are on different filesystems/devices (e.g. web app's local tmp dir vs. the NFS-backed asset path). We also observed the upload flow doing several **chained temp-file copies** before the final save:
  ```
  /tmp/RackMultipart...zip -> /tmp/<hash>...zip -> /tmp/<hash>...zip (x2-3 more hops) -> final NFS destination
  ```
  This multi-hop, non-atomic copy chain (particularly the cross-device fallback) is the leading hypothesis for where truncation/corruption is introduced — e.g. if a `cp`/`FileUtils.cp`-style copy is interrupted, races with something else touching the same temp path, or a file handle used for validation is read again after being partially consumed/rewound incorrectly.

### What to investigate / fix
1. **Reproduce reliably first.** Rather than reasoning further from logs, write a tight repro: submit a batch of ~50-100 sequential single-analysis uploads via the openstudio-analysis gem (or directly via `curl`/`Faraday` multipart POST to `/analyses/<id>/upload.json`) with a known-good local zip, then `unzip -t` every uploaded copy on the NFS server afterward. Confirm the failure rate matches (~4-5%) and try to narrow to a specific code path.
2. **Trace the actual Paperclip/Rails code path** for `POST /analyses/:id/upload.json` in `server/app/controllers/analyses_controller.rb#upload` and the `has_mongoid_attached_file :seed_zip` config in `server/app/models/analysis.rb:57-59`. Look specifically at:
   - Where/how the multipart upload temp file gets written by Rack/Rails (`config/initializers` for `tmpdir`, `Rails.application.config.paths["tmp"]`, etc.) — confirm whether it's on the same filesystem as the final Paperclip storage path (`APP_CONFIG['server_asset_path']`, which is NFS-backed via `/mnt/openstudio`). If tmp is local-disk and the final path is NFS, EVERY save goes through the cross-device fallback path — that's almost certainly the corruption vector.
   - Whether Paperclip is invoking any additional "styles"/processing on the zip (it shouldn't need to — `has_mongoid_attached_file :seed_zip` with no explicit `:styles` should just store `:original`) that could be causing the repeated copy chain we observed in logs. If there IS an unnecessary re-processing step, removing it eliminates the highest-risk code path.
   - Whether `validates_attachment_content_type` runs its content-type sniff by reading the file in a way that could leave the underlying IO in a bad state before the final copy happens.
3. **Most likely fix**: make the final write atomic and same-filesystem. Options, in order of preference:
   - Point Rails' `tmp` dir (or at least Paperclip's `use_timestamp`/temp path) at somewhere on the SAME nfs-pvc mount (e.g. `/mnt/openstudio/tmp`) so the final "copy" becomes an atomic `rename(2)` on the same filesystem instead of a cross-device `cp`. This is the cleanest fix and matches the pattern already used elsewhere in this codebase (see `run_simulate_data_point.rb`'s `download_tmp = "#{download_file}.#{Process.pid}.part"` + `FileUtils.mv` pattern, added specifically to fix a similar NFS corruption bug — issue #857). Apply the same `.part` + atomic-rename pattern to the seed_zip upload path if it isn't already using it.
   - Alternatively/in addition: after Paperclip saves the attachment, re-validate with `Analysis.seed_zip_error(analysis.seed_zip.path)` against the **final on-disk path** (not just the temp upload) and reject/retry if it now fails validation — this at least catches corruption at upload time with a clear error back to the client (which the gem already retries 3x on non-2xx), rather than silently corrupting and only failing much later during simulation.
4. Check `server/config/initializers/` and `config/environments/*.rb` for any `Rails.application.config.tmp_path` / `ENV['TMPDIR']` overrides, and check whether the container's `/tmp` is backed by the same volume as `/mnt/openstudio` (it is NOT by default in the current chart — `/tmp` is the container's ephemeral filesystem, `/mnt/openstudio` is the `nfs-pvc` mount — confirming the cross-device hypothesis structurally).
5. Once a fix is implemented and you've re-run the repro from step 1 with a 0% corruption rate over at least 100-200 uploads, proceed to the reinstall/resubmit steps below.

## Steps to complete

### 1. Fix the corruption bug (see root cause section above)
This is application code in `~/OpenStudio/OpenStudio-server` (NOT this Helm repo) — likely `server/app/controllers/analyses_controller.rb` and/or `server/app/models/analysis.rb` and/or a Rails config initializer for tmp paths. If the fix requires an application code change, you'll need to rebuild and push the `nrel/openstudio-server:3.10.0-179D-test` image to the registry referenced in `openstack/values-openstack.yaml` (`pulp-dev.hpc.nlr.gov/pulp-container-aurora-179d/nrel/openstudio-server:3.10.0-179D-test`) before the new image is picked up by the chart. Confirm with the user whether they want to rebuild the image or whether a config-only fix is preferred/sufficient.

### 2. Uninstall the current release
```bash
cd /Users/achapin/179D/openstudio-server-helm
./scripts/uninstall.sh
```
This uses the pre-delete hook (keeps NFS server up until clients unmount) and retries on known-retryable watch-stream errors on this cluster. Do NOT manually `kubectl delete deployment ...` first — see comments at the top of the script.

Verify it's fully gone:
```bash
kubectl get all,pvc,cm,secret,sa,role,rolebinding,job -n openstudio-server
```

### 3. Reinstall
```bash
cd /Users/achapin/179D/openstudio-server-helm
helm install openstudio-server ./openstudio-server -f openstack/values-openstack.yaml -n openstudio-server --create-namespace
```
Watch rollout:
```bash
kubectl get pods -n openstudio-server -w
```
Verify after all pods are `Running`:
- `kubectl get hpa -n openstudio-server` — should show `worker-hpa` with `minReplicas 2 / maxReplicas 10000 / target 25%` automatically (no manual re-creation needed if it's correctly defined in the chart now).
- `kubectl get pods -n openstudio-server -l app=worker -o jsonpath='{.items[0].spec.volumes}'` — confirm worker mounts `nfs-pvc`, not `emptyDir`.
- `kubectl exec -n openstudio-server <any-web-or-worker-pod> -- env | grep OS_SERVER_PROJECT_PATH` — should be `/mnt/openstudio` on web, web-background, AND worker.
- `kubectl get priorityclass` — confirm `high-priority` and `low-priority` exist without manual intervention.

### 4. Port-forward and resubmit from the gem repo
```bash
kubectl port-forward -n openstudio-server svc/web 61570:80 &
cd ~/179D/openstudio-bem-to-surrogate-gem
bundle exec rake execute_sequential
```

### 5. Monitor for the corruption bug and CPU utilization
While `execute_sequential` is running (or right after), spot-check upload integrity periodically rather than waiting until the end:
```bash
kubectl exec -n openstudio-server <any-pod-with-nfs-mount> -- \
  bash -c 'total=0; corrupt=0; for f in /mnt/openstudio/server/assets/analyses/*/original/*.zip; do total=$((total+1)); unzip -tq "$f" >/dev/null 2>&1 || corrupt=$((corrupt+1)); done; echo "Total: $total  Corrupt: $corrupt"'
```
If corruption count is 0 (or negligible/hardware-noise level) after a large batch, the fix worked. If it's still happening at a similar rate, the fix in step 1 didn't address the actual mechanism — revisit.

Also confirm workers are actually using CPU once jobs are flowing (should climb well above the 25% HPA target and trigger scale-up, matching the 90-95% utilization previously observed by the user before this session's troubleshooting):
```bash
kubectl top pods -n openstudio-server -l app=worker
kubectl get hpa -n openstudio-server -w
```

### 6. Clean up scratch files from this session (optional)
- `CHANGES.md` at repo root was a scratch summary file written during troubleshooting — review and delete or fold into a real doc/PR description before committing anything.
- Any stray priority-class/HPA objects manually `kubectl apply`'d earlier in this session are moot after the full uninstall/reinstall in steps 2-3.

## Known-good reference for comparison
`aws/values-aws.yaml` has the working AWS config (worker `cpu: 1`, etc.) — already consistent with what's in `openstack/values-openstack.yaml` now. Use it as a sanity check if anything looks off after reinstall.
