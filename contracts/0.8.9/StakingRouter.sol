// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>

// SPDX-License-Identifier: GPL-3.0

/* See contracts/COMPILERS.md */
pragma solidity 0.8.9;

import {AccessControlEnumerable} from "@openzeppelin/contracts-v4.4/access/AccessControlEnumerable.sol";

import {IStakingRouter} from "./interfaces/IStakingRouter.sol";
import {IStakingModule} from "./interfaces/IStakingModule.sol";
import {ILido} from "./interfaces/ILido.sol";

import {Math} from "./lib/Math.sol";
import {UnstructuredStorage} from "./lib/UnstructuredStorage.sol";
import {MinFirstAllocationStrategy} from "../common/lib/MinFirstAllocationStrategy.sol";

import {BeaconChainDepositor} from "./BeaconChainDepositor.sol";

contract StakingRouter is IStakingRouter, AccessControlEnumerable, BeaconChainDepositor {
    using UnstructuredStorage for bytes32;

    /// @dev events
    event StakingModuleAdded(uint24 indexed stakingModuleId, address stakingModule, string name, address createdBy);
    event StakingModuleTargetShareSet(uint24 indexed stakingModuleId, uint16 targetShare, address setBy);
    event StakingModuleFeesSet(uint24 indexed stakingModuleId, uint16 stakingModuleFee, uint16 treasuryFee, address setBy);
    event StakingModuleStatusSet(uint24 indexed stakingModuleId, StakingModuleStatus status, address setBy);
    event WithdrawalCredentialsSet(bytes32 withdrawalCredentials, address setBy);
    event ContractVersionSet(uint256 version);
    /**
     * Emitted when the StakingRouter received ETH
     */
    event StakingRouterETHReceived(uint256 amount);
    event StakingRouterETHDeposited(uint24 indexed stakingModuleId, uint256 amount);

    /// @dev errors
    error ErrorZeroAddress(string field);
    error ErrorBaseVersion();
    error ErrorValueOver100Percent(string field);
    error ErrorStakingModuleStatusNotChanged();
    error ErrorStakingModuleNotActive();
    error ErrorStakingModuleNotPaused();
    error ErrorEmptyWithdrawalsCredentials();
    error ErrorDirectETHTransfer();
    error ErrorStakingModulesLimitExceeded();
    error ErrorStakingModuleIdTooLarge();
    error ErrorStakingModuleUnregistered();
    error ErrorAppAuthLidoFailed();
    error ErrorStakingModuleStatusTheSame();
    error ErrorStakingModuleWrongName();

    struct StakingModuleCache {
        address stakingModuleAddress;
        uint16 stakingModuleFee;
        uint16 treasuryFee;
        uint16 targetShare;
        StakingModuleStatus status;
        uint256 activeKeysCount;
        uint256 availableKeysCount;
    }

    bytes32 public constant MANAGE_WITHDRAWAL_CREDENTIALS_ROLE = keccak256("MANAGE_WITHDRAWAL_CREDENTIALS_ROLE");
    bytes32 public constant STAKING_MODULE_PAUSE_ROLE = keccak256("STAKING_MODULE_PAUSE_ROLE");
    bytes32 public constant STAKING_MODULE_RESUME_ROLE = keccak256("STAKING_MODULE_RESUME_ROLE");
    bytes32 public constant STAKING_MODULE_MANAGE_ROLE = keccak256("STAKING_MODULE_MANAGE_ROLE");

    /// Version of the initialized contract data
    /// NB: Contract versioning starts from 1.
    /// The version stored in CONTRACT_VERSION_POSITION equals to
    /// - 0 right after deployment when no initializer is invoked yet
    /// - N after calling initialize() during deployment from scratch, where N is the current contract version
    /// - N after upgrading contract from the previous version (after calling finalize_vN())
    bytes32 internal constant CONTRACT_VERSION_POSITION = keccak256("lido.StakingRouter.contractVersion");

    bytes32 internal constant LIDO_POSITION = keccak256("lido.StakingRouter.lido");

    /// @dev Credentials which allows the DAO to withdraw Ether on the 2.0 side
    bytes32 internal constant WITHDRAWAL_CREDENTIALS_POSITION = keccak256("lido.StakingRouter.withdrawalCredentials");

    /// @dev total count of staking modules
    bytes32 internal constant STAKING_MODULES_COUNT_POSITION = keccak256("lido.StakingRouter.stakingModulesCount");
    /// @dev id of the last added staking module. This counter grow on staking modules adding
    bytes32 internal constant LAST_STAKING_MODULE_ID_POSITION = keccak256("lido.StakingRouter.lastStakingModuleId");
    /// @dev mapping is used instead of array to allow to extend the StakingModule
    bytes32 internal constant STAKING_MODULES_MAPPING_POSITION = keccak256("lido.StakingRouter.stakingModules");
    /// @dev Position of the staking modules in the `_stakingModules` map, plus 1 because
    ///      index 0 means a value is not in the set.
    bytes32 internal constant STAKING_MODULE_INDICES_MAPPING_POSITION = keccak256("lido.StakingRouter.stakingModuleIndicesOneBased");

    uint256 public constant FEE_PRECISION_POINTS = 10 ** 20; // 100 * 10 ** 18
    uint256 public constant TOTAL_BASIS_POINTS = 10000;

    uint256 internal constant UINT24_MAX = type(uint24).max;

    modifier validStakingModuleId(uint256 _stakingModuleId) {
        if (_stakingModuleId > UINT24_MAX) revert ErrorStakingModuleIdTooLarge();
        _;
    }

    constructor(address _depositContract) BeaconChainDepositor(_depositContract) {
        /// @dev lock version in implementation to avoid initialize() call
        ///      DEFAULT_ADMIN_ROLE will remain unset, i.e. no ability to add new members or roles
        _setContractVersion(type(uint256).max);
    }

    /**
     * @dev proxy initialization
     * @param _admin Lido DAO Aragon agent contract address
     * @param _lido Lido address
     * @param _withdrawalCredentials Lido withdrawal vault contract address
     */
    function initialize(address _admin, address _lido, bytes32 _withdrawalCredentials) external {
        if (_admin == address(0)) revert ErrorZeroAddress("_admin");
        if (_lido == address(0)) revert ErrorZeroAddress("_lido");
        if (CONTRACT_VERSION_POSITION.getStorageUint256() != 0) revert ErrorBaseVersion();
        _setContractVersion(1);

        _setupRole(DEFAULT_ADMIN_ROLE, _admin);

        LIDO_POSITION.setStorageAddress(_lido);
        WITHDRAWAL_CREDENTIALS_POSITION.setStorageBytes32(_withdrawalCredentials);
        emit WithdrawalCredentialsSet(_withdrawalCredentials, msg.sender);
    }

    /// @dev prohibit direct transfer to contract
    receive() external payable {
        revert ErrorDirectETHTransfer();
    }

    /**
     * @notice Return the Lido contract address
     */
    function getLido() public view returns (ILido) {
        return ILido(LIDO_POSITION.getStorageAddress());
    }

    /**
     * @notice register a new staking module
     * @param _name name of staking module
     * @param _stakingModuleAddress address of staking module
     * @param _targetShare target total stake share
     * @param _stakingModuleFee fee of the staking module taken from the consensus layer rewards
     * @param _treasuryFee treasury fee
     */
    function addStakingModule(
        string calldata _name,
        address _stakingModuleAddress,
        uint16 _targetShare,
        uint16 _stakingModuleFee,
        uint16 _treasuryFee
    ) external onlyRole(STAKING_MODULE_MANAGE_ROLE) {
        if (_targetShare > TOTAL_BASIS_POINTS) revert ErrorValueOver100Percent("_targetShare");
        if (_stakingModuleFee + _treasuryFee > TOTAL_BASIS_POINTS) revert ErrorValueOver100Percent("_stakingModuleFee + _treasuryFee");
        if (_stakingModuleAddress == address(0)) revert ErrorZeroAddress("_stakingModuleAddress");
        if (bytes(_name).length == 0 || bytes(_name).length > 32) revert ErrorStakingModuleWrongName();

        uint256 newStakingModuleIndex = getStakingModulesCount();

        if (newStakingModuleIndex >= 32) revert ErrorStakingModulesLimitExceeded();
        StakingModule storage newStakingModule = _getStakingModuleByIndex(newStakingModuleIndex);
        uint24 newStakingModuleId = uint24(LAST_STAKING_MODULE_ID_POSITION.getStorageUint256()) + 1;

        newStakingModule.id = newStakingModuleId;
        newStakingModule.name = _name;
        newStakingModule.stakingModuleAddress = _stakingModuleAddress;
        newStakingModule.targetShare = _targetShare;
        newStakingModule.stakingModuleFee = _stakingModuleFee;
        newStakingModule.treasuryFee = _treasuryFee;
        /// @dev since `enum` is `uint8` by nature, so the `status` is stored as `uint8` to avoid possible problems when upgrading.
        ///      But for human readability, we use `enum` as function parameter type.
        ///      More about conversion in the docs https://docs.soliditylang.org/en/v0.8.17/types.html#enums
        newStakingModule.status = uint8(StakingModuleStatus.Active);

        _setStakingModuleIndexById(newStakingModuleId, newStakingModuleIndex);
        LAST_STAKING_MODULE_ID_POSITION.setStorageUint256(newStakingModuleId);
        STAKING_MODULES_COUNT_POSITION.setStorageUint256(newStakingModuleIndex + 1);

        emit StakingModuleAdded(newStakingModuleId, _stakingModuleAddress, _name, msg.sender);
        emit StakingModuleTargetShareSet(newStakingModuleId, _targetShare, msg.sender);
        emit StakingModuleFeesSet(newStakingModuleId, _stakingModuleFee, _treasuryFee, msg.sender);
    }

    /**
     * @notice update staking module params
     * @param _stakingModuleId staking module id
     * @param _targetShare target total stake share
     * @param _stakingModuleFee fee of the staking module taken from the consensus layer rewards
     * @param _treasuryFee treasury fee
     */
    function updateStakingModule(
        uint256 _stakingModuleId,
        uint16 _targetShare,
        uint16 _stakingModuleFee,
        uint16 _treasuryFee
    ) external
      validStakingModuleId(_stakingModuleId)
      onlyRole(STAKING_MODULE_MANAGE_ROLE)
    {
        if (_targetShare > TOTAL_BASIS_POINTS) revert ErrorValueOver100Percent("_targetShare");
        if (_stakingModuleFee + _treasuryFee > TOTAL_BASIS_POINTS) revert ErrorValueOver100Percent("_stakingModuleFee + _treasuryFee");

        uint256 stakingModuleIndex = _getStakingModuleIndexById(uint24(_stakingModuleId));
        StakingModule storage stakingModule = _getStakingModuleByIndex(stakingModuleIndex);

        stakingModule.targetShare = _targetShare;
        stakingModule.treasuryFee = _treasuryFee;
        stakingModule.stakingModuleFee = _stakingModuleFee;

        emit StakingModuleTargetShareSet(uint24(_stakingModuleId), _targetShare, msg.sender);
        emit StakingModuleFeesSet(uint24(_stakingModuleId), _stakingModuleFee, _treasuryFee, msg.sender);
    }


    /**
     * @notice Returns all registred staking modules
     */
    function getStakingModules() external view returns (StakingModule[] memory res) {
        uint256 stakingModulesCount = getStakingModulesCount();
        res = new StakingModule[](stakingModulesCount);
        for (uint256 i; i < stakingModulesCount; ) {
            res[i] = _getStakingModuleByIndex(i);
            unchecked {
                ++i;
            }
        }
    }

    /**
     *  @dev Returns staking module by id
     */
    function getStakingModule(uint256 _stakingModuleId)
        external
        view
        validStakingModuleId(_stakingModuleId)
        returns (StakingModule memory)
    {
        return _getStakingModuleById(uint24(_stakingModuleId));
    }

    /**
     * @dev Returns total number of staking modules
     */
    function getStakingModulesCount() public view returns (uint256) {
        return STAKING_MODULES_COUNT_POSITION.getStorageUint256();
    }

    /**
     * @dev Returns status of staking module
     */
    function getStakingModuleStatus(uint256 _stakingModuleId) public view
        validStakingModuleId(_stakingModuleId)
        returns (StakingModuleStatus)
    {
        return StakingModuleStatus(_getStakingModuleById(uint24(_stakingModuleId)).status);
    }

    /**
     * @notice set the staking module status flag for participation in further deposits and/or reward distribution
     */
    function setStakingModuleStatus(uint256 _stakingModuleId, StakingModuleStatus _status) external
        validStakingModuleId(_stakingModuleId)
        onlyRole(STAKING_MODULE_MANAGE_ROLE)
    {
        StakingModule storage stakingModule = _getStakingModuleById(uint24(_stakingModuleId));
        StakingModuleStatus _prevStatus = StakingModuleStatus(stakingModule.status);
        if (_prevStatus == _status) revert ErrorStakingModuleStatusTheSame();
        stakingModule.status = uint8(_status);
        emit StakingModuleStatusSet(uint24(_stakingModuleId), _status, msg.sender);
    }

    /**
     * @notice pause deposits for staking module
     * @param _stakingModuleId id of the staking module to be paused
     */
    function pauseStakingModule(uint256 _stakingModuleId) external
        validStakingModuleId(_stakingModuleId)
        onlyRole(STAKING_MODULE_PAUSE_ROLE)
    {
        StakingModule storage stakingModule = _getStakingModuleById(uint24(_stakingModuleId));
        StakingModuleStatus _prevStatus = StakingModuleStatus(stakingModule.status);
        if (_prevStatus != StakingModuleStatus.Active) revert ErrorStakingModuleNotActive();
        stakingModule.status = uint8(StakingModuleStatus.DepositsPaused);
        emit StakingModuleStatusSet(uint24(_stakingModuleId), StakingModuleStatus.DepositsPaused, msg.sender);
    }

    /**
     * @notice resume deposits for staking module
     * @param _stakingModuleId id of the staking module to be unpaused
     */
    function resumeStakingModule(uint256 _stakingModuleId) external
        validStakingModuleId(_stakingModuleId)
        onlyRole(STAKING_MODULE_RESUME_ROLE)
    {
        StakingModule storage stakingModule = _getStakingModuleById(uint24(_stakingModuleId));
        StakingModuleStatus _prevStatus = StakingModuleStatus(stakingModule.status);
        if (_prevStatus != StakingModuleStatus.DepositsPaused) revert ErrorStakingModuleNotPaused();
        stakingModule.status = uint8(StakingModuleStatus.Active);
        emit StakingModuleStatusSet(uint24(_stakingModuleId), StakingModuleStatus.Active, msg.sender);
    }

    function getStakingModuleIsStopped(uint256 _stakingModuleId) external view
        validStakingModuleId(_stakingModuleId)
        returns (bool)
    {
        return getStakingModuleStatus(uint24(_stakingModuleId)) == StakingModuleStatus.Stopped;
    }

    function getStakingModuleIsDepositsPaused(uint256 _stakingModuleId) external view
        validStakingModuleId(_stakingModuleId)
        returns (bool)
    {
        return getStakingModuleStatus(uint24(_stakingModuleId)) == StakingModuleStatus.DepositsPaused;
    }

    function getStakingModuleIsActive(uint256 _stakingModuleId) external view
        validStakingModuleId(_stakingModuleId)
        returns (bool)
    {
        return getStakingModuleStatus(uint24(_stakingModuleId)) == StakingModuleStatus.Active;
    }

    function getStakingModuleKeysOpIndex(uint256 _stakingModuleId) external view
        validStakingModuleId(_stakingModuleId)
        returns (uint256)
    {
        return IStakingModule(_getStakingModuleAddressById(uint24(_stakingModuleId))).getValidatorsKeysNonce();
    }

    function getStakingModuleLastDepositBlock(uint256 _stakingModuleId) external view
        validStakingModuleId(_stakingModuleId)
        returns (uint256)
    {
        StakingModule storage stakingModule = _getStakingModuleById(uint24(_stakingModuleId));
        return stakingModule.lastDepositBlock;
    }

    function getStakingModuleActiveKeysCount(uint256 _stakingModuleId) external view
        validStakingModuleId(_stakingModuleId)
        returns (uint256 activeKeysCount)
    {
        (, activeKeysCount, ) = IStakingModule(_getStakingModuleAddressById(uint24(_stakingModuleId))).getValidatorsKeysStats();
    }

    /**
     * @dev calculate max count of depositable staking module keys based on the current Staking Router balance and buffered Ether amount
     *
     * @param _stakingModuleId id of the staking module to be deposited
     * @return max depositable keys count
     */
    function getStakingModuleMaxDepositableKeys(uint256 _stakingModuleId) public view
        validStakingModuleId(_stakingModuleId)
        returns (uint256)
    {
        uint256 stakingModuleIndex = _getStakingModuleIndexById(uint24(_stakingModuleId));
        uint256 _keysToAllocate = getLido().getBufferedEther() / DEPOSIT_SIZE;
        (, uint256[] memory newKeysAllocation, StakingModuleCache[] memory stakingModulesCache) = _getKeysAllocation(_keysToAllocate);
        return newKeysAllocation[stakingModuleIndex] - stakingModulesCache[stakingModuleIndex].activeKeysCount;
    }

    /**
     * @notice return shares table
     *
     * @return recipients recipients list
     * @return stakingModuleFees fee of each recipient
     * @return totalFee total fee to mint for each staking module and treasury
     */
    function getStakingRewardsDistribution()
        external
        view
        returns (address[] memory recipients, uint96[] memory stakingModuleFees, uint96 totalFee, uint256 precisionPoints)
    {
        (uint256 totalActiveKeys, StakingModuleCache[] memory stakingModuleCache) = _loadStakingModulesCache();
        uint256 stakingModulesCount = stakingModuleCache.length;

        /// @dev return empty response if there are no staking modules or active keys yet
        if (stakingModulesCount == 0 || totalActiveKeys == 0) {
            return (new address[](0), new uint96[](0), 0, FEE_PRECISION_POINTS);
        }

        precisionPoints = FEE_PRECISION_POINTS;
        recipients = new address[](stakingModulesCount);
        stakingModuleFees = new uint96[](stakingModulesCount);

        uint256 rewardedStakingModulesCount = 0;
        uint256 stakingModuleKeysShare;
        uint96 stakingModuleFee;

        for (uint256 i; i < stakingModulesCount; ) {
            /// @dev skip staking modules which have no active keys
            if (stakingModuleCache[i].activeKeysCount > 0) {
                stakingModuleKeysShare = ((stakingModuleCache[i].activeKeysCount * precisionPoints) / totalActiveKeys);

                recipients[rewardedStakingModulesCount] = address(stakingModuleCache[i].stakingModuleAddress);
                stakingModuleFee = uint96((stakingModuleKeysShare * stakingModuleCache[i].stakingModuleFee) / TOTAL_BASIS_POINTS);
                /// @dev if the staking module has the `Stopped` status for some reason, then
                ///      the staking module's rewards go to the treasure, so that the DAO has ability
                ///      to manage them (e.g. to compensate the staking module in case of an error, etc.)
                if (stakingModuleCache[i].status != StakingModuleStatus.Stopped) {
                    stakingModuleFees[rewardedStakingModulesCount] = stakingModuleFee;
                }
                // else keep stakingModuleFees[rewardedStakingModulesCount] = 0, but increase totalFee

                totalFee += (uint96((stakingModuleKeysShare * stakingModuleCache[i].treasuryFee) / TOTAL_BASIS_POINTS) + stakingModuleFee);

                unchecked {
                    rewardedStakingModulesCount++;
                }
            }
            unchecked {
                ++i;
            }
        }

        // sanity check
        if (totalFee >= precisionPoints) revert ErrorValueOver100Percent("totalFee");

        /// @dev shrink arrays
        if (rewardedStakingModulesCount < stakingModulesCount) {
            uint256 trim = stakingModulesCount - rewardedStakingModulesCount;
            assembly {
                mstore(recipients, sub(mload(recipients), trim))
                mstore(stakingModuleFees, sub(mload(stakingModuleFees), trim))
            }
        }
    }

    /// @notice returns new deposits allocation after the distribution of the `_keysToAllocate` keys
    function getKeysAllocation(uint256 _keysToAllocate) external view returns (uint256 allocated, uint256[] memory allocations) {
        (allocated, allocations, ) = _getKeysAllocation(_keysToAllocate);
    }

    /**
     * @dev Invokes a deposit call to the official Deposit contract
     * @param _maxDepositsCount max deposits count
     * @param _stakingModuleId id of the staking module to be deposited
     * @param _depositCalldata staking module calldata
     */
    function deposit(
        uint256 _maxDepositsCount,
        uint256 _stakingModuleId,
        bytes calldata _depositCalldata
    ) external payable validStakingModuleId(_stakingModuleId)  returns (uint256 keysCount) {
        if (msg.sender != LIDO_POSITION.getStorageAddress()) revert ErrorAppAuthLidoFailed();

        uint256 depositableEth = msg.value;
        if (depositableEth == 0) {
            _transferBalanceEthToLido();
            return 0;
        }

        bytes32 withdrawalCredentials = getWithdrawalCredentials();
        if (withdrawalCredentials == 0) revert ErrorEmptyWithdrawalsCredentials();

        uint256 stakingModuleIndex = _getStakingModuleIndexById(uint24(_stakingModuleId));
        StakingModule storage stakingModule = _getStakingModuleByIndex(stakingModuleIndex);
        if (StakingModuleStatus(stakingModule.status) != StakingModuleStatus.Active) revert ErrorStakingModuleNotActive();

        uint256 maxDepositableKeys = getStakingModuleMaxDepositableKeys(_stakingModuleId);
        uint256 keysToDeposit = Math.min(maxDepositableKeys, _maxDepositsCount);

        if (keysToDeposit > 0) {
            bytes memory publicKeysBatch;
            bytes memory signaturesBatch;
            (keysCount, publicKeysBatch, signaturesBatch) = IStakingModule(stakingModule.stakingModuleAddress)
                .requestValidatorsKeysForDeposits(keysToDeposit, _depositCalldata);

            if (keysCount > 0) {
                _makeBeaconChainDeposits32ETH(keysCount, abi.encodePacked(withdrawalCredentials), publicKeysBatch, signaturesBatch);

                stakingModule.lastDepositAt = uint64(block.timestamp);
                stakingModule.lastDepositBlock = block.number;

                emit StakingRouterETHDeposited(uint24(_stakingModuleId), keysCount * DEPOSIT_SIZE);
            }
        }
        _transferBalanceEthToLido();
        // return keysCount;
    }

    /// @dev transfer all remaining balance to Lido contract
    function _transferBalanceEthToLido() internal {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            getLido().receiveStakingRouter{value: balance}();
        }
    }

    /**
     * @notice Set credentials to withdraw ETH on Consensus Layer side after the phase 2 is launched to `_withdrawalCredentials`
     * @dev Note that setWithdrawalCredentials discards all unused signing keys as the signatures are invalidated.
     * @param _withdrawalCredentials withdrawal credentials field as defined in the Ethereum PoS consensus specs
     */
    function setWithdrawalCredentials(bytes32 _withdrawalCredentials) external onlyRole(MANAGE_WITHDRAWAL_CREDENTIALS_ROLE) {
        WITHDRAWAL_CREDENTIALS_POSITION.setStorageBytes32(_withdrawalCredentials);

        //trim keys with old WC
        _trimUnusedKeys();

        emit WithdrawalCredentialsSet(_withdrawalCredentials, msg.sender);
    }

    /**
     * @notice Returns current credentials to withdraw ETH on Consensus Layer side after the phase 2 is launched
     */
    function getWithdrawalCredentials() public view returns (bytes32) {
        return WITHDRAWAL_CREDENTIALS_POSITION.getStorageBytes32();
    }

    function _trimUnusedKeys() internal {
        uint256 stakingModulesCount = getStakingModulesCount();
        for (uint256 i; i < stakingModulesCount; ) {
            IStakingModule(_getStakingModuleAddressByIndex(i)).invalidateReadyToDepositKeys();
            unchecked {
                ++i;
            }
        }
    }

    function _readStakingModuleCache(uint256 _stakingModuleIndex) internal view returns (StakingModuleCache memory stakingModuleCache) {
        StakingModule storage stakingModuleData = _getStakingModuleByIndex(_stakingModuleIndex);
        stakingModuleCache.stakingModuleAddress = stakingModuleData.stakingModuleAddress;
        stakingModuleCache.stakingModuleFee = stakingModuleData.stakingModuleFee;
        stakingModuleCache.treasuryFee = stakingModuleData.treasuryFee;
        stakingModuleCache.targetShare = stakingModuleData.targetShare;
        stakingModuleCache.status = StakingModuleStatus(stakingModuleData.status);
    }

    /**
     * @dev load all staking modules list
     * @notice used for reward distribution
     * @return totalActiveKeys for not stopped staking modules
     * @return stakingModuleCache array of StakingModuleCache struct
     */
    function _loadStakingModulesCache() internal view returns (uint256 totalActiveKeys, StakingModuleCache[] memory stakingModuleCache) {
        uint256 stakingModulesCount = getStakingModulesCount();
        stakingModuleCache = new StakingModuleCache[](stakingModulesCount);
        for (uint256 i; i < stakingModulesCount; ) {
            stakingModuleCache[i] = _readStakingModuleCache(i);
            (, stakingModuleCache[i].activeKeysCount, stakingModuleCache[i].availableKeysCount) = IStakingModule(stakingModuleCache[i].stakingModuleAddress)
                .getValidatorsKeysStats();
            totalActiveKeys += stakingModuleCache[i].activeKeysCount;
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @dev load active staking modules list
     * @notice used for deposits allocation
     * @return totalActiveKeys for active staking modules
     * @return stakingModuleCache array of StakingModuleCache struct
     */
    function _loadActiveStakingModulesCache() internal view returns (uint256 totalActiveKeys, StakingModuleCache[] memory stakingModuleCache) {
        uint256 stakingModulesCount = getStakingModulesCount();
        stakingModuleCache = new StakingModuleCache[](stakingModulesCount);

        for (uint256 i; i < stakingModulesCount; ) {
            stakingModuleCache[i] = _readStakingModuleCache(i);

            /// @dev account only keys from active staking modules
            if (stakingModuleCache[i].status == StakingModuleStatus.Active) {
                (, stakingModuleCache[i].activeKeysCount, stakingModuleCache[i].availableKeysCount) = IStakingModule(
                    stakingModuleCache[i].stakingModuleAddress
                ).getValidatorsKeysStats();
                totalActiveKeys += stakingModuleCache[i].activeKeysCount;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _getKeysAllocation(
        uint256 _keysToAllocate
    ) internal view returns (uint256 allocated, uint256[] memory allocations, StakingModuleCache[] memory stakingModuleCache) {
        // calculate total used keys for operators
        uint256 totalActiveKeys;

        (totalActiveKeys, stakingModuleCache) = _loadActiveStakingModulesCache();

        uint256 stakingModulesCount = stakingModuleCache.length;
        allocations = new uint256[](stakingModulesCount);
        if (stakingModulesCount > 0) {
            /// @dev new estimated active keys count
            totalActiveKeys += _keysToAllocate;
            uint256[] memory capacities = new uint256[](stakingModulesCount);
            uint256 targetKeys;

            for (uint256 i; i < stakingModulesCount; ) {
                allocations[i] = stakingModuleCache[i].activeKeysCount;
                targetKeys = (stakingModuleCache[i].targetShare * totalActiveKeys) / TOTAL_BASIS_POINTS;
                capacities[i] = Math.min(targetKeys, stakingModuleCache[i].activeKeysCount + stakingModuleCache[i].availableKeysCount);
                unchecked {
                    ++i;
                }
            }

            allocated = MinFirstAllocationStrategy.allocate(allocations, capacities, _keysToAllocate);
        }
    }

    function _getStakingModuleIndexById(uint24 _stakingModuleId) internal view returns (uint256) {
        mapping(uint24 => uint256) storage _stakingModuleIndicesOneBased = _getStorageStakingIndicesMapping();
        uint256 indexOneBased = _stakingModuleIndicesOneBased[_stakingModuleId];
        if (indexOneBased == 0) revert ErrorStakingModuleUnregistered();
        return indexOneBased - 1;
    }

    function _setStakingModuleIndexById(uint24 _stakingModuleId, uint256 _stakingModuleIndex) internal {
        mapping(uint24 => uint256) storage _stakingModuleIndicesOneBased = _getStorageStakingIndicesMapping();
        _stakingModuleIndicesOneBased[_stakingModuleId] = _stakingModuleIndex + 1;
    }

    function _getStakingModuleIdByIndex(uint256 _stakingModuleIndex) internal view returns (uint24) {
        return _getStakingModuleByIndex(_stakingModuleIndex).id;
    }

    function _getStakingModuleById(uint24 _stakingModuleId) internal view returns (StakingModule storage) {
        return _getStakingModuleByIndex(_getStakingModuleIndexById(_stakingModuleId));
    }

    function _getStakingModuleByIndex(uint256 _stakingModuleIndex) internal view returns (StakingModule storage) {
        mapping(uint256 => StakingModule) storage _stakingModules = _getStorageStakingModulesMapping();
        return _stakingModules[_stakingModuleIndex];
    }

    function _getStakingModuleAddressById(uint24 _stakingModuleId) internal view returns (address) {
        return _getStakingModuleById(_stakingModuleId).stakingModuleAddress;
    }

    function _getStakingModuleAddressByIndex(uint256 _stakingModuleIndex) internal view returns (address) {
        return _getStakingModuleByIndex(_stakingModuleIndex).stakingModuleAddress;
    }

    function _setContractVersion(uint256 version) internal {
        CONTRACT_VERSION_POSITION.setStorageUint256(version);
        emit ContractVersionSet(version);
    }

    /// @notice Return the initialized version of this contract starting from 0
    function getVersion() external view returns (uint256) {
        return CONTRACT_VERSION_POSITION.getStorageUint256();
    }

    function _getStorageStakingModulesMapping() internal pure returns (mapping(uint256 => StakingModule) storage result) {
        bytes32 position = STAKING_MODULES_MAPPING_POSITION;
        assembly {
            result.slot := position
        }
    }

    function _getStorageStakingIndicesMapping() internal pure returns (mapping(uint24 => uint256) storage result) {
        bytes32 position = STAKING_MODULE_INDICES_MAPPING_POSITION;
        assembly {
            result.slot := position
        }
    }
}
