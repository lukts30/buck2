/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under both the MIT license found in the
 * LICENSE-MIT file in the root directory of this source tree and the Apache
 * License, Version 2.0 found in the LICENSE-APACHE file in the root directory
 * of this source tree.
 */

use std::future::Future;
use std::sync::Arc;

use allocative::Allocative;
use buck2_futures::owning_future::OwningFuture;
use dupe::Dupe;
use futures::future::BoxFuture;
use futures::FutureExt;
use gazebo::variants::UnpackVariants;

use crate::api::computations::DiceComputations;
use crate::api::data::DiceData;
use crate::api::error::DiceResult;
use crate::api::key::Key;
use crate::api::opaque::OpaqueValue;
use crate::api::user_data::UserComputationData;
use crate::api::user_data::UserCycleDetectorGuard;
use crate::impls::ctx::ModernComputeCtx;
use crate::legacy::ctx::DiceComputationsImplLegacy;
use crate::opaque::OpaqueValueImpl;
use crate::versions::VersionNumber;
use crate::ProjectionKey;

#[derive(Allocative, UnpackVariants, Clone, Dupe)]
pub(crate) enum DiceComputationsImpl {
    Legacy(Arc<DiceComputationsImplLegacy>),
    Modern(Arc<ModernComputeCtx>),
}

impl DiceComputationsImpl {
    /// Gets all the result of of the given computation key.
    /// recorded as dependencies of the current computation for which this
    /// context is for.
    pub(crate) fn compute<'a, K>(
        &'a self,
        key: &K,
    ) -> impl Future<Output = DiceResult<<K as Key>::Value>> + 'a
    where
        K: Key,
    {
        match self {
            DiceComputationsImpl::Legacy(delegate) => delegate.compute(key).left_future(),
            DiceComputationsImpl::Modern(delegate) => delegate.compute(key).right_future(),
        }
    }

    /// Compute "opaque" value where the value is only accessible via projections.
    /// Projections allow accessing derived results from the "opaque" value,
    /// where the dependency of reading a projection is the projection value rather
    /// than the entire opaque value.
    pub(crate) fn compute_opaque<'a, K>(
        &'a self,
        key: &K,
    ) -> impl Future<Output = DiceResult<OpaqueValue<K>>> + 'a
    where
        K: Key,
    {
        match self {
            DiceComputationsImpl::Legacy(delegate) => delegate
                .compute_opaque(key)
                .map(|r| r.map(|x| OpaqueValue::new(OpaqueValueImpl::Legacy(x))))
                .left_future(),
            DiceComputationsImpl::Modern(delegate) => delegate
                .compute_opaque(key)
                .map(|r| r.map(|x| OpaqueValue::new(OpaqueValueImpl::Modern(x))))
                .right_future(),
        }
    }

    pub fn projection<'a, K: Key, P: ProjectionKey<DeriveFromKey = K>>(
        &'a self,
        derive_from: &OpaqueValue<K>,
        projection_key: &P,
    ) -> DiceResult<P::Value> {
        match self {
            DiceComputationsImpl::Legacy(delegate) => delegate.projection(
                derive_from.unpack_legacy().expect("engine type mismatch"),
                projection_key,
            ),
            DiceComputationsImpl::Modern(delegate) => delegate.projection(
                derive_from.unpack_modern().expect("engine type mismatch"),
                projection_key,
            ),
        }
    }

    pub fn opaque_into_value<'a, K: Key>(
        &'a self,
        derive_from: OpaqueValue<K>,
    ) -> DiceResult<K::Value> {
        match self {
            DiceComputationsImpl::Legacy(delegate) => Ok(delegate
                .opaque_into_value(derive_from.into_legacy().expect("engine type mismatch"))),
            DiceComputationsImpl::Modern(delegate) => Ok(delegate
                .opaque_into_value(derive_from.into_modern().expect("engine type mismatch"))),
        }
    }

    /// Computes all the given tasks in parallel, returning an unordered Stream
    pub(crate) fn compute_many<'a, T: 'a>(
        &'a self,
        computes: impl IntoIterator<
            Item = impl for<'x> FnOnce(&'x mut DiceComputations<'a>) -> BoxFuture<'x, T> + Send,
        >,
    ) -> Vec<impl Future<Output = T> + 'a> {
        computes
            .into_iter()
            .map(|work| OwningFuture::new(DiceComputations::borrowed(self), work))
            .collect()
    }

    pub(crate) fn compute2<'a, T: 'a, U: 'a>(
        &'a self,
        compute1: impl for<'x> FnOnce(&'x mut DiceComputations<'a>) -> BoxFuture<'x, T> + Send,
        compute2: impl for<'x> FnOnce(&'x mut DiceComputations<'a>) -> BoxFuture<'x, U> + Send,
    ) -> (impl Future<Output = T> + 'a, impl Future<Output = U> + 'a) {
        (
            OwningFuture::new(DiceComputations::borrowed(self), compute1),
            OwningFuture::new(DiceComputations::borrowed(self), compute2),
        )
    }

    /// Data that is static per the entire lifetime of Dice. These data are initialized at the
    /// time that Dice is initialized via the constructor.
    pub(crate) fn global_data(&self) -> &DiceData {
        match self {
            DiceComputationsImpl::Legacy(delegate) => delegate.global_data(),
            DiceComputationsImpl::Modern(delegate) => delegate.global_data(),
        }
    }

    /// Data that is static for the lifetime of the current request context. This lifetime is
    /// the lifetime of the top-level `DiceComputation` used for all requests.
    /// The data is also specific to each request context, so multiple concurrent requests can
    /// each have their own individual data.
    pub(crate) fn per_transaction_data(&self) -> &UserComputationData {
        match self {
            DiceComputationsImpl::Legacy(delegate) => delegate.per_transaction_data(),
            DiceComputationsImpl::Modern(delegate) => delegate.per_transaction_data(),
        }
    }

    pub(crate) fn cycle_guard<T: UserCycleDetectorGuard>(&self) -> DiceResult<Option<&T>> {
        match self {
            DiceComputationsImpl::Legacy(delegate) => delegate.cycle_guard(),
            DiceComputationsImpl::Modern(delegate) => delegate.cycle_guard(),
        }
    }

    pub fn store_evaluation_data<T: Send + Sync + 'static>(&self, value: T) -> DiceResult<()> {
        match self {
            DiceComputationsImpl::Legacy(delegate) => delegate.store_evaluation_data(value),
            DiceComputationsImpl::Modern(delegate) => delegate.store_evaluation_data(value),
        }
    }

    pub(crate) fn get_version(&self) -> VersionNumber {
        match self {
            DiceComputationsImpl::Legacy(delegate) => delegate.get_version(),
            DiceComputationsImpl::Modern(delegate) => delegate.get_version(),
        }
    }
}
