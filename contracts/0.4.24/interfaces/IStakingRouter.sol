// SPDX-FileCopyrightText: 2020 Lido <info@lido.fi>

// SPDX-License-Identifier: GPL-3.0

/* See contracts/COMPILERS.md */
pragma solidity 0.4.24;

interface IStakingRouter {
    function getSharesTable() external returns(
        address[] memory recipients, 
        uint256[] memory modulesShares,
        uint256[] memory moduleFee,
        uint256[] memory treasuryFee
    );
    function deposit(bytes pubkeys, bytes signatures) external returns(uint);

    /**
      * @notice Set credentials to withdraw ETH on ETH 2.0 side after the phase 2 is launched to `_withdrawalCredentials`
      * @dev Note that setWithdrawalCredentials discards all unused signing keys as the signatures are invalidated.
      * @param _withdrawalCredentials withdrawal credentials field as defined in the Ethereum PoS consensus specs
      */
    function setWithdrawalCredentials(bytes32 _withdrawalCredentials) external;

    /**
      * @notice Returns current credentials to withdraw ETH on ETH 2.0 side after the phase 2 is launched
      */
    function getWithdrawalCredentials() external view returns (bytes32);

    event WithdrawalCredentialsSet(bytes32 withdrawalCredentials);
}