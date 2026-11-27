#!/usr/bin/env python3
"""Verify the frozen TT16 source set and its packaged physical outputs."""

import argparse
import hashlib
import json
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "tt_submission"
TOP = "tt_um_openblastcore32_tt16"
EXPECTED_SOURCE_DIGEST = "f7a45d274bb9037fac01f8771eb8bc0dd093785ba1525918016902ce613f64dc"
EXPECTED_GDS_SHA256 = "35d2a727e3da4baed862d073996a85ab2fb394c916ed31f11f521e54ebe4b539"
EXPECTED_SUBMISSION_SHA256 = {
    "pdk.json": "ce17ddee0d7971e8e6dd7399326ad86dfde273a5daa8f69efb9c617b181a913a",
    "resolved.json": "2ab662ad93914c449182d65a622e57e07e57a70f180b1d54f28623f84f97268a",
    "stats/metrics.csv": "d2c34732349d5d63d98bcfe87999e4bcb0f58aaf0a9d9dd07c3f9bae8960fb69",
    "stats/synthesis-stats.txt": "33af411258c38caf9d11759a5011722f85e1f4f27a81c544b84508cfc350fa5c",
    f"{TOP}.gds": "35d2a727e3da4baed862d073996a85ab2fb394c916ed31f11f521e54ebe4b539",
    f"{TOP}.lef": "bed4087303f5051b88382040553c143f4967bdb1128c044e7da76ece6030938e",
    f"{TOP}.max.spef": "c9f6a2ef63d93c947e20ff3e5c1d6c89512e564a3aff80d131a129dfbd91f2cc",
    f"{TOP}.min.spef": "caf35e1d5a969ae9b315c2fdfb3d65c69049e64622e6b103d5cc8af6d2a611f6",
    f"{TOP}.nom.spef": "c1c4268ae97642fc63ed7d13072b1ef017b3babc5c5a3b6e07f41cd39920f8a7",
    f"{TOP}.oas": "d55681d1e942f52b16826f229f8c4ae697ddd1663baf7aea9ef9d8e48e931158",
    f"{TOP}.v": "633cd9b31c308405ce95e82056c232c89a92bad5ffb723aca95b01b75ec791f0",
}
MANIFEST_NAME = "release_manifest.json"
SUMS_NAME = "SHA256SUMS.txt"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def source_inventory():
    project = yaml.safe_load((ROOT / "info.yaml").read_text(encoding="utf-8"))["project"]
    require(project["top_module"] == TOP, "Project top does not match the release top")
    declared = project["source_files"]
    require(len(declared) == len(set(declared)), "Duplicate source files in info.yaml")

    sources = {
        path.name: path
        for path in (ROOT / "src").glob("*.v")
    }
    require(set(declared) == set(sources), "RTL source list differs from info.yaml")
    require(
        (ROOT / "src" / "vendor" / "gamepad_pmod" / "LICENSE-2.0.txt").is_file(),
        "Missing Gamepad PMOD license",
    )
    hashes = {name: sha256(sources[name]) for name in sorted(sources)}
    digest = hashlib.sha256(
        json.dumps(hashes, sort_keys=True, separators=(",", ":")).encode("ascii")
    ).hexdigest()
    require(digest == EXPECTED_SOURCE_DIGEST, "Release RTL source digest mismatch")
    project_files = {
        "LICENSE": ROOT / "LICENSE",
        "docs/info.md": ROOT / "docs" / "info.md",
        "info.yaml": ROOT / "info.yaml",
        "src/vendor/gamepad_pmod/LICENSE-2.0.txt":
            ROOT / "src" / "vendor" / "gamepad_pmod" / "LICENSE-2.0.txt",
    }
    return hashes, digest, {
        name: sha256(path) for name, path in sorted(project_files.items())
    }


