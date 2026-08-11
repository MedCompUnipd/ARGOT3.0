#!/usr/bin/env bash

set -euo pipefail

# -----------------------------
# Error / warning
# -----------------------------
err() { echo "Error: $*" >&2; }
warn() { echo "Warning: $*" >&2; }

# -----------------------------
# Execution control
# -----------------------------
dry_run=0
verbose=0
force=0

run() {
    if [[ "$dry_run" -eq 1 ]]; then
        echo -n "[DRY-RUN] "
        printf '%q ' "$@"
        echo
    else
        if [[ "$verbose" -eq 1 ]]; then
            echo -n "[RUN] "
            printf '%q ' "$@"
            echo
        fi
        "$@"
    fi
}

cleanup_fasta_mapping() {
    if [[ -n "${normalized_fasta:-}" ]]; then
        rm -f -- "$normalized_fasta"
    fi
    if [[ "${mapping_ready:-0}" -ne 1 && -n "${header_mapping:-}" ]]; then
        rm -f -- "$header_mapping"
    fi
}

# -----------------------------
# Defaults
# -----------------------------
mode=""
exec_mode="sequential"

# shared
fasta=""
outdir=""
go_owl=""

# classic
diamond_db=""
threads=1
mongo_host="localhost"
mongo_port=27017
mongo_db=""

# new
structure_dir=""
weights_dir=""

# merge
species=0
taxonomy_dir=""
constraints_dir=""

# scripts
script_classic="/app/src/run_classic_model.sh"
script_new="/app/src/run_new_model.sh"
script_merging="/app/src/run_merging.sh"
fasta_mapping_tool="/app/src/container_tools/fasta_id_map.py"

# -----------------------------
# Usage
# -----------------------------
usage() {
    echo "ARGOT3"
    echo
    echo "Run the ARGOT3 classic model, the new deep learning-based model, or merge their outputs."
    echo "MongoDB is expected to be running externally (e.g. via Docker Compose)."
    echo
    echo "Usage:"
    echo "  $0 --mode <classic|new|both|merge|all> [options]"
    echo
    echo "Execution mode:"
    echo "  --mode <mode>          Select pipeline to run:"
    echo "                         classic   Run the DIAMOND + ARGOT3 pipeline"
    echo "                         new       Run the deep learning-based pipeline"
    echo "                         both      Run both pipelines"
    echo "                         merge     Merge existing classic and new outputs"
    echo "                         all       Run both pipelines then merge"
    echo
    echo "  --exec <mode>          Execution strategy when --mode=both or --mode=all:"
    echo "                         sequential (default)   Run classic then new"
    echo "                         parallel               Run classic and new in parallel"
    echo
    echo "Shared arguments:"
    echo "  -f <fasta>             Input protein FASTA file (not required for --mode merge)"
    echo "  -o <outdir>            Output directory. Creates:"
    echo "                                              - <outdir>/classic"
    echo "                                              - <outdir>/new"
    echo "                                              - <outdir>/merged (when enabled)"
    echo "  -g <go.owl>            Gene Ontology file (OWL format)"
    echo
    echo "Classic model arguments:"
    echo "  -d <db>                DIAMOND database (prefix or .dmnd file)"
    echo "  -t <threads>           Number of threads for DIAMOND (default: 1)"
    echo "  --mongo-db <name>      MongoDB database name (e.g. ARGOT_DB)"
    echo "  --mongo-host <host>    MongoDB host (default: localhost)"
    echo "  --mongo-port <port>    MongoDB port (default: 27017)"
    echo
    echo "New model arguments:"
    echo "  -s <dir>               Structure directory"
    echo "  -w <dir>               Weights directory"
    echo
    echo "Merge arguments:"
    echo "  --species <taxid>      NCBI taxon ID (enables taxonomic constraints) (default: no constraints)"
    echo "  -T <dir>               Taxonomy directory (required with --species)"
    echo "  -C <dir>               Constraints directory (required with --species)"
    echo
    echo "Execution flags:"
    echo "      --dry-run          Print commands without executing them"
    echo "      --verbose          Print commands as they are executed"
    echo "      --force            Overwrite existing output directory"
    echo "  -h                     Show this help message and exit"
    echo
    exit 1
}

