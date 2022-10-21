// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "./Constants.sol";

library Utils {
    function getTokens() public pure returns (address[] memory) {
        address[] memory tokens = new address[](5);
        tokens[0] = Constants.usdcAddress;
        tokens[1] = Constants.sushiAddress;
        tokens[2] = Constants.daiAddress;
        tokens[3] = Constants.jEurAddress;
        tokens[4] = Constants.aaveAddress;

        return tokens;
    }

    function getCexAddresses() public pure returns (address[] memory) {
        address[] memory cexAddresses = new address[](5);
        cexAddresses[0] = Constants.cexAddressUsdc;
        cexAddresses[1] = Constants.cexAddressSushi;
        cexAddresses[2] = Constants.cexAddressDai;
        cexAddresses[3] = Constants.cexAddressJEur;
        cexAddresses[4] = Constants.cexAddressAave;

        return cexAddresses;
    }

    function getATokens() public pure returns (address[] memory) {
        address[] memory aTokens = new address[](5);
        aTokens[0] = Constants.ausdcAddress;
        aTokens[1] = Constants.asushiAddress;
        aTokens[2] = Constants.adaiAddress;
        aTokens[3] = Constants.ajEurAddress;
        aTokens[4] = Constants.aaaveAddress;

        return aTokens;
    }
}
