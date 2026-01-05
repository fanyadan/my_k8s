# A local kind K8S cluster for running distributed AI agent

This project runs a small distributed “news fetcher agent” on a local Kubernetes cluster created with **kind**.

This project is ONLY a practice demo.

Two MPIJobs are provided:

- `news-agent-hf` runs `news_agent_hf_toolcall.py` (Hugging Face `InferenceClient` + tool-calling / fallback formatting)
- `news-agent-langchain` runs `news_agent_langchain.py` (LangChain agent wrapper over Hugging Face Inference)

Both jobs:

- fetch live headlines from **NewsAPI**
- summarize headlines using **Hugging Face Inference Providers**
- run in **real MPI distributed mode** (5 ranks across 5 worker pods) using **Open MPI + mpi4py**

## Repository layout

- `kind-5nodes.yaml`: kind cluster config (1 control-plane + 4 workers)
- `k8s/namespace.yaml`: creates namespace `news-agent`
- `k8s/mpijob-hf.yaml`: MPIJob manifest for the HF tool-call agent
- `k8s/mpijob-langchain.yaml`: MPIJob manifest for the LangChain agent
- `k8s/secret.yaml` / `k8s/secret.template.yaml`: placeholder secret template (do **not** apply with `REPLACE_ME`)
- `news-agent-image/`: Docker build context for the runtime image (`news-agent-mpi:local`)
- `scripts/bootstrap_kind_mpi_cluster.zsh`: one-command cluster bootstrap (kind + mpi-operator + RBAC patch)
- `scripts/run_news_agent_mpijobs.zsh`: sync code + build/load image + sync secrets + (re)run MPIJobs

## Prerequisites

You need these tools available on your machine:

- Docker Desktop / Docker daemon
- `kubectl`
- `kind`
- `helm`

Sanity check:

```bash
docker --version
kubectl version --client --short
kind version
helm version
```

### Base image dependency

`news-agent-image/Dockerfile` builds from `slurm-local:dev`:

```Dockerfile
FROM slurm-local:dev
```

Make sure `slurm-local:dev` exists locally:

```bash
docker image inspect slurm-local:dev >/dev/null && echo "slurm-local:dev is present"
```

## Secrets / tokens

The Python scripts require:

- `NEWS_API_KEY` (NewsAPI)
- `HF_TOKEN` (Hugging Face token with Inference Providers permission)

**Pods cannot read your Mac’s `~/.zshrc`.** This repo’s workflow is:

1) you export tokens in `~/.zshrc`
2) the helper script reads them locally and upserts a Kubernetes Secret (`news-agent-secrets`)
3) MPIJob pods read the Secret via `secretKeyRef`

Add these to `~/.zshrc`:

```bash
export NEWS_API_KEY="..."
export HF_TOKEN="..."
```

Reload:

```bash
source ~/.zshrc
```

Important:

- `k8s/secret.yaml` contains `REPLACE_ME`. **Do not apply it** unless you have replaced those values.
- Prefer using `scripts/run_news_agent_mpijobs.zsh` which safely creates/updates the Secret from your local env.

## 1) Bootstrap the cluster (one command)

This will:

- create (or reuse) a kind cluster (default name `mpi`)
- install `mpi-operator` via Helm
- patch RBAC so `mpi-operator` can update Roles/RoleBindings (required for reliable reconciliation)

```bash
./scripts/bootstrap_kind_mpi_cluster.zsh
```

If you want a clean slate:

```bash
./scripts/bootstrap_kind_mpi_cluster.zsh --recreate
```

Verify:

```bash
kubectl config use-context kind-mpi
kubectl get nodes -o wide
kubectl -n mpi-operator get pods -o wide
```

## 2) Run the news fetcher agent (one command)

This will:

- sync your latest Python sources from `../my_agent/` into `news-agent-image/app/`
  - all `*.py` files are synced recursively (so refactors into modules keep working)
