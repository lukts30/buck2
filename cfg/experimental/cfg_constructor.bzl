# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@prelude//utils:graph_utils.bzl", "post_order_traversal")
load(
    ":common.bzl",
    "get_constraint_setting_deps",
    "get_modifier_info",
    "merge_modifiers",
    "modifier_key_to_constraint_setting",
    "modifier_to_refs",
    "resolve_modifier",
)
load(":name.bzl", "cfg_name")
load(
    ":types.bzl",
    "ModifierCliLocation",
    "TaggedModifier",
    "TaggedModifierInfo",
)

PostConstraintAnalysisParams = record(
    legacy_platform = PlatformInfo | None,
    # Merged modifier dictionaries from PACKAGE and target modifiers.
    # If a key exists in both PACKAGE and target modifiers, the target modifier
    # will override PACKAGE modifier for that key.
    package_and_target_modifiers = dict[str, list[TaggedModifier]],
    cli_modifiers = list[str],
)

def cfg_constructor_pre_constraint_analysis(
        *,
        legacy_platform: PlatformInfo | None,
        package_modifiers: dict[str, list[TaggedModifier]] | None,
        target_modifiers: dict[str, TaggedModifier] | None,
        cli_modifiers: list[str]) -> (list[str], PostConstraintAnalysisParams):
    """
    First stage of cfg constructor for modifiers.

    Args:
        legacy_platform:
            PlatformInfo from legacy target platform resolution, if one is specified
        package_modifiers:
            Modifiers specified from all parent PACKAGE files aggregated into a single dictionary.
            Key of dictionary is the modifier key converted from constraint setting.
            Value of dictionary is the modifier for that constraint setting.
        target_modifier:
            Modifiers specified from buildfile via `metadata` attribute.
            Key of dictionary is the modifier key converted from constraint setting.
            Value of dictionary is the modifier for that constraint setting.
        cli_modifiers:
            modifiers specified from `--modifier` flag, `?modifier`, or BXL

    Returns `(refs, PostConstraintAnalysisParams)`, where `refs` is a list of fully qualified configuration
    targets we need providers for.
    """

    package_modifiers = package_modifiers or {}
    target_modifiers = target_modifiers or {}

    # Convert modifier keys back to constraint settings
    package_modifiers = {modifier_key_to_constraint_setting(key): val for key, val in package_modifiers.items()}
    target_modifiers = {modifier_key_to_constraint_setting(key): val for key, val in target_modifiers.items()}

    # Merge PACKAGE and target modifiers into one dictionary
    package_and_target_modifiers = package_modifiers
    for modifier_key, modifier_with_loc in target_modifiers.items():
        package_and_target_modifiers[modifier_key] = merge_modifiers(
            package_and_target_modifiers.get(modifier_key),
            modifier_with_loc,
        )

    refs = []
    for constraint_setting, modifiers in package_and_target_modifiers.items():
        refs.append(constraint_setting)
        for modifier_with_loc in modifiers:
            refs.extend(modifier_to_refs(modifier_with_loc.modifier, constraint_setting, modifier_with_loc.location))
    refs.extend(cli_modifiers)

    return refs, PostConstraintAnalysisParams(
        legacy_platform = legacy_platform,
        package_and_target_modifiers = package_and_target_modifiers,
        cli_modifiers = cli_modifiers,
    )

def _get_constraint_setting_and_tagged_modifier_infos(
        refs: dict[str, ProviderCollection],
        constraint_setting: str,
        modifiers: list[TaggedModifier]) -> (TargetLabel, list[TaggedModifierInfo]):
    constraint_setting_info = refs[constraint_setting][ConstraintSettingInfo]
    modifier_infos = [TaggedModifierInfo(
        modifier_info = get_modifier_info(
            refs = refs,
            modifier = modifier_with_loc.modifier,
            constraint_setting = constraint_setting,
            location = modifier_with_loc.location,
        ),
        location = modifier_with_loc.location,
    ) for modifier_with_loc in modifiers]
    return constraint_setting_info.label, modifier_infos

def cfg_constructor_post_constraint_analysis(
        *,
        refs: dict[str, ProviderCollection],
        params: PostConstraintAnalysisParams) -> PlatformInfo:
    """
    Second stage of cfg constructor for modifiers.

    Args:
        refs: a dictionary of fully qualified target labels for configuration targets with their providers
        params: `PostConstraintAnalysisParams` returned from first stage of cfg constructor

    Returns a PlatformInfo
    """

    constraint_setting_to_tagged_modifier_infos = {}

    for constraint_setting, modifiers in params.package_and_target_modifiers.items():
        constraint_setting_label, tagged_modifier_infos = _get_constraint_setting_and_tagged_modifier_infos(
            refs = refs,
            constraint_setting = constraint_setting,
            modifiers = modifiers,
        )
        constraint_setting_to_tagged_modifier_infos[constraint_setting_label] = tagged_modifier_infos

    for modifier in params.cli_modifiers:
        constraint_value_info = refs[modifier][ConstraintValueInfo]
        constraint_setting_to_tagged_modifier_infos[constraint_value_info.setting.label] = [TaggedModifierInfo(
            modifier_info = constraint_value_info,
            location = ModifierCliLocation(),
        )]

    # Modifiers are resolved in topological ordering of modifier selects. For example, if the CPU modifier
    # is a modifier_select on OS constraint, then the OS modifier must be resolved before the CPU modifier.
    # To determine this order, we first construct a dep graph of constraint settings based on the modifier
    # selects. Then we perform a post order traversal of the said graph.
    modifier_dep_graph = {
        constraint_setting: [
            dep
            for tagged_modifier_info in tagged_modifier_infos
            for dep in get_constraint_setting_deps(tagged_modifier_info.modifier_info)
        ]
        for constraint_setting, tagged_modifier_infos in constraint_setting_to_tagged_modifier_infos.items()
    }
    constraint_setting_order = post_order_traversal(modifier_dep_graph)

    if not constraint_setting_to_tagged_modifier_infos:
        # If there is no modifier and legacy platform is specified,
        # then return the legacy platform as is without changing the label or
        # configuration.
        return params.legacy_platform or PlatformInfo(
            # Empty configuration
            label = "",
            configuration = ConfigurationInfo(
                constraints = {},
                values = {},
            ),
        )

    cfg = ConfigurationInfo(
        constraints = {},
        values = {},
    )
    for constraint_setting in constraint_setting_order:
        for tagged_modifier_info in constraint_setting_to_tagged_modifier_infos[constraint_setting]:
            constraint_value = resolve_modifier(cfg, tagged_modifier_info.modifier_info)
            if constraint_value:
                cfg.constraints[constraint_setting] = constraint_value

    if params.legacy_platform:
        # For backwards compatibility with legacy target platform, any constraint setting
        # from legacy target platform not covered by modifiers will be added to the configuration
        for key, value in params.legacy_platform.configuration.constraints.items():
            if key not in cfg.constraints:
                cfg.constraints[key] = value

    name = cfg_name(cfg)
    return PlatformInfo(
        label = name,
        configuration = cfg,
    )
