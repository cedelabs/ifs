// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "@openzeppelin/interfaces/IERC20.sol";
import "@openzeppelin/utils/structs/DoubleEndedQueue.sol";
import "@chainlink/KeeperCompatible.sol";
import "@aave-v3/interfaces/IPoolAddressesProvider.sol";
import "@aave-v3/interfaces/IPool.sol";

error ForwardPerUserLimitReached(uint16 maxForwards);

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
        State status;
    }

    enum State {
        transferPending,
        transferExecuted
    }

    uint16 public constant MAX_FORWARDS_PER_BATCH = 100; // TODO calculate precisely
    uint16 public constant MAX_FORWARDS_PER_USER = 100; // TODO calculate precisely

    address public owner;
    address public poolAddressesProvider;

    mapping(address => Forward[]) forwardsByAddress;
    address[] users;

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    constructor(address _owner, address _poolAddressesProvider) {
        owner = _owner;
        poolAddressesProvider = _poolAddressesProvider;
    }

    function addPendingForward(
        address _pool,
        address _token,
        uint256 _amount
    ) public {
        if (forwardsByAddress[msg.sender].length >= MAX_FORWARDS_PER_USER)
            revert ForwardPerUserLimitReached({
                maxForwards: MAX_FORWARDS_PER_USER
            });

        Forward memory forward = Forward(
            _pool,
            _token,
            _amount,
            block.timestamp,
            State.transferPending
        );
        forwardsByAddress[msg.sender].push(forward);
        users.push(msg.sender);
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
        for (uint256 i = 0; i < users.length; i++) {
            for (uint256 j = 0; j < forwardsByAddress[users[i]].length; j++) {
                Forward storage forward = forwardsByAddress[users[i]][j];
                if (forward.status == State.transferPending) {
                    // check balance && allowance
                    if (
                        IERC20(forward.token).balanceOf(users[i]) >=
                        forward.amount ||
                        IERC20(forward.token).allowance(
                            users[i],
                            address(this)
                        ) >=
                        forward.amount
                    ) {
                        return (
                            true,
                            abi.encode(
                                forward.pool,
                                users[i],
                                forward.token,
                                forward.amount
                            )
                        );
                    }
                }
            }
        }
        return (false, "");
    }

    function performUpkeep(bytes calldata performData) external override {
        (address pool, address investor, address token, uint256 amount) = abi
            .decode(performData, (address, address, address, uint256));
        supplyAave(pool, investor, token, amount);
    }

    function supplyAave(
        address _pool,
        address _investor,
        address _token,
        uint256 _amount
    ) internal {
        for (uint256 i = 0; i < forwardsByAddress[_investor].length; i++) {
            Forward storage forward = forwardsByAddress[_investor][i];
            if (
                forward.pool == _pool &&
                forward.token == _token &&
                forward.amount == _amount
            ) {
                forward.status = State.transferExecuted;

                IERC20(_token).transferFrom(_investor, address(this), _amount);

                // https://docs.aave.com/developers/deployed-contracts/v3-testnet-addresses
                IPoolAddressesProvider provider = IPoolAddressesProvider(
                    address(poolAddressesProvider)
                );
                IPool lendingPool = IPool(provider.getPool());
                IERC20(_token).approve(provider.getPool(), _amount);

                uint16 referral = 0;
                lendingPool.supply(_token, _amount, _investor, referral);

                emit ForwardExecuted(
                    provider.getPool(),
                    _investor,
                    _amount,
                    block.timestamp
                );
                break;
            }
        }
    }

    // function cleanExpiredForwards() internal onlyOwner {

    //     uint256 memory indexesToRemove = [];

    //     for (uint256 i = 0; i < users.length; i++) {
    //         for (uint256 j = 0; j < forwardsByAddress[users[i]].length; j++) {
    //             Forward storage forward = forwardsByAddress[users[i]][j];
    //             if (forward.status == State.transferExecuted) {
    //                 indexesToRemove =
    //             }
    //         }
    //     }
    // }
}
