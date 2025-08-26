// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

// 추상 Contract > 직접 배포가 불가능하며 상속받아 구현해야 함
abstract contract InterestRateModel {
    bool public constant isInterestRateModel = true;
    
    function getBorrowRate(
        uint cash,
        uint borrows,
        uint reserves
    ) external view virtual returns (uint);
    
    function getSupplyRate(
        uint cash,
        uint borrows,
        uint reserves,
        uint reserveFactorMantissa
    ) external view virtual returns (uint);
}