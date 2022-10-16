// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/IFS.sol";
import "@openzeppelin/token/ERC20/IERC20.sol";

contract IFSTest is Test {
    IFS public ifs;
    // polygon address
    address constant aavePoolAddressesProvider =
        0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address constant usdcAddress = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address constant ausdcAddress = 0x625E7708f30cA75bfd92586e17077590C60eb4cD;
    // somedoby's address (rich in usdc)
    address constant cexAddress = 0x6E685A45Db4d97BA160FA067cB81b40Dfed47245;

    address constant defiUserAddress =
        0x8dF3aad3a84da6b69A4DA8aeC3eA40d9091B2Ac4;

    function setUp() public {
        ifs = new IFS(msg.sender, aavePoolAddressesProvider);
    }

    function testUpkeepBeforeAnyJob() public {
        (bool upkeepNeeded, bytes memory performData) = ifs.checkUpkeep("0x");
        assertEq(upkeepNeeded, false);
        assertEq(performData, "");
    }

    function testUpkeepWithoutArrivedFunds() public {
        vm.prank(defiUserAddress);
        ifs.addPendingForward(aavePoolAddressesProvider, usdcAddress, 10000);
        (bool upkeepNeeded, bytes memory performData) = ifs.checkUpkeep("0x");
        assertEq(upkeepNeeded, false);
        assertEq(performData, "");
    }

    function testExecution() public {
        uint256 withdrawnAmount = 10000000000;
        uint256 investedAmount = 100000000;

        // user actions
        vm.startPrank(defiUserAddress);
        IERC20(usdcAddress).approve(address(ifs), investedAmount);
        ifs.addPendingForward(
            aavePoolAddressesProvider,
            usdcAddress,
            investedAmount
        );
        vm.stopPrank();

        // simulate CEX withdrawal
        vm.startPrank(address(cexAddress));
        IERC20(usdcAddress).transfer(defiUserAddress, withdrawnAmount);
        vm.stopPrank();

        // ensure that the job is pending
        (bool upkeepNeeded, bytes memory performData) = ifs.checkUpkeep("0x");
        uint256 defiUserBalance = IERC20(usdcAddress).balanceOf(
            defiUserAddress
        );
        assertEq(defiUserBalance, withdrawnAmount);
        assertEq(upkeepNeeded, true);
        assertEq(
            performData,
            abi.encode(
                aavePoolAddressesProvider,
                defiUserAddress,
                usdcAddress,
                investedAmount
            )
        );

        // execute the pending job
        ifs.performUpkeep(performData);

        // ensure that the user has invested the funds
        uint256 aTokenUserBalance = IERC20(ausdcAddress).balanceOf(
            defiUserAddress
        );
        assertEq(aTokenUserBalance, investedAmount);

        // check that no job is pending
        (upkeepNeeded, performData) = ifs.checkUpkeep("0x");
        assertEq(upkeepNeeded, false);
        assertEq(performData, "");
    }

    // TODO test maximum forwards per user revert
}
