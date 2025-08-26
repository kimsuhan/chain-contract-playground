// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {PriceOracle} from "./Comptroller.sol";

contract SimplePriceOracle is PriceOracle {
    mapping(address => uint) prices;
    address admin;

    constructor() {
        admin = msg.sender;
    }

    // 관리자가 수동으로 가격 설정
    function setUnderlyingPrice(
        address cToken,
        uint underlyingPriceMantissa
    ) external {
        require(msg.sender == admin, "only admin");
        prices[cToken] = underlyingPriceMantissa;
    }

    function getUnderlyingPrice(address cToken) external view returns (uint) {
        return prices[cToken];
    }
}
