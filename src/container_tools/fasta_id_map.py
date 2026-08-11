#!/usr/bin/env python3

"""Container-boundary FASTA ID aliasing and prediction ID restoration."""

import argparse
import csv
import os
import sys
import tempfile


MAPPING_FIELDS = ("surrogate_id", "original_header")


def encode_fasta(input_path, output_path, mapping_path):
    sequence_count = 0
    saw_header = False

    with (
        open(input_path, "r", encoding="utf-8", newline="") as source,
        open(output_path, "w", encoding="utf-8", newline="") as normalized,
        open(mapping_path, "w", encoding="utf-8", newline="") as mapping,
    ):
        # csv defaults to CRLF terminators; keep the mapping file readable by
        # line-oriented tools (cut, awk) on the container's Linux filesystem.
        writer = csv.DictWriter(
            mapping, fieldnames=MAPPING_FIELDS, delimiter="\t", lineterminator="\n"
        )
        writer.writeheader()

        for line_number, line in enumerate(source, start=1):
            if line.startswith(">"):
                original_header = line[1:].rstrip("\r\n")
                if not original_header.strip():
                    raise ValueError(f"Empty FASTA header at line {line_number}")

                sequence_count += 1
                surrogate_id = f"seq{sequence_count}"
                writer.writerow(
                    {
                        "surrogate_id": surrogate_id,
                        "original_header": original_header,
                    }
                )
                normalized.write(f">{surrogate_id}\n")
                saw_header = True
            else:
                if line.strip() and not saw_header:
                    raise ValueError(
                        f"Sequence data found before the first FASTA header at line {line_number}"
                    )
                normalized.write(line)

    if sequence_count == 0:
        raise ValueError("The input file does not contain any FASTA records")

    print(f"Prepared {sequence_count} FASTA records for pipeline processing")


def load_mapping(mapping_path):
    with open(mapping_path, "r", encoding="utf-8", newline="") as mapping:
        reader = csv.DictReader(mapping, delimiter="\t")
        if tuple(reader.fieldnames or ()) != MAPPING_FIELDS:
            raise ValueError(f"Unexpected mapping header in {mapping_path}")
        # Prediction files are tab-separated, so preserve the complete FASTA
        # defline while converting embedded tabs to non-structural whitespace.
        return {
            row["surrogate_id"]: row["original_header"].replace("\t", " ")
            for row in reader
        }


def restore_file(path, aliases):
    directory = os.path.dirname(os.path.abspath(path))
    original_mode = os.stat(path).st_mode
    replaced = 0
    temporary_path = None

    try:
        with open(
            path, "r", encoding="utf-8", newline=""
        ) as source, tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", newline="", dir=directory, delete=False
        ) as destination:
            temporary_path = destination.name
            for line in source:
                first, separator, remainder = line.partition("\t")
                original_id = aliases.get(first)
                if separator and original_id is not None:
                    destination.write(original_id + separator + remainder)
                    replaced += 1
                else:
                    destination.write(line)

        os.chmod(temporary_path, original_mode)
        os.replace(temporary_path, path)
        temporary_path = None
    finally:
        if temporary_path is not None and os.path.exists(temporary_path):
            os.unlink(temporary_path)

    print(f"Restored {replaced} prediction IDs in {path}")


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    encode = subparsers.add_parser(
        "encode", help="replace FASTA headers with stable aliases"
    )
    encode.add_argument("--input", required=True)
    encode.add_argument("--output", required=True)
    encode.add_argument("--mapping", required=True)

    restore = subparsers.add_parser(
        "restore", help="restore aliased IDs in prediction TSVs"
    )
    restore.add_argument("--mapping", required=True)
    restore.add_argument("files", nargs="+")

    return parser.parse_args()


def main():
    args = parse_args()
    try:
        if args.command == "encode":
            encode_fasta(args.input, args.output, args.mapping)
        else:
            aliases = load_mapping(args.mapping)
            for path in args.files:
                restore_file(path, aliases)
    except ValueError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