# -----------------------------
# Parse args
# -----------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) mode=$2; shift 2 ;;
        --exec) exec_mode=$2; shift 2 ;;

        -f) fasta=$2; shift 2 ;;
        -o) outdir=$2; shift 2 ;;
        -g) go_owl=$2; shift 2 ;;

        -d) diamond_db=$2; shift 2 ;;
        -t) threads=$2; shift 2 ;;
        --mongo-db) mongo_db=$2; shift 2 ;;
        --mongo-host) mongo_host=$2; shift 2 ;;
        --mongo-port) mongo_port=$2; shift 2 ;;

        -s) structure_dir=$2; shift 2 ;;
        -w) weights_dir=$2; shift 2 ;;

        --species) species=$2; shift 2 ;;  # overrides default 0
        -T) taxonomy_dir=$2; shift 2 ;;
        -C) constraints_dir=$2; shift 2 ;;

        --dry-run) dry_run=1; shift ;;
        --verbose) verbose=1; shift ;;
        --force) force=1; shift ;;
        -h) usage ;;

        *) err "unknown argument '$1'"; usage ;;
    esac
done

# -----------------------------
# Validation
# -----------------------------
missing=0
[[ -z "$mode" ]]   && { err "missing required argument --mode <classic|new|both|merge|all>"; missing=1; }
[[ "$mode" != "merge" ]] && [[ -z "$fasta" ]]  && { err "missing required argument -f <fasta>"; missing=1; }
[[ -z "$outdir" ]] && { err "missing required argument -o <outdir>"; missing=1; }
[[ -z "$go_owl" ]] && { err "missing required argument -g <go.owl>"; missing=1; }

[[ $missing -eq 1 ]] && { echo; usage; }

case "$mode" in
    classic|new|both|merge|all) ;;
    *) err "invalid value for --mode <classic|new|both|merge|all>"; exit 1 ;;
esac

case "$exec_mode" in
    sequential|parallel) ;;
    *) err "invalid value for --exec <sequential|parallel>"; exit 1 ;;
esac

if [[ "$mode" != "both" && "$mode" != "all" && "$exec_mode" != "sequential" ]]; then
    warn "--exec is ignored unless --mode both or --mode all"
fi

[[ "$mode" == "merge" ]] || { [[ -f "$fasta" ]] || { err "file not found '$fasta' (-f)"; exit 1; }; }
[[ -f "$go_owl" ]] || { err "file not found '$go_owl' (-g)"; exit 1; }

# Classic validation
if [[ "$mode" == "classic" || "$mode" == "both" || "$mode" == "all" ]]; then
    [[ -z "$diamond_db" ]] && { err "missing required argument -d <db>"; exit 1; }
    [[ -z "$mongo_db" ]]   && { err "missing required argument --mongo-db <name>"; exit 1; }

    if ! [[ "$threads" =~ ^[1-9][0-9]*$ ]]; then
        err "invalid value for -t <threads>, must be a positive integer (got '$threads')"
        exit 1
    fi

    if ! [[ "$mongo_port" =~ ^[0-9]+$ ]]; then
        err "invalid value for --mongo-port <port>, must be a positive integer (got '$mongo_port')"
        exit 1
    fi

    if [[ -f "$diamond_db" ]]; then
        :
    elif [[ -f "${diamond_db}.dmnd" ]]; then
        diamond_db="${diamond_db}.dmnd"
    else
        err "file not found '$diamond_db' (-d)"
        exit 1
    fi

    [[ -f "$script_classic" ]] || { err "file not found '$script_classic' (classic script)"; exit 1; }
fi

