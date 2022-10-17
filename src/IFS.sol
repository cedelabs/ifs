// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/interfaces/IERC20.sol";
import "@openzeppelin/utils/structs/DoubleEndedQueue.sol";
import "@chainlink/KeeperCompatible.sol";
import "@aave-v3/interfaces/IPoolAddressesProvider.sol";
import "@aave-v3/interfaces/IPool.sol";

error ForwardPerUserLimitReached(uint16 maxForwards);
error ForwardDoesNotExist();
error PoolNotWhitelisted(address pool);

contract IFS is KeeperCompatibleInterface {
    event ForwardExecuted(
        address indexed pool,
        address indexed investor,
        uint256 indexed transferAmount,
        uint256 timestamp
    );

    event PendingForwardAdded(
        address indexed pool,
        address indexed investor,
        uint256 indexed transferAmount,
        uint256 timestamp
    );

    struct Forward {
        address pool;
        address token;
        uint256 amount;
        uint256 timestamp; // timestamp of when the investor was added to the pool
        State state;
        address owner;
    }

    /**
     * @dev canceledByUser state allows to tag forward as canceled, to avoid its execution when DoubleEndedQueue is being processed.
     */
    enum State {
        transferPending,
        canceledByUser
    }

    uint16 public constant MAX_FORWARDS_PER_BATCH = 100; // TODO calculate precisely
    uint16 public constant MAX_FORWARDS_PER_USER = 100; // TODO calculate precisely
    uint16 public constant FORWARD_EXPIRY_TIME = 100; // 20 min approximately

    DoubleEndedQueue.Bytes32Deque fsHashesQueue;
    mapping(bytes32 => Forward) forwardByHash;
    mapping(address => uint16) forwardsCountByUser;

    address public owner;
    mapping(address => bool) public isPoolWhitelisted;
    address public poolAddressesProvider;

    modifier onlyAdmin() {
        require(msg.sender == owner);
        _;
    }

    constructor(address _owner, address _poolAddressesProvider) {
        owner = _owner;
        isPoolWhitelisted[_poolAddressesProvider] = true;
    }

    function addPendingForward(
        address _pool,
        address _token,
        uint256 _amount
    ) public {
        if (forwardsCountByUser[msg.sender] >= MAX_FORWARDS_PER_USER)
            revert ForwardPerUserLimitReached({
                maxForwards: MAX_FORWARDS_PER_USER
            });

        if (!isPoolWhitelisted[_pool]) revert PoolNotWhitelisted({pool: _pool});

        Forward memory forward = Forward(
            _pool,
            _token,
            _amount,
            block.number,
            State.transferPending,
            msg.sender
        );

        bytes32 fsHash = keccak256(
            abi.encodePacked(_pool, _token, _amount, block.number, msg.sender)
        );
        forwardByHash[fsHash] = forward;
        DoubleEndedQueue.pushBack(fsHashesQueue, fsHash);
        forwardsCountByUser[msg.sender] += 1;
        emit PendingForwardAdded(_pool, msg.sender, _amount, block.timestamp);
    }

    // TODO add time limits on every user
    // unbounded loop is used only for this view function
    function checkUpkeep(bytes calldata)
        public
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // deque indexes to execute
        bytes32[] memory fsHashesToExecute = new bytes32[](
            MAX_FORWARDS_PER_BATCH
        );
        uint16 fsHashesToExecuteCount = 0;
        // deque indexes to delete
        bytes32[] memory fsHashesToPop = new bytes32[](MAX_FORWARDS_PER_BATCH);
        uint16 fsHashesToPopCount = 0;

        for (uint256 i = 0; i < DoubleEndedQueue.length(fsHashesQueue); i++) {
            // first decode
            bytes32 fHash = DoubleEndedQueue.at(fsHashesQueue, i);
            // memory or storage?
            Forward memory forward = forwardByHash[fHash];

            if (forward.state == State.transferPending) {
                // check balance && allowance
                if (
                    IERC20(forward.token).balanceOf(forward.owner) >=
                    forward.amount ||
                    IERC20(forward.token).allowance(
                        forward.owner,
                        address(this)
                    ) >=
                    forward.amount
                ) {
                    fsHashesToExecute[fsHashesToExecuteCount] = fHash;
                    fsHashesToExecuteCount++;
                }

                // check expiration
                if (block.number - forward.timestamp > FORWARD_EXPIRY_TIME) {
                    fsHashesToPop[fsHashesToPopCount] = fHash;
                    fsHashesToPopCount++;
                }
            } else if (forward.state == State.canceledByUser) {
                fsHashesToPop[fsHashesToPopCount] = fHash;
                fsHashesToPopCount++;
            }
        }

        if (fsHashesToExecute.length > 0 || fsHashesToPop.length > 0) {
            upkeepNeeded = true;
            performData = abi.encode(fsHashesToExecute, fsHashesToPop);
        } else {
            upkeepNeeded = false;
            performData = "";
        }
        return (upkeepNeeded, performData);
    }

    function cancelForward(bytes32 fsHashToCancel) public {
        if (forwardByHash[fsHashToCancel].timestamp == 0)
            revert ForwardDoesNotExist();

        forwardByHash[fsHashToCancel].state = State.canceledByUser;
    }

    function performUpkeep(bytes calldata performData) external override {
        (
            bytes32[] memory fsHashesToExecute,
            bytes32[] memory fsHashesToPop
        ) = abi.decode(performData, (bytes32[], bytes32[]));

        // execute forwards
        for (uint256 i = 0; i < fsHashesToExecute.length; i++) {
            Forward memory forward = forwardByHash[fsHashesToExecute[i]];
            supplyAave(
                forward.pool,
                forward.owner,
                forward.token,
                forward.amount
            );
            delete forwardByHash[fsHashesToExecute[i]];
            forwardsCountByUser[forward.owner] -= 1;
        }

        // delete from mapping
        for (uint256 i = 0; i < fsHashesToPop.length; i++) {
            forwardsCountByUser[forwardByHash[fsHashesToPop[i]].owner] -= 1;
            delete forwardByHash[fsHashesToPop[i]];
        }

        // clean fifo as far as possible
        while (
            DoubleEndedQueue.length(fsHashesQueue) > 0 &&
            forwardByHash[DoubleEndedQueue.front(fsHashesQueue)].state !=
            State.transferPending
        ) {
            DoubleEndedQueue.popFront(fsHashesQueue);
        }
    }

    function supplyAave(
        address _poolAddressesProvider,
        address _owner,
        address _token,
        uint256 _amount
    ) internal {
        IERC20(_token).transferFrom(_owner, address(this), _amount);

        // https://docs.aave.com/developers/deployed-contracts/v3-testnet-addresses
        IPoolAddressesProvider provider = IPoolAddressesProvider(
            address(_poolAddressesProvider)
        );
        IPool lendingPool = IPool(provider.getPool());
        IERC20(_token).approve(provider.getPool(), _amount);

        uint16 referral = 0;
        lendingPool.supply(_token, _amount, _owner, referral);

        emit ForwardExecuted(
            provider.getPool(),
            _owner,
            _amount,
            block.timestamp
        );
    }
}
