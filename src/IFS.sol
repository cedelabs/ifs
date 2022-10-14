// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// KeeperCompatible.sol imports the functions from both ./KeeperBase.sol and
// ./interfaces/KeeperCompatibleInterface.sol
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@chainlink/contracts/src/v0.8/KeeperCompatible.sol";
import "aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import "aave-v3-core/interfaces/IPool.sol";

contract IFS is KeeperCompatibleInterface {

    event KeeperTransferred(address indexed pool, address indexed investor, uint256 indexed transferAmount, uint256 timestamp);
    event PendingTxAdded(address indexed pool, address indexed investor, uint256 indexed transferAmount, uint256 timestamp);

    struct Investment {
        address pool;
        address token;
        uint256 amount;
        uint256 timestamp; // timestamp of when the investor was added to the pool
        State status;
    }

    enum State { transferPending, transferExecuted}

    address public owner;
    address public poolAddressesProvider;

    mapping(address => Investment[]) investments;
    address[] users;

    constructor(address _owner, address _poolAddressesProvider) {
        owner = _owner;
        poolAddressesProvider = _poolAddressesProvider;
    }

    function addPendingTx(address _pool, address _token, uint256 _amount) public {
        Investment memory investment = Investment(_pool, _token, _amount, block.timestamp, State.transferPending);
        investments[msg.sender].push(investment);
        users.push(msg.sender);
        emit PendingTxAdded(_pool, msg.sender, _amount, block.timestamp);
    }

    // TODO add time limits on every user
    function checkUpkeep(bytes calldata) public override view returns (bool upkeepNeeded, bytes memory performData) {
        for (uint i=0; i<users.length; i++) {
            for (uint j = 0; j < investments[users[i]].length; j++) {
                Investment storage investment = investments[users[i]][j];
                if (investment.status == State.transferPending) {
                    // check balance && allowance
                    if (ERC20(investment.token).balanceOf(users[i]) > 0 ||
                        ERC20(investment.token).allowance(users[i], address(this)) > 0) {
                        return (true, abi.encode(investment.pool, users[i], investment.token, investment.amount));
                    }
                }
            }
        }
        return (false, "");
    }

    function performUpkeep(bytes calldata performData) external override {
        (address pool, address investor, address token, uint256 amount) = abi.decode(performData, (address, address, address, uint));
        supplyAave(pool, investor, token, amount);
    }

    function supplyAave(address _pool, address _investor, address _token, uint256 _amount) internal {
        for (uint i = 0; i < investments[_investor].length; i++) {
            Investment storage investment = investments[_investor][i];
            if (investment.pool == _pool && investment.token == _token && investment.amount == _amount) {
                investment.status = State.transferExecuted;

                ERC20(_token).transferFrom(_investor, address(this), _amount);

                // https://docs.aave.com/developers/deployed-contracts/v3-testnet-addresses
                IPoolAddressesProvider provider = IPoolAddressesProvider(address(poolAddressesProvider));
                IPool lendingPool = IPool(provider.getPool());
                ERC20(_token).approve(provider.getPool(), _amount);

                uint16 referral = 0;
                lendingPool.supply(_token, _amount, _investor, referral);

                emit KeeperTransferred(provider.getPool(), _investor, _amount, block.timestamp);
                break;
            }
        }
    }
}

