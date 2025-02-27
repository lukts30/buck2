# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//:artifacts.bzl", "ArtifactGroupInfo")
load("@prelude//python:python.bzl", "PythonLibraryInfo")
load(
    ":manifest.bzl",
    "ManifestInfo",  # @unused Used as a type
    "create_manifest_for_source_map",
)
load(":python.bzl", "PythonLibraryManifestsTSet")

DEFAULT_PY_VERSION = "3.10"

def create_typeshed_manifest_info(
        ctx: AnalysisContext,
        typeshed_deps: list[Dependency]) -> ManifestInfo:
    # NOTE(grievejia): This assumes that if multiple typeshed targets offer
    # the same stub file, the target that comes later wins.
    srcs = {
        artifact.short_path: artifact
        for typeshed_dep in typeshed_deps
        for artifact in typeshed_dep[ArtifactGroupInfo].artifacts
    }
    return create_manifest_for_source_map(ctx, "typeshed", srcs)

def create_per_target_type_check(
        ctx: AnalysisContext,
        executable: RunInfo,
        srcs: ManifestInfo | None,
        deps: list[PythonLibraryInfo],
        typeshed_stubs: list[Dependency],
        py_version: str | None,
        typing_enabled: bool) -> DefaultInfo:
    output_file_name = "type_check_result.json"
    if not typing_enabled:
        # Use empty dict to signal that no type checking was performed.
        output_file = ctx.actions.write_json(output_file_name, {})
    else:
        cmd = cmd_args(executable)
        cmd.add(cmd_args("check"))

        # Source artifacts
        source_manifests = []
        if srcs != None:
            source_manifests = [srcs.manifest]
            cmd.hidden([a for a, _ in srcs.artifacts])

        # Dep artifacts
        dep_manifest_tset = ctx.actions.tset(PythonLibraryManifestsTSet, children = [d.manifests for d in deps])
        dep_manifests = dep_manifest_tset.project_as_args("source_type_manifests")
        cmd.hidden(dep_manifest_tset.project_as_args("source_type_artifacts"))

        # Typeshed artifacts
        if len(typeshed_stubs) > 0:
            typeshed_manifest_info = create_typeshed_manifest_info(ctx, typeshed_stubs)
            cmd.hidden([a for a, _ in typeshed_manifest_info.artifacts])
            typeshed_manifest = typeshed_manifest_info.manifest
        else:
            typeshed_manifest = None

        # Create input configs
        input_config = {
            "dependencies": dep_manifests,
            "py_version": py_version or DEFAULT_PY_VERSION,
            "sources": source_manifests,
            "typeshed": typeshed_manifest,
        }

        input_file = ctx.actions.write_json("type_check_config.json", input_config, with_inputs = True)
        output_file = ctx.actions.declare_output(output_file_name)
        cmd.add(cmd_args(input_file))
        cmd.add(cmd_args(output_file.as_output(), format = "--output={}"))

        ctx.actions.run(cmd, category = "type_check")

    return DefaultInfo(default_output = output_file)
