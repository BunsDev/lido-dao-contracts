// SPDX-FileCopyrightText: 2020 Lido <info@lido.fi>

// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.4.24;

import "../interfaces/ILido.sol";

/**
 * @dev This is a mock. Don't use in production.
 */
contract OracleMock {
    ILido private pool;
    address private beaconReceiver;

    function setPool(address _pool) external {
        pool = ILido(_pool);
    }

    function reportBeacon(
        uint256,
        uint128 _beaconValidators,
        uint128 _beaconBalance
    ) external {
        uint256[] memory empty = new uint256[](0);
        pool.handleOracleReport(_beaconValidators, _beaconBalance, 0, 0, empty, empty, empty);
    }

    function setBeaconReportReceiver(address _receiver) public {
        beaconReceiver = _receiver;
    }

    function getBeaconReportReceiver() external view returns (address) {
        return beaconReceiver;
    }
}
