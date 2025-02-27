# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

def _cgo_enabled_transition(platform, refs, attrs):
    constraints = platform.configuration.constraints

    # Cancel transition if the value already set
    # to enable using configuration modifiers for overiding this option
    cgo_enabled_setting = refs.cgo_enabled_auto[ConstraintValueInfo].setting
    if cgo_enabled_setting.label in constraints:
        return platform

    if attrs.cgo_enabled == None:
        cgo_enabled_ref = refs.cgo_enabled_auto
    elif attrs.cgo_enabled == True:
        cgo_enabled_ref = refs.cgo_enabled_true
    else:
        cgo_enabled_ref = refs.cgo_enabled_false

    cgo_enabled_value = cgo_enabled_ref[ConstraintValueInfo]
    constraints[cgo_enabled_value.setting.label] = cgo_enabled_value

    new_cfg = ConfigurationInfo(
        constraints = constraints,
        values = platform.configuration.values,
    )

    return PlatformInfo(
        label = platform.label,
        configuration = new_cfg,
    )

def _compile_shared_transition(platform, refs, _):
    compile_shared_value = refs.compile_shared_value[ConstraintValueInfo]
    constraints = platform.configuration.constraints
    constraints[compile_shared_value.setting.label] = compile_shared_value
    new_cfg = ConfigurationInfo(
        constraints = constraints,
        values = platform.configuration.values,
    )

    return PlatformInfo(
        label = platform.label,
        configuration = new_cfg,
    )

def _chain_transitions(transitions):
    def tr(platform, refs, attrs):
        for t in transitions:
            platform = t(platform, refs, attrs)
        return platform

    return tr

go_binary_transition = transition(
    impl = _chain_transitions([_cgo_enabled_transition, _compile_shared_transition]),
    refs = {
        "cgo_enabled_auto": "prelude//go/constraints:cgo_enabled_auto",
        "cgo_enabled_false": "prelude//go/constraints:cgo_enabled_false",
        "cgo_enabled_true": "prelude//go/constraints:cgo_enabled_true",
        "compile_shared_value": "prelude//go/constraints:compile_shared_false",
    },
    attrs = ["cgo_enabled"],
)

go_test_transition = transition(
    impl = _chain_transitions([_cgo_enabled_transition, _compile_shared_transition]),
    refs = {
        "cgo_enabled_auto": "prelude//go/constraints:cgo_enabled_auto",
        "cgo_enabled_false": "prelude//go/constraints:cgo_enabled_false",
        "cgo_enabled_true": "prelude//go/constraints:cgo_enabled_true",
        "compile_shared_value": "prelude//go/constraints:compile_shared_false",
    },
    attrs = ["cgo_enabled"],
)

go_exported_library_transition = transition(
    impl = _chain_transitions([_cgo_enabled_transition, _compile_shared_transition]),
    refs = {
        "cgo_enabled_auto": "prelude//go/constraints:cgo_enabled_auto",
        "cgo_enabled_false": "prelude//go/constraints:cgo_enabled_false",
        "cgo_enabled_true": "prelude//go/constraints:cgo_enabled_true",
        "compile_shared_value": "prelude//go/constraints:compile_shared_true",
    },
    attrs = ["cgo_enabled"],
)

cgo_enabled_attr = attrs.default_only(attrs.option(attrs.bool(), default = select({
    "DEFAULT": None,
    "prelude//go/constraints:cgo_enabled_auto": None,
    "prelude//go/constraints:cgo_enabled_false": False,
    "prelude//go/constraints:cgo_enabled_true": True,
})))

compile_shared_attr = attrs.default_only(attrs.bool(default = select({
    "DEFAULT": False,
    "prelude//go/constraints:compile_shared_false": False,
    "prelude//go/constraints:compile_shared_true": True,
})))
