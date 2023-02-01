// SPDX-FileCopyrightText: 2020 Lido <info@lido.fi>

// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.4.24;

import "../Lido.sol";
import "./VaultMock.sol";

/**
 * @dev Mock for unit-testing handleOracleReport and how reward get calculated
 */
contract LidoPushableMock is Lido {
    uint256 public totalRewards;
    bool public distributeFeeCalled;

    function initialize(address _oracle, address _elRewardsVault, address _withdrawalQueue, address _withdrawalVault) public onlyInit {
        _setProtocolContracts(_oracle, _oracle, _elRewardsVault, _withdrawalQueue, _withdrawalVault);
        _resume();
        initialized();
    }

    function setDepositedValidators(uint256 _depositedValidators) public {
        DEPOSITED_VALIDATORS_POSITION.setStorageUint256(_depositedValidators);
    }

    function setBeaconBalance(uint256 _beaconBalance) public {
        CL_BALANCE_POSITION.setStorageUint256(_beaconBalance);
    }

    // value sent to this function becomes buffered
    function setBufferedEther() public payable {
        BUFFERED_ETHER_POSITION.setStorageUint256(msg.value);
    }

    function setBeaconValidators(uint256 _beaconValidators) public {
        CL_VALIDATORS_POSITION.setStorageUint256(_beaconValidators);
    }

    function setTotalShares(uint256 _totalShares) public {
        TOTAL_SHARES_POSITION.setStorageUint256(_totalShares);
    }

    function resetDistributeFee() public {
        totalRewards = 0;
        distributeFeeCalled = false;
    }

    function getWithdrawalCredentials() public view returns (bytes32) {
        IStakingRouter stakingRouter = getStakingRouter();
        if (address(stakingRouter) != address(0)) {
            return stakingRouter.getWithdrawalCredentials();
        }
        return bytes32(0);
    }

    function _distributeFee(uint256 _totalRewards) internal {
        totalRewards = _totalRewards;
        distributeFeeCalled = true;
    }
}