def package_inventory():
    gds_name = f"{TOP}.gds"
    require((PACKAGE / gds_name).is_file(), "Missing release GDS")
    require(sha256(PACKAGE / gds_name) == EXPECTED_GDS_SHA256, "Release GDS hash mismatch")

    required = {
        gds_name,
        f"{TOP}.oas",
        f"{TOP}.lef",
        f"{TOP}.v",
        f"{TOP}.min.spef",
        f"{TOP}.nom.spef",
        f"{TOP}.max.spef",
        "pdk.json",
        "resolved.json",
        "stats/metrics.csv",
        "stats/synthesis-stats.txt",
    }
    actual = {
        path.relative_to(PACKAGE).as_posix()
        for path in PACKAGE.rglob("*")
        if path.is_file() and path.name not in {MANIFEST_NAME, SUMS_NAME}
    }
    require(actual == required, "Submission package file inventory mismatch")
    require(not (PACKAGE / "commit_id.json").exists(), "Unexpected build provenance file")

    pdk = json.loads((PACKAGE / "pdk.json").read_text(encoding="utf-8"))
    require(pdk["PDK"] == "sky130A", "Unexpected PDK")
    require(
        pdk["PDK_VERSION"] == "8afc8346a57fe1ab7934ba5a6056ea8b43078e71",
        "Unexpected PDK revision",
    )
    hashes = {
        name: sha256(PACKAGE / name)
        for name in sorted(actual)
    }
    require(hashes == EXPECTED_SUBMISSION_SHA256, "Submission artifact hash mismatch")
    return hashes


def write_manifests(source_hashes, source_digest, project_hashes, package_hashes):
    manifest = {
        "release_top": TOP,
        "rtl_source_digest": source_digest,
        "rtl_source_sha256": source_hashes,
        "project_file_sha256": project_hashes,
        "submission_file_sha256": package_hashes,
    }
    manifest_path = PACKAGE / MANIFEST_NAME
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    files = sorted(
        path for path in PACKAGE.rglob("*")
        if path.is_file() and path.name != SUMS_NAME
    )
    sums = "".join(
        f"{sha256(path)}  ./{path.relative_to(PACKAGE).as_posix()}\n"
        for path in files
    )
    (PACKAGE / SUMS_NAME).write_text(sums, encoding="utf-8")


def verify_manifests(source_hashes, source_digest, project_hashes, package_hashes):
    manifest = json.loads((PACKAGE / MANIFEST_NAME).read_text(encoding="utf-8"))
    require(manifest["release_top"] == TOP, "Manifest release top mismatch")
    require(manifest["rtl_source_digest"] == source_digest, "Manifest source digest mismatch")
    require(manifest["rtl_source_sha256"] == source_hashes, "Manifest source hashes mismatch")
    require(
        manifest["project_file_sha256"] == project_hashes,
        "Manifest project file hashes mismatch",
    )
    require(
        manifest["submission_file_sha256"] == package_hashes,
        "Manifest submission file hashes mismatch",
    )

    expected_sums = {
        path.relative_to(PACKAGE).as_posix(): sha256(path)
        for path in PACKAGE.rglob("*")
        if path.is_file() and path.name != SUMS_NAME
    }
    recorded_sums = {}
    for line in (PACKAGE / SUMS_NAME).read_text(encoding="utf-8").splitlines():
        digest, name = line.split("  ", 1)
        require(name.startswith("./"), f"Invalid checksum path: {name}")
        recorded_sums[name[2:]] = digest
    require(recorded_sums == expected_sums, "Package checksum file mismatch")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--write-manifest",
        action="store_true",
        help="write the package hash manifest and SHA256SUMS.txt",
    )
    args = parser.parse_args()

    source_hashes, source_digest, project_hashes = source_inventory()
    package_hashes = package_inventory()
    if args.write_manifest:
        write_manifests(source_hashes, source_digest, project_hashes, package_hashes)
    verify_manifests(source_hashes, source_digest, project_hashes, package_hashes)
    print("Release source and submission package hashes verified.")


if __name__ == "__main__":
    main()
