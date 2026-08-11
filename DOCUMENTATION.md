# ARGOT3

ARGOT3 is a containerized pipeline for protein function annotation using Gene Ontology (GO) terms. It supports two annotation strategies that can be run independently or together, with an optional merging step to combine their outputs:

- **Classic model**: sequence similarity-based annotation using DIAMOND, MongoDB-backed GO annotations, and the scoring engine
- **New model**: deep learning-based annotation using ESM2 protein embeddings and trained neural network weights
- **Merging**: combines predictions from both models, with optional taxonomic constraint filtering

---

## Resource Bundle

Download the resource bundle from [Zenodo (DOI: 10.5281/zenodo.21820416)](https://doi.org/10.5281/zenodo.21820416), then extract it into the desired parent directory:

```
tar --zstd -xvf argot3_resource_bundle.zst -C /path/to/destination
```

This creates `/path/to/destination/argot3_resource_bundle`, which occupies approximately **236 GB** after extraction. Ensure that the destination filesystem has sufficient free space in addition to the downloaded archive itself.

The extraction command requires a version of `tar` with Zstandard support and the `zstd` executable. If `tar` does not recognize `--zstd`, install or update these tools before extracting the archive.

---

## Repository Structure

```
ARGOT3/
├── Dockerfile                  # Container definition (NVIDIA TF base + dependencies)
├── entrypoint.sh               # Main pipeline entry point
├── run_mongodb.sh              # Host-side MongoDB setup script (Docker or Singularity)
├── bin/
│   ├── diamond                 # DIAMOND binary
│   └── Argot3-1.0.jar          # ARGOT3 Java engine (pre-built)
└── src/
    ├── run_classic_model.sh    # Classic pipeline runner
    ├── run_new_model.sh        # New model pipeline runner
    ├── run_merging.sh          # Merging pipeline runner
    ├── classic_model/          # Python scripts for the classic pipeline
    ├── new_model/              # Python scripts for the new model pipeline
    ├── merging/                # Python scripts for the merging pipeline
    └── java/argot3/            # ARGOT3 Java source code (see src/java/argot3/README.md)
```

---

## Requirements

Modes that process a FASTA file (`classic`, `new`, `both`, and `all`) use three separate mount points:

| Mount | Purpose |
|-------|---------|
| `-v /path/to/argot3_resource_bundle:/data` | Resource bundle (databases, weights, embeddings) |
| `-v /path/to/proteins.fasta:/input/proteins.fasta` | Input FASTA file |
| `-v /path/to/output:/output` | Output directory |

The `merge` mode uses only the resource and output mounts because it reads predictions from an existing run directory.

The resource bundle directory should be structured as follows:

```
argot3_resource_bundle/
├── go.owl                      # Gene Ontology file (OWL format)
├── uniprot_with_go.fasta       # DIAMOND source FASTA                [classic model]
├── uniprot_with_go.dmnd        # Generated locally with `makedb`     [classic model]
├── dump/                       # MongoDB dump directory               [classic model]
│   └── ARGOT_DB/
│       ├── annots.bson
│       ├── annots.metadata.json
│       ├── goa.bson
│       ├── goa.metadata.json
│       ├── goafreq.bson
│       ├── goafreq.metadata.json
│       ├── uniprot_with_go.bson
│       └── uniprot_with_go.metadata.json
├── structure/                  # GO terms (BPO, CCO, MFO) files       [new model]
├── weights/                    # Pre-trained model weights            [new model]
├── embeddings/                 # ESM2 model weights cache             [new model]
│   └── hub/
│       └── checkpoints/
│           ├── esm2_t33_650M_UR50D.pt
│           └── esm2_t33_650M_UR50D-contact-regression.pt
├── taxonomy/                   # NCBI taxonomy files                  [merging, optional]
└── constraints/                # GO taxonomic constraints             [merging, optional]
```

The Zenodo resource archive contains `uniprot_with_go.fasta`; `uniprot_with_go.dmnd` is generated locally after unpacking the archive. See **Build the DIAMOND index** below.

The `embeddings/` directory holds the pre-downloaded ESM2 model weights used by `fair-esm` at runtime. Without it, the pipeline will attempt to download ~2.5 GB at runtime. Pass it to the container via `TORCH_HOME` (see examples below).

The `taxonomy/` and `constraints/` directories are only required when running the merging step with taxonomic constraint filtering (`--species`).

---

## Build the DIAMOND index

The DIAMOND database is intentionally not included in the resource archive and must be generated locally for modes that include the classic model (`classic`, `both`, and `all`). Build it once after unpacking the archive. It is not required for `new` or `merge`.

The resource directory must be writable because `diamond makedb` creates `uniprot_with_go.dmnd` alongside the source FASTA.

If DIAMOND is installed locally, run:

```
cd /path/to/argot3_resource_bundle
diamond makedb --in uniprot_with_go.fasta --db uniprot_with_go --threads "$(nproc)"
```

Alternatively, use the DIAMOND executable included in the ARGOT3 container.

**Docker**

```
docker run --rm \
    --entrypoint /app/bin/diamond \
    -v /path/to/argot3_resource_bundle:/data \
    argot3 \
    makedb --in /data/uniprot_with_go.fasta --db /data/uniprot_with_go --threads "$(nproc)"
```

**Singularity**

```
singularity exec \
    --bind /path/to/argot3_resource_bundle:/data \
    argot3.sif \
    diamond makedb --in /data/uniprot_with_go.fasta --db /data/uniprot_with_go --threads "$(nproc)"
```

Verify that the index was created:

```
ls -lh /path/to/argot3_resource_bundle/uniprot_with_go.dmnd
```

Pass this generated file to ARGOT3 as `-d /data/uniprot_with_go.dmnd`.

`$(nproc)` uses all CPUs available to the process. Replace it with a fixed value such as `8`, or omit `--threads`, if preferred.

---

## MongoDB Setup

MongoDB must be running for modes that include the classic model (`classic`, `both`, and `all`). It is not required for `new` or `merge`. Use `run_mongodb.sh` to start a MongoDB instance and optionally restore a dump directory. The database name loaded from the dump is `ARGOT_DB` (fixed by the dump contents) and the container or Singularity instance is named `argot-mongodb` (changeable with `-n`). The examples below use both names.

Docker and Singularity both expose this MongoDB instance on all network interfaces, allowing jobs on another node to connect. The instance does not enable authentication, so access must be restricted through the cluster network or firewall.

> **Note:** `run_mongodb.sh` is a host-side script and is not part of the Docker container.

### Usage

```
./run_mongodb.sh [options]

Options:
  -r <runtime>    Container runtime: docker | singularity (default: auto-detect)
  -n <name>       Container/instance name (default: argot-mongodb)
  -p <port>       MongoDB port (default: 27017)
  -d <data_dir>   Host directory for persistent data (default: $HOME/mongo_data)
  -f <dump_dir>   Path to dump directory to restore (optional)
  -I <image>      MongoDB image name (default: mongo:8)
  -i <sif>        Singularity SIF image (optional, default: docker://<image>)
  -w <workers>    Total insertion workers budget for mongorestore (split across collections)
                  (default: max available, capped at 16 workers per collection)
  -c <cols>       Number of parallel collections for mongorestore (default: 3)
  --force         Remove existing data directory before starting
  -h              Show this help message and exit
```

> **Warning:** The ARGOT3 database dump is large. Restoring it requires approximately **100 GB of free disk space** in the persistent data directory (`-d`). Make sure the target filesystem has sufficient space before running with `-f`.

### Examples
Start MongoDB (auto-detected) and restore a dump:
```
./run_mongodb.sh -f /path/to/argot3_resource_bundle/dump/
```

Use a custom port and container name:
```
./run_mongodb.sh -n my-mongo -p 27018 -f /path/to/argot3_resource_bundle/dump/
```

#### Use Singularity on HPC with a pre-built SIF

For HPC environments without Docker, use `run_mongodb.sh` with `-r singularity` (the software auto-detects Singularity if Docker is missing). It is recommended to provide a pre-built SIF image to avoid pulling from Docker Hub on compute nodes:

```
singularity build mongo.sif docker://mongo:8
```

```
./run_mongodb.sh -r singularity -i /path/to/mongo.sif -f /path/to/argot3_resource_bundle/dump/
```

> **Note:** The dump directory must be in `mongodump` directory format (created with `mongodump --out <dir>`).

### Re-running with a dump on an existing container

Volume mounts are set at container creation time and cannot be changed on a running or stopped container. If a MongoDB container or Singularity instance already exists (created without `-f`) and you later want to restore a dump into it, the dump directory will not be mounted and `mongorestore` will fail.

In this case, remove the existing container/instance first:

```
# Docker
docker rm -f argot-mongodb

# Singularity
singularity instance stop argot-mongodb
```

Then re-run `run_mongodb.sh` with `-f`:

```
./run_mongodb.sh -f /path/to/argot3_resource_bundle/dump/
```

> **Note:** `--force` only removes the persistent **data directory** (`~/mongo_data` by default), not the container itself. To reset everything, remove both the container and the data directory.

### Service lifetime and recovery

`run_mongodb.sh` starts MongoDB in the background and returns. The service keeps running after the script exits and after the terminal or SSH session is closed. It is not tied to the shell that started it.

It does **not** come back automatically after a reboot or Docker daemon restart. A cluster scheduler may also terminate it when the allocation ends. Run MongoDB only on a node or allocation where long-running services are permitted, following the policies of the local HPC system.

Stopping the service does not remove its host data directory (`-d`, default `$HOME/mongo_data`), although persistence still depends on the selected filesystem. To bring the service back up, re-run the script with the same runtime, instance name, port, data directory, and other custom options, but omit `-f`. For example, if the defaults were used:

```
./run_mongodb.sh
```

This reuses the existing data directory and skips the restore entirely (`No dump provided, skipping restore`). If custom options such as `-r`, `-n`, `-p`, `-d`, or `-i` were used originally, provide the same values when restarting. Only pass `-f` again when the database genuinely needs to be reloaded from the dump, since that repeats the full ~100 GB restore.

> **Singularity:** the instance and the `mongod` process inside it have separate lifetimes. If `singularity instance list` shows `argot-mongodb` but connections are refused, the instance outlived its `mongod`. Re-running the script will report `Instance 'argot-mongodb' already running` and then fail while waiting for MongoDB. Stop the instance and start again:
>
> ```
> singularity instance stop argot-mongodb
> ./run_mongodb.sh
> ```

### Connecting ARGOT3 to MongoDB

The classic model pipeline connects to MongoDB at runtime using the `--mongo-host`, `--mongo-port`, and `--mongo-db` flags passed to `entrypoint.sh`.

**Docker**

MongoDB runs on the host (via `run_mongodb.sh`) and the ARGOT3 container connects to it over the host network. Use `--network host` so that `localhost` inside the container resolves to the host:

```
docker run --network host \
    ... \
    argot3 --mode classic \
    --mongo-host localhost \
    --mongo-db ARGOT_DB \
    ...
```

Without `--network host`, `localhost` inside the container refers to the container itself, not the host, and the connection will fail.

**Singularity**

Singularity containers share the host network by default, so `--mongo-host localhost` works without any extra flags:

```
singularity run ... argot3.sif --mode classic \
    --mongo-host localhost \
    --mongo-db ARGOT_DB \
    ...
```

If ARGOT3 runs on a different node from MongoDB, set `--mongo-host` to the hostname or IP address of the node running MongoDB instead of `localhost`. Use the port selected with `run_mongodb.sh -p` as `--mongo-port`.

---

## ARGOT3 JAR

The Java source code for the ARGOT3 scoring engine is in `src/java/argot3/`. A pre-built JAR is already provided at `bin/Argot3-1.0.jar` and is used by the pipeline, so rebuilding is only needed if you modify the Java source.

See [`src/java/argot3/README.md`](src/java/argot3/README.md) for the required external libraries and Maven build instructions. The rebuilt JAR is created at `src/java/argot3/target/Argot3-1.0.jar`; replace `bin/Argot3-1.0.jar` only if you want the pipeline to use the rebuilt engine.

---

## Container Image

Pre-built images are available on the GitHub Container Registry ([package page](https://github.com/MedCompUnipd/ARGOT3/pkgs/container/argot3)):

```
# Docker
docker pull ghcr.io/medcompunipd/argot3:latest
docker tag ghcr.io/medcompunipd/argot3:latest argot3

# Singularity
singularity build argot3.sif docker://ghcr.io/medcompunipd/argot3:latest
```

> **Note:** Building the Singularity image may require several tens of GB of temporary disk space. Set `SINGULARITY_TMPDIR` and `SINGULARITY_CACHEDIR` to change default directories if needed.

To build locally from source:

```
docker build -t argot3 .
```

The image is based on `nvcr.io/nvidia/tensorflow:24.01-tf2-py3` and includes:
- Java 17 (for Argot3.jar)
- PyTorch with CUDA 12.1 support
- Python packages: `pymongo`, `owlready2`, `fair-esm`, `biopython`, `networkx`, and others

---

## Pipeline Usage

The main entry point is `entrypoint.sh`, which is set as the Docker `ENTRYPOINT`.

### Arguments

```
docker run [docker options] argot3 --mode <classic|new|both|merge|all> [options]

Execution mode:
  --mode <mode>          classic   Run the DIAMOND + ARGOT3 pipeline
                         new       Run the deep learning-based pipeline
                         both      Run both pipelines
                         merge     Merge existing classic and new outputs
                         all       Run both pipelines then merge

  --exec <mode>          Execution strategy when --mode=both or --mode=all:
                         sequential (default)   Run classic then new
                         parallel               Run classic and new in parallel

Shared arguments:
  -f <fasta>             Input protein FASTA file (not required for --mode merge)
  -o <outdir>            Output directory
  -g <go.owl>            Gene Ontology file (OWL format)

Classic model arguments:
  -d <db>                DIAMOND database (prefix or .dmnd file)
  -t <threads>           Number of threads for DIAMOND (default: 1)
  --mongo-db <name>      MongoDB database name
  --mongo-host <host>    MongoDB host (default: localhost)
  --mongo-port <port>    MongoDB port (default: 27017)

  Note: classic mode requires --network host (Docker) so the container
  can reach MongoDB running on the host (see MongoDB Setup section).

New model arguments:
  -s <dir>               Structure directory (GO terms files)
  -w <dir>               Weights directory

Merge arguments:
  --species <taxid>      NCBI taxon ID (enables taxonomic constraints) (default: no constraints)
  -T <dir>               Taxonomy directory (required with --species)
  -C <dir>               Constraints directory (required with --species)

Execution flags:
  --dry-run              Print commands without executing them
  --verbose              Print commands as they are executed
  --force                Overwrite existing output directory
  -h                     Show this help message and exit
```

### FASTA header handling

ARGOT3 accepts complete UTF-8 FASTA headers, including descriptions, pipes, non-ASCII characters, and other content that the bundled model scripts do not normally recognize. User-facing prediction TSVs contain the complete original header text without the leading `>`. The only normalization is that embedded tabs are converted to spaces so they do not create additional TSV columns.

Header restoration is automatic after a successful run. If a pipeline stage fails before that final step, the retained `fasta_header_mapping.tsv` support file can restore any completed prediction TSV manually. Run this recovery command only on prediction files that have not already been restored:

```
python3 src/container_tools/fasta_id_map.py restore \
    --mapping /path/to/run/fasta_header_mapping.tsv \
    /path/to/run/classic/predictions/unpropagated.tsv \
    /path/to/run/classic/predictions/propagated.tsv
```

Pass any other existing new-model or merged prediction TSVs as additional file arguments.

### Examples

All examples below use Docker. For Singularity, apply these substitutions:

| Docker | Singularity |
|--------|-------------|
| `docker run` | `singularity run` |
| `--gpus all` | `--nv` *(omit if no GPU)* |
| `--network host` | *(omit — host network is default)* |
| `-v src:dst` | `--bind src:dst` |
| `-e VAR=val` | `--env VAR=val` |
| `argot3` | `argot3.sif` |

For `classic`, `new`, `both`, and `all`, the `-o` argument should point to a **non-existing subdirectory** inside the output mount; the pipeline creates it. This supports keeping multiple runs under the same output volume (e.g. `/output/run1`, `/output/run2`, ...). For `merge`, point `-o` to an existing run directory produced by `--mode both`.

Run the classic model:
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

Run the new model:
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

Run both pipelines in parallel:
```
docker run --gpus all --network host \
    -v /path/to/argot3_resource_bundle:/data \
    -v /path/to/proteins.fasta:/input/proteins.fasta \
    -v /path/to/output:/output \
    -e TORCH_HOME=/data/embeddings \
    argot3 \
    --mode both \
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

Merge outputs from a previous `--mode both` run (point `-o` to the same existing run directory):
```
docker run \
    -v /path/to/argot3_resource_bundle:/data \
    -v /path/to/output:/output \
    argot3 \
    --mode merge \
    -o /output/run1 \
    -g /data/go.owl
```

Run all pipelines end-to-end with taxonomic constraints:
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
    -w /data/weights \
    --species 9606 \
    -T /data/taxonomy \
    -C /data/constraints
```

When running with `--exec parallel`, each pipeline writes its logs to `<outdir>/classic.log` and `<outdir>/new.log`.

---

## Output Structure

### Classic model (`--mode classic`)

```
<outdir>/classic/
├── input/
│   ├── proteins_list.fasta         # Validated input sequences
│   └── argot_in.txt                # ARGOT3 input file
├── output/
│   ├── diamond_raw.blastp          # Raw DIAMOND output
│   ├── diamond_clean.blastp        # Filtered DIAMOND output
│   ├── argot_out.txt               # ARGOT3 raw scores
│   ├── predictions_raw.tsv         # Unpropagated predictions
│   └── predictions_prop.tsv        # Propagated predictions
└── predictions/
    ├── unpropagated.tsv            # Final unpropagated output
    └── propagated.tsv              # Final propagated output
```

At the run-directory root, `fasta_header_mapping.tsv` is retained as a support file for preserving or recovering original FASTA headers. It is created for `classic`, `new`, `both`, and `all` modes.

### New model (`--mode new`)

```
<outdir>/new/
├── data/
│   ├── proteins_list.fasta         # Validated input sequences
│   ├── proteins_list.txt           # Protein IDs
│   ├── embeddings/                 # Per-protein ESM2 embeddings (generated at runtime)
│   ├── cco_batch.txt               # Cellular Component predictions
│   ├── mfo_batch.txt               # Molecular Function predictions
│   ├── bpo_batch.txt               # Biological Process predictions
│   ├── prediction_raw.txt          # Joined unpropagated predictions
│   └── prediction_propagated.txt   # Propagated predictions
└── predictions/
    ├── unpropagated.tsv            # Final unpropagated output
    └── propagated.tsv              # Final propagated output
```

### Merging (`--mode merge` or `--mode all`)

Without taxonomic constraints:
```
<outdir>/merged/
├── unpropagated.tsv
├── propagated.tsv
└── final/
    ├── predictions_slim.tsv        # Slim GO terms only
    └── predictions_full.tsv        # Full GO annotation
```

With taxonomic constraints (`--species`):
```
<outdir>/merged/
├── unpropagated.tsv
├── propagated.tsv
├── unpropagated_filtered.tsv
├── propagated_filtered.tsv
└── final/
    ├── predictions_unfiltered_slim.tsv
    ├── predictions_unfiltered_full.tsv
    ├── predictions_filtered_slim.tsv
    └── predictions_filtered_full.tsv
```

When running `--mode both`, outputs are placed in `<outdir>/classic/` and `<outdir>/new/`. With `--mode all`, the merged output is additionally placed in `<outdir>/merged/`.
