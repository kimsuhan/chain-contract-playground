// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {InterestRateModel} from "./InterestRateModel.sol";

contract JumpRateModel is InterestRateModel {
    uint public blocksPerYear;
    uint private constant BASE = 1e18; // 100%
    
    uint public multiplierPerBlock;
    uint public baseRatePerBlock;
    uint public jumpMultiplierPerBlock;
    uint public kink;
    
    constructor(
        uint baseRatePerYear,
        uint multiplierPerYear,
        uint jumpMultiplierPerYear,
        uint kink_
    ) {
        /// 가스비를 아끼기 위해선 상수로 박으면 되지만 현재는 공부중이니까 이더리움 기준 12초 기준으로 계산 (초가 변경된다면 blockTime을 변경)
        uint secondsPerYear = 365 * 24 * 60 * 60; // 31,536,000초
        uint blockTime = 12; // 12초
        blocksPerYear = secondsPerYear / blockTime;

        baseRatePerBlock = baseRatePerYear / blocksPerYear;
        multiplierPerBlock = multiplierPerYear / blocksPerYear;
        jumpMultiplierPerBlock = jumpMultiplierPerYear / blocksPerYear;
        kink = kink_;
    }
    
    function getBorrowRate(
        uint cash,
        uint borrows,
        uint reserves
    ) external view override returns (uint) {
        uint util = utilizationRate(cash, borrows, reserves);
        
        if (util <= kink) {
            return ((util * multiplierPerBlock) / BASE) + baseRatePerBlock;
        } else {
            uint normalRate = ((kink * multiplierPerBlock) / BASE) + baseRatePerBlock;
            uint excessUtil = util - kink;
            return ((excessUtil * jumpMultiplierPerBlock) / BASE) + normalRate;
        }
    }
    
    function getSupplyRate(
        uint cash,
        uint borrows,
        uint reserves,
        uint reserveFactorMantissa
    ) external view override returns (uint) {
        uint oneMinusReserveFactor = BASE - reserveFactorMantissa;
        uint borrowRate = this.getBorrowRate(cash, borrows, reserves);
        uint rateToPool = (borrowRate * oneMinusReserveFactor) / BASE;
        return (utilizationRate(cash, borrows, reserves) * rateToPool) / BASE;
    }
    
    function utilizationRate(
        uint cash,
        uint borrows,
        uint reserves
    ) public pure returns (uint) {
        if (borrows == 0) return 0;
        return (borrows * BASE) / (cash + borrows - reserves);
    }
}