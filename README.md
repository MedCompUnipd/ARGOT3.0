# ARGOT3 — Quick Start

ARGOT3 annotates protein sequences with Gene Ontology terms using a classic sequence-similarity pipeline, a deep learning pipeline, or both combined.

For full documentation see [HERE](DOCUMENTATION.md).

---

## 1. Download and unpack the resource bundle

Download the resource bundle from [Zenodo (DOI: 10.5281/zenodo.21820416)](https://doi.org/10.5281/zenodo.21820416), then unpack it into the desired parent directory:

```
tar --zstd -xvf argot3_resource_bundle.zst -C /path/to/destination
```

This creates `/path/to/destination/argot3_resource_bundle`, which occupies approximately **236 GB** after extraction. Ensure that the destination filesystem has sufficient free space in addition to the downloaded archive itself.

> **Compatibility:** This command requires a version of `tar` with Zstandard support and the `zstd` executable. If `tar` does not recognize `--zstd`, install or update these tools before extracting the archive.

---

## 2. Get the container image

**Pre-built (recommended)** — pull directly from the GitHub Container Registry ([package page](https://github.com/MedCompUnipd/ARGOT3/pkgs/container/argot3)):

```
# Docker
docker pull ghcr.io/medcompunipd/argot3:latest
docker tag ghcr.io/medcompunipd/argot3:latest argot3

# Singularity
singularity build argot3.sif docker://ghcr.io/medcompunipd/argot3:latest
```

> **Note:** Building the Singularity image may require several tens of GB of temporary disk space. Set `SINGULARITY_TMPDIR` and `SINGULARITY_CACHEDIR` to change default directories if needed.

**Build locally** — from the repository source:

```
# Docker
docker build -t argot3 .

# Singularity (requires Docker image built above)
singularity build argot3.sif docker-daemon://argot3:latest
```

---

## 3. Build the DIAMOND index

The resource archive contains `uniprot_with_go.fasta`, but not the DIAMOND index. Build it once, directly inside the unpacked resource directory. If DIAMOND is installed locally, run:

```
cd /path/to/argot3_resource_bundle
diamond makedb --in uniprot_with_go.fasta --db uniprot_with_go --threads "$(nproc)"
```

Alternatively, use the DIAMOND executable included in the ARGOT3 container:

```
# Docker
docker run --rm \
    --entrypoint /app/bin/diamond \
    -v /path/to/argot3_resource_bundle:/data \
    argot3 \
    makedb --in /data/uniprot_with_go.fasta --db /data/uniprot_with_go --threads "$(nproc)"

# Singularity
singularity exec \
    --bind /path/to/argot3_resource_bundle:/data \
    argot3.sif \
    diamond makedb --in /data/uniprot_with_go.fasta --db /data/uniprot_with_go --threads "$(nproc)"
```

This creates `/path/to/argot3_resource_bundle/uniprot_with_go.dmnd`, which is passed to the pipeline with `-d`.

`$(nproc)` uses all CPUs available to the process. Replace it with a fixed value such as `8`, or omit `--threads`, if preferred.

---

## 4. Start MongoDB

The script auto-detects Docker or Singularity. Use `-r docker` or `-r singularity` to override. The database name loaded from the dump is `ARGOT_DB` — use this value for `--mongo-db` when running the pipeline. The container or Singularity instance is named `argot-mongodb` — use this name with `docker` or `singularity` commands, or choose a different one with `-n`.

```
./run_mongodb.sh -f /path/to/argot3_resource_bundle/dump/
```

> **Warning:** The database dump is large. Restoring it requires ~100 GB of free disk space. Persistent data is stored in `$HOME/mongo_data` by default — make sure that filesystem has enough space, or specify a different location with `-d`.

Common options:

```
# Custom runtime, data directory and port
./run_mongodb.sh \
    -r singularity \
    -d /scratch/mongo_data \
    -p 27018 \
    -f /path/to/argot3_resource_bundle/dump/
```

MongoDB runs on port `27017` by default. If you change it with `-p`, pass the same port to the pipeline with `--mongo-port`.

Docker and Singularity both expose this MongoDB instance on all network interfaces, allowing jobs on another node to connect. The instance does not enable authentication, so access must be restricted through the cluster network or firewall.

MongoDB keeps running after the script exits and after the session is closed. On a cluster, run it on a node or allocation where long-running services are permitted; a scheduler may terminate it when the allocation ends. If the service stops, restart it with the same runtime, instance name, port, data directory, and other custom options, but omit `-f` to reuse the existing database without repeating the restore. See [Service lifetime and recovery](DOCUMENTATION.md#service-lifetime-and-recovery) for details.

If ARGOT3 runs on a different node from MongoDB, replace `localhost` in the pipeline command with the hostname or IP address of the node running MongoDB.

---

## 5. Run the pipeline

Three volume mounts are required:

| Mount | Purpose |
|-------|---------|
| `/path/to/argot3_resource_bundle` → `/data` | Resource bundle |
| `/path/to/proteins.fasta` → `/input/proteins.fasta` | Input FASTA |
| `/path/to/output` → `/output` | Output directory |

The `-o` argument must point to a **non-existing subdirectory** inside the output mount (e.g. `/output/run1`). The pipeline creates it.

ARGOT3 accepts complete UTF-8 FASTA headers and preserves them in user-facing prediction TSVs without the leading `>`. Descriptions, pipes, non-ASCII characters, and other header content are retained. Embedded tabs are converted to spaces so they do not create additional TSV columns.

> **Singularity users:** commands below are identical — apply these substitutions:
>
> | Docker | Singularity |
> |--------|-------------|
> | `docker run` | `singularity run` |
> | `--gpus all` | `--nv` *(omit if no GPU)* |
> | `--network host` | *(omit — host network is default)* |
> | `-v src:dst` | `--bind src:dst` |
> | `-e VAR=val` | `--env VAR=val` |
> | `argot3` | `argot3.sif` |

### Run everything (both pipelines + merge)

```
docker run --gpus all --network host \
    -v /path/to/argot3_resource_bundle:/data \
    -v /path/to/proteins.fasta:/input/proteins.fasta \
    -v /path/to/output:/output \
    -e TORCH_HOME=/data/embeddings \
    argot3 \
    --mode all \
    --exec parallel \
    -f /input/proteins.fasta \
    -o /output/run1 \
    -g /data/go.owl \
    -d /data/uniprot_with_go.dmnd \
    -t 8 \
    --mongo-host localhost \
    --mongo-db ARGOT_DB \
    -s /data/structure \
    -w /data/weights
```

- `TORCH_HOME=/data/embeddings` points to the pre-downloaded ESM2 weights (avoids a ~2.5 GB download at runtime)
- `--exec parallel` runs both pipelines simultaneously; omit it (or use `--exec sequential`) to run them one after the other, which uses less memory

### Classic model only

```
docker run --network host \
    -v /path/to/argot3_resource_bundle:/data \
    -v /path/to/proteins.fasta:/input/proteins.fasta \
    -v /path/to/output:/output \
    argot3 \
    --mode classic \
    -f /input/proteins.fasta \
    -o /output/run1 \
    -g /data/go.owl \
    -d /data/uniprot_with_go.dmnd \
    -t 8 \
    --mongo-host localhost \
    --mongo-db ARGOT_DB
```

### New model only

```
docker run --gpus all \
    -v /path/to/argot3_resource_bundle:/data \
    -v /path/to/proteins.fasta:/input/proteins.fasta \
    -v /path/to/output:/output \
    -e TORCH_HOME=/data/embeddings \
    argot3 \
    --mode new \
    -f /input/proteins.fasta \
    -o /output/run1 \
    -g /data/go.owl \
    -s /data/structure \
    -w /data/weights
```

### Run both pipelines without merging

Use `--mode both` with the same arguments as `--mode all` — it runs both pipelines without the final merge. Results can be merged later with `--mode merge`.

### Merge existing outputs

Use this to merge results from a previous `--mode classic` and `--mode new` run, pointing `-o` to the same run directory. **The output directory must contain results from both models** (i.e. it must have been produced by prior `--mode classic` and `--mode new` runs with the same `-o` path).

```
docker run \
    -v /path/to/argot3_resource_bundle:/data \
    -v /path/to/output:/output \
    argot3 \
    --mode merge \
    -o /output/run1 \
    -g /data/go.owl
```

To apply taxonomic constraints, append these flags. `--species` is the NCBI taxonomy ID of the target organism (e.g. `9606` for human):

```
    --species 9606 \
    -T /data/taxonomy \
    -C /data/constraints
```
