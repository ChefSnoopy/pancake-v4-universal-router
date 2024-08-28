// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import {Permit2Payments} from "../../Permit2Payments.sol";
// import {V4Router} from "pancake-v4-periphery/src/V4Router.sol";
import {V4Router} from "../../../V4Router/V4Router.sol";
import {IVault} from "pancake-v4-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "pancake-v4-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "pancake-v4-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {Currency} from "pancake-v4-core/src/types/Currency.sol";
import {CalldataDecoder} from "../../../V4Router/libraries/CalldataDecoder.sol";

/// @title Router for PCS v4 Trades
abstract contract V4SwapRouter is V4Router, Permit2Payments {
    using CalldataDecoder for bytes;

    constructor(address _vault, address _clPoolManager, address _binPoolManager)
        V4Router(IVault(_vault), ICLPoolManager(_clPoolManager), IBinPoolManager(_binPoolManager))
    {}

    function _pay(Currency token, address payer, uint256 amount) internal override {
        payOrPermit2Transfer(Currency.unwrap(token), payer, address(vault), amount);
    }

    /// @notice function that is called by the Vault through the SafeCallback.lockAcquired
    /// @param data Abi encoding of (bytes actions, bytes[] params)
    /// where params[i] is the encoded parameters for actions[i]
    function _lockAcquired(bytes calldata data) internal override returns (bytes memory) {
        (bool isDefault, bytes calldata extraData) = data.decodeBoolAndBytes();
        if (isDefault) {
            _executeDefaultActions(extraData);
        } else {
            _executeExtraLogic(extraData);
        }
        return "";
    }

    function _executeDefaultActions(bytes calldata data) internal {
        // abi.decode(data, (bytes, bytes[]));
        (bytes calldata actions, bytes[] calldata params) = data.decodeActionsRouterParams();
        _executeActionsWithoutLock(actions, params);
    }

    function _executeExtraLogic(bytes calldata data) internal virtual;
}
