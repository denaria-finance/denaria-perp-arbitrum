// SPDX-License-Identifier: BUSL-1.1

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]

#[cfg(not(any(test, feature = "export-abi")))]
#[unsafe(no_mangle)]
pub extern "C" fn main() {}

#[cfg(feature = "export-abi")]
fn main() {
    denaria_perp_engine_stylus::print_from_args();
}
