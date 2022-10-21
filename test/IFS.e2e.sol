// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/IFS.sol";
import "@openzeppelin/token/ERC20/IERC20.sol";
import "./Constants.sol";
import "./Utils.sol";

contract IFSTest is Test {
    IFS public ifs;

    function setUp() public {
        ifs = new IFS(msg.sender, Constants.aavePoolAddressesProvider);
    }

    /**
     * @dev This test is e2e. It tests the whole flow of the IFS contract.
     * Given 5 pending forwards and 2 users, it should:
     * - execute 2 forwards for the first user from 3 pending forwards
     * - and 1 for the second user from 2 pending forwards
     */
    function testExecutionMultipleForwards() public {
        uint256 withdrawnAmount = 10000000000;
        uint256 investedAmount = 100000000;

        address[] memory tokenAddresses = Utils.getTokens();
        address[] memory aTokenAddresses = Utils.getATokens();
        address[] memory cexAddresses = Utils.getCexAddresses();

        // first user 3 forwards
        vm.startPrank(Constants.defiUserAddress);
        for (uint256 i = 0; i < 3; i++) {
            IERC20(tokenAddresses[i]).approve(address(ifs), investedAmount);
            ifs.addPendingForward(
                Constants.aavePoolAddressesProvider,
                tokenAddresses[i],
                investedAmount
            );
        }
        vm.stopPrank();

        // second user 2 forwards
        vm.startPrank(Constants.defiUserAddress2);
        for (uint256 i = 3; i < 5; i++) {
            IERC20(tokenAddresses[i]).approve(address(ifs), investedAmount);
            ifs.addPendingForward(
                Constants.aavePoolAddressesProvider,
                tokenAddresses[i],
                investedAmount
            );
        }
        vm.stopPrank();

        // simulate 2 CEX withdrawals for the first user
        vm.prank(address(cexAddresses[0]));
        IERC20(tokenAddresses[0]).transfer(
            Constants.defiUserAddress,
            withdrawnAmount
        );
        vm.prank(address(cexAddresses[2]));
        IERC20(tokenAddresses[2]).transfer(
            Constants.defiUserAddress,
            withdrawnAmount
        );

        // simulate 1 CEX withdrawal for the second user
        vm.prank(address(cexAddresses[3]));
        IERC20(tokenAddresses[3]).transfer(
            Constants.defiUserAddress2,
            withdrawnAmount
        );

        // ensure that the job is pending
        (bool upkeepNeeded, bytes memory performData) = ifs.checkUpkeep("0x");
        assertEq(upkeepNeeded, true);

        uint16 fsHashesToExecuteCount = 3;
        uint16 fsHashesToPopCount = 0;
        bytes32[] memory fsHashesToExecute = new bytes32[](
            Constants.MAX_FORWARDS_PER_BATCH
        );
        fsHashesToExecute[0] = keccak256(
            abi.encode(
                Constants.aavePoolAddressesProvider,
                tokenAddresses[0],
                investedAmount,
                block.number,
                Constants.defiUserAddress
            )
        );
        fsHashesToExecute[1] = keccak256(
            abi.encode(
                Constants.aavePoolAddressesProvider,
                tokenAddresses[2],
                investedAmount,
                block.number,
                Constants.defiUserAddress
            )
        );
        fsHashesToExecute[2] = keccak256(
            abi.encode(
                Constants.aavePoolAddressesProvider,
                tokenAddresses[3],
                investedAmount,
                block.number,
                Constants.defiUserAddress2
            )
        );
        assertEq(
            performData,
            abi.encode(
                fsHashesToExecute,
                fsHashesToExecuteCount,
                new bytes32[](Constants.MAX_FORWARDS_PER_BATCH),
                fsHashesToPopCount
            )
        );

        // execute the pending job
        ifs.performUpkeep(performData);

        // ensure that the user has invested the funds
        assertEq(
            IERC20(aTokenAddresses[0]).balanceOf(Constants.defiUserAddress),
            investedAmount
        );
        assertEq(
            IERC20(aTokenAddresses[2]).balanceOf(Constants.defiUserAddress),
            investedAmount
        );
        assertEq(
            IERC20(aTokenAddresses[3]).balanceOf(Constants.defiUserAddress2),
            investedAmount
        );

        // check pending jobs, should be 0 left
        (upkeepNeeded, performData) = ifs.checkUpkeep("0x");
        assertEq(upkeepNeeded, false);

        // simulate 1 CEX withdrawal for the first user
        vm.prank(address(cexAddresses[1]));
        IERC20(tokenAddresses[1]).transfer(
            Constants.defiUserAddress,
            withdrawnAmount
        );

        // cancel the last forward for the second user
        vm.prank(Constants.defiUserAddress2);
        ifs.cancelPendingForward(
            keccak256(
                abi.encode(
                    Constants.aavePoolAddressesProvider,
                    tokenAddresses[4],
                    investedAmount,
                    block.number,
                    Constants.defiUserAddress2
                )
            )
        );

        // check pending jobs, should be 2 left
        (upkeepNeeded, performData) = ifs.checkUpkeep("0x");
        assertEq(upkeepNeeded, true);

        fsHashesToExecuteCount = 1;
        fsHashesToPopCount = 1;
        fsHashesToExecute = new bytes32[](Constants.MAX_FORWARDS_PER_BATCH);
        fsHashesToExecute[0] = keccak256(
            abi.encode(
                Constants.aavePoolAddressesProvider,
                tokenAddresses[1],
                investedAmount,
                block.number,
                Constants.defiUserAddress
            )
        );
        bytes32[] memory fsHashesToPop = new bytes32[](
            Constants.MAX_FORWARDS_PER_BATCH
        );
        fsHashesToPop[0] = keccak256(
            abi.encode(
                Constants.aavePoolAddressesProvider,
                tokenAddresses[4],
                investedAmount,
                block.number,
                Constants.defiUserAddress2
            )
        );
    }

    function getExpectedForwards() public view returns (IFS.Forward[] memory) {
        IFS.Forward[] memory expectedForwards = new IFS.Forward[](5);
        address[] memory tokens = Utils.getTokens();

        for (uint256 i = 0; i < 5; i++) {
            expectedForwards[i] = IFS.Forward(
                Constants.aavePoolAddressesProvider,
                tokens[i],
                10000,
                block.number,
                IFS.State.forwardPending,
                Constants.defiUserAddress
            );
        }

        return expectedForwards;
    }
}
