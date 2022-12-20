// SPDX-FileCopyrightText: 2022 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.9;

interface IRestakingSink {
    function receiveRestake() external payable;
}

/**
 * @title A dedicated contract for handling stETH withdrawal request queue
 * @author folkyatina
 */
contract WithdrawalQueue {
    /**
     * @notice minimal possible sum that is possible to withdraw
     * We don't want to deal with small amounts because there is a gas spent on oracle
     * for each request.
     * But exact threshold should be defined later when it will be clear how much will
     * it cost to withdraw.
     */
    uint256 public constant MIN_WITHDRAWAL = 0.1 ether;

    /**
     * @notice All state-modifying calls are allowed only from owner protocol.
     * @dev should be Lido
     */
    address payable public immutable OWNER;

    /**
     * @notice amount of ETH on this contract balance that is locked for withdrawal and waiting for claim
     * @dev Invariant: `lockedEtherAmount <= this.balance`
     */
    uint128 public lockedEtherAmount = 0;

    /// @notice queue for withdrawal requests
    Request[] public queue;

    /// @notice length of the finalized part of the queue
    uint256 public finalizedRequestsCounter = 0;

    /// @notice structure representing a request for withdrawal.
    struct Request {
        /// @notice sum of the all requested ether including this request
        uint128 cumulativeEther;
        /// @notice sum of the all shares locked for withdrawal including this request
        uint128 cumulativeShares;
        /// @notice payable address of the recipient withdrawal will be transferred to
        address payable recipient;
        /// @notice block.number when the request created
        uint64 requestBlockNumber;
        /// @notice flag if the request was already claimed
        bool claimed;
    }

    /// @notice finalization price history registry
    Price[] public finalizationPrices;

    /**
     * @notice structure representing share price for some range in request queue
     * @dev price is stored as a pair of value that should be divided later
     */
    struct Price {
        uint128 totalPooledEther;
        uint128 totalShares;
        /// @notice last index in queue this price is actual for
        uint256 index;
    }

    /**
     * @param _owner address that will be able to invoke `enqueue` and `finalize` methods.
     */
    constructor(address payable _owner) {
        require(_owner  != address(0), "ZERO_OWNER");
        OWNER = _owner;
    }

    /**
     * @notice Getter for withdrawal queue length
     * @return length of the request queue
     */
    function queueLength() external view returns (uint256) {
        return queue.length;
    }

    /**
     * @notice put a withdrawal request in a queue and associate it with `_recipient` address
     * @dev Assumes that `_ethAmount` of stETH is locked before invoking this function
     * @param _recipient payable address this request will be associated with
     * @param _etherAmount maximum amount of ether (equal to amount of locked stETH) that will be claimed upon withdrawal
     * @param _sharesAmount amount of stETH shares that will be burned upon withdrawal
     * @return requestId unique id to claim funds once it is available
     */
    function enqueue(
        address payable _recipient,
        uint256 _etherAmount,
        uint256 _sharesAmount
    ) external onlyOwner returns (uint256 requestId) {
        require(_etherAmount > MIN_WITHDRAWAL, "WITHDRAWAL_IS_TOO_SMALL");
        requestId = queue.length;

        uint128 cumulativeEther = _toUint128(_etherAmount);
        uint128 cumulativeShares = _toUint128(_sharesAmount);

        if (requestId > 0) {
            cumulativeEther += queue[requestId - 1].cumulativeEther;
            cumulativeShares += queue[requestId - 1].cumulativeShares;
        }

        queue.push(Request(
            cumulativeEther,
            cumulativeShares,
            _recipient,
            _toUint64(block.number),
            false
        ));
    }

    /**
     * @notice Finalize the batch of requests started at `finalizedRequestsCounter` and ended at `_lastIdToFinalize` using the given price
     * @param _lastIdToFinalize request index in the queue that will be last finalized request in a batch
     * @param _etherToLock ether that should be locked for these requests
     * @param _totalPooledEther ether price component that will be used for this request batch finalization
     * @param _totalShares shares price component that will be used for this request batch finalization
     */
    function finalize(
        uint256 _lastIdToFinalize,
        uint256 _etherToLock,
        uint256 _totalPooledEther,
        uint256 _totalShares
    ) external payable onlyOwner {
        require(
            _lastIdToFinalize >= finalizedRequestsCounter && _lastIdToFinalize < queue.length,
            "INVALID_FINALIZATION_ID"
        );
        require(lockedEtherAmount + _etherToLock <= address(this).balance, "NOT_ENOUGH_ETHER");

        _updatePriceHistory(_toUint128(_totalPooledEther), _toUint128(_totalShares), _lastIdToFinalize);

        lockedEtherAmount = _toUint128(_etherToLock);
        finalizedRequestsCounter = _lastIdToFinalize + 1;
    }

    /**
     * @notice Mark `_requestId` request as claimed and transfer reserved ether to recipient
     * @param _requestId request id to claim
     * @param _priceIndexHint price index found offchain that should be used for claiming
     */
    function claim(uint256 _requestId, uint256 _priceIndexHint) external returns (address recipient) {
        // request must be finalized
        require(finalizedRequestsCounter > _requestId, "REQUEST_NOT_FINALIZED");

        Request storage request = queue[_requestId];
        require(!request.claimed, "REQUEST_ALREADY_CLAIMED");

        request.claimed = true;

        Price memory price;

        if (_isPriceHintValid(_requestId, _priceIndexHint)) {
            price = finalizationPrices[_priceIndexHint];
        } else {
            // unbounded loop branch. Can fail
            price = finalizationPrices[findPriceHint(_requestId)];
        }

        (uint128 etherToTransfer,) = _calculateDiscountedBatch(
            _requestId,
            _requestId,
            price.totalPooledEther,
            price.totalShares
            );
        lockedEtherAmount -= etherToTransfer;

        _sendValue(request.recipient, etherToTransfer);

        return request.recipient;
    }

    /**
     * @notice calculates the params to fulfill the next batch of requests in queue
     * @param _lastIdToFinalize last id in the queue to finalize upon
     * @param _totalPooledEther share price component to finalize requests
     * @param _totalShares share price component to finalize requests
     *
     * @return etherToLock amount of eth required to finalize the batch
     * @return sharesToBurn amount of shares that should be burned on finalization
     */
    function calculateFinalizationParams(
        uint256 _lastIdToFinalize,
        uint256 _totalPooledEther,
        uint256 _totalShares
    ) external view returns (uint256 etherToLock, uint256 sharesToBurn) {
        return _calculateDiscountedBatch(
            finalizedRequestsCounter,
            _lastIdToFinalize,
            _toUint128(_totalPooledEther),
            _toUint128(_totalShares)
        );
    }

    function findPriceHint(uint256 _requestId) public view returns (uint256 hint) {
        require(_requestId < finalizedRequestsCounter, "PRICE_NOT_FOUND");

        for (uint256 i = finalizationPrices.length; i > 0; i--) {
            if (_isPriceHintValid(_requestId, i - 1)){
                return i - 1;
            }
        }
        assert(false);
    }

    function restake(uint256 _amount) external onlyOwner {
        require(lockedEtherAmount + _amount <= address(this).balance, "NOT_ENOUGH_ETHER");

        IRestakingSink(OWNER).receiveRestake{value: _amount}();
    }

    function _calculateDiscountedBatch(
        uint256 firstId,
        uint256 lastId,
        uint128 _totalPooledEther,
        uint128 _totalShares
    ) internal view returns (uint128 eth, uint128 shares) {
        eth = queue[lastId].cumulativeEther;
        shares = queue[lastId].cumulativeShares;

        if (firstId > 0) {
            eth -= queue[firstId - 1].cumulativeEther;
            shares -= queue[firstId - 1].cumulativeShares;
        }

        eth = _min(eth, shares * _totalPooledEther / _totalShares);
    }

    function _isPriceHintValid(uint256 _requestId, uint256 hint) internal view returns (bool isInRange) {
        uint256 hintLastId = finalizationPrices[hint].index;

        isInRange = _requestId <= hintLastId;
        if (hint > 0) {
            uint256 previousId = finalizationPrices[hint - 1].index;

            isInRange = isInRange && previousId < _requestId;
        }
    }

    function _updatePriceHistory(uint128 _totalPooledEther, uint128 _totalShares, uint256 index) internal {
        if (finalizationPrices.length == 0) {
            finalizationPrices.push(Price(_totalPooledEther, _totalShares, index));
        } else {
            Price storage lastPrice = finalizationPrices[finalizationPrices.length - 1];

            if (_totalPooledEther/_totalShares == lastPrice.totalPooledEther/lastPrice.totalShares) {
                lastPrice.index = index;
            } else {
                finalizationPrices.push(Price(_totalPooledEther, _totalShares, index));
            }
        }
    }

    function _min(uint128 a, uint128 b) internal pure returns (uint128) {
        return a < b ? a : b;
    }

    function _sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        // solhint-disable-next-line
        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    function _toUint64(uint256 value) internal pure returns (uint64) {
        require(value <= type(uint64).max, "SafeCast: value doesn't fit in 96 bits");
        return uint64(value);
    }

    function _toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "SafeCast: value doesn't fit in 128 bits");
        return uint128(value);
    }

    modifier onlyOwner() {
        require(msg.sender == OWNER, "NOT_OWNER");
        _;
    }
}
