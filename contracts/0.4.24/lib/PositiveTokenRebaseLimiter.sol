// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>

// SPDX-License-Identifier: GPL-3.0

/* See contracts/COMPILERS.md */
pragma solidity 0.4.24;

import {SafeMath} from "@aragon/os/contracts/lib/math/SafeMath.sol";

import {Math256} from "../../common/lib/Math256.sol";

/**
 * This library implements positive rebase limiter for `stETH` token.
 * One needs to initialize `LimiterState` with the desired parameters:
 * - _maxLimiterValue (limiter max value, nominated in LIMITER_PRECISION_POINTS)
 * - _totalPooledEther (see `Lido.getTotalPooledEther()`)
 * - _totalShares (see `Lido.getTotalShares()`)
 *
 * The limiter allows to account for:
 * - consensus layer balance updates (can be either positive or negative)
 * - total pooled ether changes (withdrawing funds from vaults on execution layer)
 * - total shares changes (coverage application)
 */

library LimiterState {
    /**
      * @dev Internal limiter representation struct (storing in memory)
      */
    struct Data {
        uint256 totalPooledEther; // total pooled ether pre-rebase
        uint256 totalShares;      // total shares before pre-rebase
        uint256 maxLimiterValue;  // max positive rebase (target value)
        uint256 prevLimiterValue; // accumulated rebase (previous value)
    }
}

library PositiveTokenRebaseLimiter {
    using SafeMath for uint256;

    /// @dev Precision base for the limiter (e.g.: 1e6 - 0.1%; 1e9 - 100%)
    uint256 private constant LIMITER_PRECISION_BASE = 10**9;

    /**
      * @dev Initialize the new `LimiterState` structure instance
      * @param _maxLimiterValue max limiter value (saturation point), see `LIMITER_PRECISION_POINTS`
      * @param _totalPooledEther total pooled ether, see `Lido.getTotalPooledEther()`
      * @param _totalShares total shares, see `Lido.getTotalShares()`
      * @return newly initialized limiter structure
      */
    function initLimiterState(
        uint256 _maxLimiterValue,
        uint256 _totalPooledEther,
        uint256 _totalShares
    ) internal pure returns (LimiterState.Data memory _limiterState) {
        require(_maxLimiterValue <= LIMITER_PRECISION_BASE, "TOO_LARGE_TOKEN_REBASE_MAX");
        require(_maxLimiterValue > 0, "TOO_LOW_TOKEN_REBASE_MAX");

        _limiterState.totalPooledEther = _totalPooledEther;
        _limiterState.totalShares = _totalShares;
        _limiterState.maxLimiterValue = _maxLimiterValue;
    }

    /**
     * @notice check if positive rebase limit is reached
     * @param _limiterState limit repr struct
     * @return true if limit is reached
     */
    function isLimitReached(LimiterState.Data memory _limiterState) internal pure returns (bool) {
        return _limiterState.prevLimiterValue == _limiterState.maxLimiterValue;
    }

    /**
     * @dev apply consensus layer balance update
     * @param _limiterState limit repr struct
     * @param _clBalanceDiff cl balance diff (can be negative!)
     *
     * NB: if `_clBalanceDiff` is negative than max limiter value is pushed higher
     * otherwise limiter is updated with the `appendEther` call.
     */
    function applyCLBalanceUpdate(LimiterState.Data memory _limiterState, int256 _clBalanceDiff) internal view {
        require(_limiterState.prevLimiterValue == 0, "DIRTY_LIMITER_STATE");

        if (_clBalanceDiff < 0) {
            _limiterState.maxLimiterValue = Math256.min(
                _limiterState.maxLimiterValue.add(
                    uint256(-_clBalanceDiff).mul(LIMITER_PRECISION_BASE).div(_limiterState.totalPooledEther)
                ),
                LIMITER_PRECISION_BASE
            );
        } else {
            appendEther(_limiterState, uint256(_clBalanceDiff));
        }
    }

    /**
     * @dev append ether and return value not exceeding the limit
     * @param _limiterState limit repr struct
     * @param _etherAmount desired ether addition
     * @return allowed to add ether to not exceed the limit
     */
    function appendEther(LimiterState.Data memory _limiterState, uint256 _etherAmount)
        internal
        view
        returns (uint256 appendableEther)
    {
        uint256 remainingLimit = _limiterState.maxLimiterValue.sub(_limiterState.prevLimiterValue);
        uint256 remainingLimitEther = remainingLimit.mul(_limiterState.totalPooledEther).div(LIMITER_PRECISION_BASE);

        appendableEther = Math256.min(remainingLimitEther, _etherAmount);

        if (appendableEther == remainingLimitEther) {
            _limiterState.prevLimiterValue = _limiterState.maxLimiterValue;
        } else {
            _limiterState.prevLimiterValue = _limiterState.prevLimiterValue.add(
                appendableEther.mul(LIMITER_PRECISION_BASE).div(_limiterState.totalPooledEther)
            );
        }
    }

    /**
     * @dev deduct shares and return value not exceeding the limit
     * @param _limiterState limit repr struct
     * @param _sharesAmount desired shares deduction
     * @return allowed to deduct shares to not exceed the limit
     */
    function deductShares(LimiterState.Data memory _limiterState, uint256 _sharesAmount)
        internal
        pure
        returns (uint256 deductableShares)
    {
        uint256 remainingLimit = _limiterState.maxLimiterValue.sub(_limiterState.prevLimiterValue);
        uint256 remainingLimitShares = _limiterState.totalShares.mul(remainingLimit).div(
            LIMITER_PRECISION_BASE.add(remainingLimit)
        );

        deductableShares = Math256.min(_sharesAmount, remainingLimitShares);

        if (deductableShares == remainingLimitShares) {
            _limiterState.prevLimiterValue = _limiterState.maxLimiterValue;
        } else {
            _limiterState.prevLimiterValue = _limiterState.prevLimiterValue.add(
                deductableShares.mul(LIMITER_PRECISION_BASE).div(_limiterState.totalShares.sub(deductableShares))
            );
        }
    }
}