# New validation
if [[ "$mode" == "new" || "$mode" == "both" || "$mode" == "all" ]]; then
    [[ -z "$structure_dir" ]] && { err "missing required argument -s <dir>"; exit 1; }
    [[ -z "$weights_dir" ]]   && { err "missing required argument -w <dir>"; exit 1; }

    [[ -d "$structure_dir" ]] || { err "directory not found '$structure_dir' (-s)"; exit 1; }
    [[ -d "$weights_dir" ]]   || { err "directory not found '$weights_dir' (-w)"; exit 1; }

    [[ -f "$script_new" ]] || { err "file not found '$script_new' (new script)"; exit 1; }
fi

# Merge validation
if [[ "$mode" == "merge" || "$mode" == "all" ]]; then
    [[ -f "$script_merging" ]] || { err "file not found '$script_merging' (merging script)"; exit 1; }

    if [[ "$species" -ne 0 ]]; then
        if ! [[ "$species" =~ ^[0-9]+$ ]]; then
            err "invalid value for --species <taxid>, must be a positive integer (got '$species')"
            exit 1
        fi

        [[ -z "$taxonomy_dir" ]]    && { err "missing required argument -T <dir> (required with --species)"; exit 1; }
        [[ -z "$constraints_dir" ]] && { err "missing required argument -C <dir> (required with --species)"; exit 1; }
        [[ -d "$taxonomy_dir" ]]    || { err "directory not found '$taxonomy_dir' (-T)"; exit 1; }
        [[ -d "$constraints_dir" ]] || { err "directory not found '$constraints_dir' (-C)"; exit 1; }
    fi
fi

# -----------------------------
# Output
# -----------------------------
classic_out="$outdir/classic"
new_out="$outdir/new"
merged_out="$outdir/merged"

if [[ "$mode" == "merge" ]]; then
    # merge reads from an existing outdir — do not recreate it
    [[ -d "$outdir" ]]      || { err "output directory not found '$outdir' (-o)"; exit 1; }
    [[ -d "$classic_out/predictions" ]] || { err "directory not found '$classic_out/predictions' (expected predictions output)"; exit 1; }
    [[ -d "$new_out/predictions" ]]     || { err "directory not found '$new_out/predictions' (expected predictions output)"; exit 1; }
else
    if [[ -d "$outdir" && "$force" -ne 1 ]]; then
        err "output directory exists '$outdir' (use --force)"
        exit 1
    fi

    [[ -d "$outdir" ]] && run rm -rf "$outdir"
    run mkdir -p "$outdir"

    if [[ "$dry_run" -eq 0 ]] && [[ ! -w "$outdir" ]]; then
        err "output directory is not writable '$outdir'"
        exit 1
    fi
fi

# Use simple internal identifiers while the bundled scripts run, then restore
# the complete original FASTA headers in the user-facing prediction files.
header_mapping=""
normalized_fasta=""
mapping_ready=0
if [[ "$mode" != "merge" ]]; then
    header_mapping="$outdir/fasta_header_mapping.tsv"
    normalized_fasta="$outdir/.argot3_normalized.fasta"

    if [[ "$dry_run" -eq 1 ]]; then
        echo "[DRY-RUN] FASTA headers would be prepared for pipeline processing"
    else
        trap cleanup_fasta_mapping EXIT
        run python3 "$fasta_mapping_tool" encode \
            --input "$fasta" \
            --output "$normalized_fasta" \
            --mapping "$header_mapping"
        mapping_ready=1
        fasta="$normalized_fasta"
    fi
fi

# -----------------------------
# Commands
# -----------------------------
classic_cmd=(
    bash "$script_classic"
    -f "$fasta"
    -d "$diamond_db"
    -g "$go_owl"
    -o "$classic_out"
    -t "$threads"
    -m "$mongo_host"
    -P "$mongo_port"
    -D "$mongo_db"
)

new_cmd=(
    bash "$script_new"
    -f "$fasta"
    -g "$go_owl"
    -o "$new_out"
    -s "$structure_dir"
    -w "$weights_dir"
)

merge_cmd=(
    bash "$script_merging"
    -d "$classic_out"
    -t "$new_out"
    -o "$merged_out"
    -g "$go_owl"
)
[[ "$species" -ne 0 ]] && \
    merge_cmd+=(-s "$species" -T "$taxonomy_dir" -C "$constraints_dir")

