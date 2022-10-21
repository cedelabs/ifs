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

    function testUpkeepBeforeAnyJob() public {
        (bool upkeepNeeded, bytes memory performData) = ifs.checkUpkeep("0x");
        assertEq(upkeepNeeded, false);
        assertEq(performData, "");
    }

    function testUpkeepWithoutArrivedFunds() public {
        vm.prank(Constants.defiUserAddress);
        ifs.addPendingForward(
            Constants.aavePoolAddressesProvider,
            Constants.usdcAddress,
            10000
        );
        (bool upkeepNeeded, bytes memory performData) = ifs.checkUpkeep("0x");
        assertEq(upkeepNeeded, false);
        assertEq(performData, "");
    }

    // TODO test maximum forwards per user revert

    function testGetUserForwards() public {
        vm.startPrank(Constants.defiUserAddress);
        ifs.addPendingForward(
            Constants.aavePoolAddressesProvider,
            Constants.usdcAddress,
            10000
        );
        (IFS.Forward[] memory forwards, uint16 forwardsCount) = ifs
            .getUserForwards();
        vm.stopPrank();

        assertEq(forwardsCount, 1);
        IFS.Forward memory expectedForward = IFS.Forward(
            Constants.aavePoolAddressesProvider,
            Constants.usdcAddress,
            10000,
            block.number,
            IFS.State.forwardPending,
            Constants.defiUserAddress
        );

        // In order to compare structs, we need to convert them to bytes
        assertEq(
            abi.encode(expectedForward.owner),
            abi.encode(forwards[0].owner)
        );
    }

    function testGetUserMultipleForwards() public {
        vm.startPrank(Constants.defiUserAddress);
        ifs.addPendingForward(
            Constants.aavePoolAddressesProvider,
            Constants.usdcAddress,
            10000
        );
        ifs.addPendingForward(
            Constants.aavePoolAddressesProvider,
            Constants.sushiAddress,
            10000
        );
        ifs.addPendingForward(
            Constants.aavePoolAddressesProvider,
            Constants.daiAddress,
            10000
        );
        ifs.addPendingForward(
            Constants.aavePoolAddressesProvider,
            Constants.jEurAddress,
            10000
        );
        ifs.addPendingForward(
            Constants.aavePoolAddressesProvider,
            Constants.aaveAddress,
            10000
        );

        (IFS.Forward[] memory forwards, uint16 forwardsCount) = ifs
            .getUserForwards();
        vm.stopPrank();

        assertEq(forwardsCount, 5);
        IFS.Forward[] memory expectedForwards = this.getExpectedForwards();

        for (uint256 i = 0; i < forwardsCount; i++) {
            assertEq(
                // In order to compare structs, we need to convert them to bytes
                abi.encode(expectedForwards[i]),
                abi.encode(forwards[i])
            );
        }
    }

    function testExecution() public {
        uint256 withdrawnAmount = 10000000000;
        uint256 investedAmount = 100000000;

        // user actions
        vm.startPrank(Constants.defiUserAddress);
        IERC20(Constants.usdcAddress).approve(address(ifs), investedAmount);
        ifs.addPendingForward(
            Constants.aavePoolAddressesProvider,
            Constants.usdcAddress,
            investedAmount
        );
        vm.stopPrank();

        // simulate CEX withdrawal
        vm.startPrank(Constants.cexAddressUsdc);
        IERC20(Constants.usdcAddress).transfer(
            Constants.defiUserAddress,
            withdrawnAmount
        );
        vm.stopPrank();

        // ensure that the job is pending
        (bool upkeepNeeded, bytes memory performData) = ifs.checkUpkeep("0x");
        uint256 defiUserBalance = IERC20(Constants.usdcAddress).balanceOf(
            Constants.defiUserAddress
        );
        assertEq(defiUserBalance, withdrawnAmount);
        assertEq(upkeepNeeded, true);

        bytes32[] memory fsHashesToExecute = new bytes32[](
            Constants.MAX_FORWARDS_PER_BATCH
        );

        uint16 fsHashesToExecuteCount = 1;
        uint16 fsHashesToPopCount = 0;
        fsHashesToExecute[0] = keccak256(
            abi.encode(
                Constants.aavePoolAddressesProvider,
                Constants.usdcAddress,
                investedAmount,
                block.number,
                Constants.defiUserAddress
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
        uint256 aTokenUserBalance = IERC20(Constants.ausdcAddress).balanceOf(
            Constants.defiUserAddress
        );
        assertEq(aTokenUserBalance, investedAmount);

        // check that no job is pending
        (upkeepNeeded, performData) = ifs.checkUpkeep("0x");
        assertEq(upkeepNeeded, false);
        assertEq(performData, "");
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