- build the runtime image: `news-agent-mpi:local`
- load the image into the kind cluster (`kind load docker-image`)
- upsert `Secret/news-agent-secrets` from your local `~/.zshrc` env
- delete+recreate the MPIJobs so they actually re-run

```bash
./scripts/run_news_agent_mpijobs.zsh --rerun
```

Flags:

- `--no-sync`: don’t copy code from `../my_agent/`
- `--no-image`: don’t rebuild/load the Docker image

## 3) Monitor

### Job / pod status

```bash
kubectl -n news-agent get mpijob
kubectl -n news-agent get pods -o wide
```

Live watch:

```bash
kubectl -n news-agent get mpijob -w
# or
kubectl -n news-agent get pods -w
```

### See the actual “result” (headlines + summaries)

The combined output is printed by `mpirun` in the **launcher** pod logs:

```bash
kubectl -n news-agent logs -f pod/news-agent-hf-launcher -c launcher --tail=200
kubectl -n news-agent logs -f pod/news-agent-langchain-launcher -c launcher --tail=200
```

Save logs:

```bash
kubectl -n news-agent logs pod/news-agent-hf-launcher -c launcher --timestamps | tee hf.launcher.log
kubectl -n news-agent logs pod/news-agent-langchain-launcher -c launcher --timestamps | tee langchain.launcher.log
```

### Confirm it ran distributed (MPI across multiple pods)

Both scripts run an MPI sanity check when `NEWS_AGENT_MPI_CHECK=1`.
You should see `world_size=5` and hostnames spread across worker pods:

```bash
kubectl -n news-agent logs pod/news-agent-hf-launcher -c launcher | grep '\[mpi-check'
kubectl -n news-agent logs pod/news-agent-langchain-launcher -c launcher | grep '\[mpi-check'
```

### What “one rank per pod” means here

- 1 launcher pod runs `mpirun.openmpi`
- 5 worker pods exist (`worker-0..4`)
- with `slotsPerWorker: 1` and `mpirun ... -np 5`, Open MPI places **one MPI rank (one Python process)** on each worker pod

Worker pods run `sshd` (so they typically stay `Running` even after the launcher completes). This is intentional when `cleanPodPolicy: Running` so you can inspect/debug.

## Changing behavior

### Change worker count / ranks

Edit these together:

- `k8s/mpijob-*.yaml`: `Worker.replicas`
- launcher args: `mpirun ... -np <N>`

They should match.

### Change model/provider

Edit env vars in `k8s/mpijob-*.yaml`:

- `HF_PROVIDER` (default `novita`)
- `HF_MODEL` (default `zai-org/GLM-4.6`)

### Change the “what to fetch” (country/category/limit)

Currently the scripts’ `__main__` section runs:

- `country="us"`
- `category="technology"`
- `limit=10`

Update `../my_agent/news_agent_hf_toolcall.py` and/or `../my_agent/news_agent_langchain.py`, then rerun:

```bash
./scripts/run_news_agent_mpijobs.zsh --rerun
```

## Troubleshooting

### MPIJob says Succeeded but output looks wrong

The scripts may print an error string but still exit 0 in some cases (e.g. missing token, API error).
Always check launcher logs for the actual output.

### Operator / RBAC issues

If pods aren’t created or MPIJobs get stuck, check operator logs:

```bash
kubectl -n mpi-operator logs deploy/mpi-operator --tail=200
```

If you see errors like “forbidden … cannot update resource roles …”, re-run:

```bash
./scripts/bootstrap_kind_mpi_cluster.zsh
```

### Events

```bash
kubectl -n news-agent get events --sort-by=.metadata.creationTimestamp | tail -n 50
```

## Cleanup

Delete the MPIJobs (and their pods):

```bash
kubectl -n news-agent delete mpijob news-agent-hf news-agent-langchain
```

Delete the namespace:

```bash
kubectl delete namespace news-agent
```

Delete the entire kind cluster:

```bash
kind delete cluster --name mpi
```