[[ "$dry_run" -eq 1 ]] && classic_cmd+=(--dry-run) && new_cmd+=(--dry-run) && merge_cmd+=(--dry-run)
[[ "$verbose" -eq 1 ]] && classic_cmd+=(--verbose) && new_cmd+=(--verbose) && merge_cmd+=(--verbose)
if [[ "$force" -eq 1 || "$mode" == "all" ]]; then
    merge_cmd+=(--force)
fi

# -----------------------------
# Execute
# -----------------------------
if [[ "$mode" == "classic" ]]; then
    run "${classic_cmd[@]}"

elif [[ "$mode" == "new" ]]; then
    run "${new_cmd[@]}"

elif [[ "$mode" == "merge" ]]; then
    run "${merge_cmd[@]}"

elif [[ "$mode" == "both" ]]; then
    if [[ "$exec_mode" == "parallel" && "$dry_run" -eq 0 ]]; then
        echo "=== Running ARGOT3 Classic Model ====="
        "${classic_cmd[@]}" > "$outdir/classic.log" 2>&1 & pid1=$!
        echo "  Started (Host PID: $pid1)"
        echo "=== Running ARGOT3 New Model ========="
        "${new_cmd[@]}" > "$outdir/new.log" 2>&1 & pid2=$!
        echo "  Started (Host PID: $pid2)"
        echo
        echo "Logs:"
        echo "  Classic: $outdir/classic.log"
        echo "  New:     $outdir/new.log"
        echo "  Waiting for processes to complete..."

        fail=0
        wait $pid1 || { err "Classic pipeline failed"; fail=1; }
        wait $pid2 || { err "New pipeline failed"; fail=1; }
        [[ $fail -eq 1 ]] && exit 1

        echo
        echo "=== DONE ============================="

    else
        run "${classic_cmd[@]}"
        run "${new_cmd[@]}"
    fi

else  # all
    if [[ "$exec_mode" == "parallel" && "$dry_run" -eq 0 ]]; then
        echo "=== Running ARGOT3 Classic Model ====="
        "${classic_cmd[@]}" > "$outdir/classic.log" 2>&1 & pid1=$!
        echo "  Started (Host PID: $pid1)"
        echo "=== Running ARGOT3 New Model ========="
        "${new_cmd[@]}" > "$outdir/new.log" 2>&1 & pid2=$!
        echo "  Started (Host PID: $pid2)"
        echo
        echo "Logs:"
        echo "  Classic: $outdir/classic.log"
        echo "  New:     $outdir/new.log"
        echo "  Waiting for processes to complete..."

        fail=0
        wait $pid1 || { err "Classic pipeline failed"; fail=1; }
        wait $pid2 || { err "New pipeline failed"; fail=1; }
        [[ $fail -eq 1 ]] && exit 1

    else
        run "${classic_cmd[@]}"
        run "${new_cmd[@]}"
    fi

    run "${merge_cmd[@]}"
fi

if [[ "$mode" != "merge" && "$dry_run" -eq 0 ]]; then
    prediction_files=()
    case "$mode" in
        classic) search_roots=("$classic_out/predictions") ;;
        new)     search_roots=("$new_out/predictions") ;;
        both)    search_roots=("$classic_out/predictions" "$new_out/predictions") ;;
        all)     search_roots=("$classic_out/predictions" "$new_out/predictions" "$merged_out") ;;
    esac

    while IFS= read -r -d '' prediction_file; do
        prediction_files+=("$prediction_file")
    done < <(find "${search_roots[@]}" -type f -name '*.tsv' -print0)

    if [[ ${#prediction_files[@]} -gt 0 ]]; then
        run python3 "$fasta_mapping_tool" restore \
            --mapping "$header_mapping" \
            "${prediction_files[@]}"
    fi
    rm -f -- "$normalized_fasta"
    normalized_fasta=""
fi
