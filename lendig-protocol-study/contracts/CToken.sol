// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./InterestRateModel.sol";
import "./Comptroller.sol";

contract CToken is ERC20, ReentrancyGuard {
    uint internal constant borrowRateMaxMantissa = 0.0005e16; // 0.0005%
    uint internal constant reserveFactorMaxMantissa = 1e18; // 100%
    
    address public underlying; // 기초 자산 (ETH의 경우 0x0)
    Comptroller public comptroller;
    InterestRateModel public interestRateModel;
    
    uint public reserveFactorMantissa;
    uint public accrualBlockNumber;
    uint public borrowIndex;
    uint public totalBorrows;
    uint public totalReserves;
    
    mapping(address => uint) internal accountTokens;
    mapping(address => uint) internal accountBorrows;
    
    struct BorrowSnapshot {
        uint principal;
        uint interestIndex;
    }
    mapping(address => BorrowSnapshot) internal accountBorrowSnapshots;
    
    event Mint(address minter, uint mintAmount, uint mintTokens);
    event Redeem(address redeemer, uint redeemAmount, uint redeemTokens);
    event Borrow(address borrower, uint borrowAmount, uint accountBorrows, uint totalBorrows);
    event RepayBorrow(address payer, address borrower, uint repayAmount, uint accountBorrows, uint totalBorrows);
    
    constructor(
        address underlying_,
        Comptroller comptroller_,
        InterestRateModel interestRateModel_,
        uint reserveFactorMantissa_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {
        underlying = underlying_;
        comptroller = comptroller_;
        interestRateModel = interestRateModel_;
        reserveFactorMantissa = reserveFactorMantissa_;
        accrualBlockNumber = block.number;
        borrowIndex = 1e18;
    }
    
    // 이자 누적 계산
    function accrueInterest() public returns (uint) {
        uint currentBlockNumber = block.number;
        uint accrualBlockNumberPrior = accrualBlockNumber;
        
        if (accrualBlockNumberPrior == currentBlockNumber) {
            return 0; // Already up to date
        }
        
        uint cashPrior = getCash();
        uint borrowsPrior = totalBorrows;
        uint reservesPrior = totalReserves;
        uint borrowIndexPrior = borrowIndex;
        
        uint borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
        require(borrowRateMantissa <= borrowRateMaxMantissa, "Borrow rate too high");
        
        uint blockDelta = currentBlockNumber - accrualBlockNumberPrior;
        uint interestAccumulated = (borrowRateMantissa * blockDelta * borrowsPrior) / 1e18;
        uint totalBorrowsNew = interestAccumulated + borrowsPrior;
        uint totalReservesNew = (reserveFactorMantissa * interestAccumulated) / 1e18 + reservesPrior;
        uint borrowIndexNew = (interestAccumulated * 1e18) / borrowsPrior + borrowIndexPrior;
        
        accrualBlockNumber = currentBlockNumber;
        borrowIndex = borrowIndexNew;
        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;
        
        return 0;
    }
    
    // 예치 (Mint)
    function mint(uint mintAmount) external nonReentrant returns (uint) {
        accrueInterest();
        return mintInternal(mintAmount);
    }
    
    function mintInternal(uint mintAmount) internal returns (uint) {
        // 교환 비율 계산
        uint exchangeRateMantissa = exchangeRateStoredInternal();
        uint mintTokens = (mintAmount * 1e18) / exchangeRateMantissa;
        
        // 토큰 전송
        require(IERC20(underlying).transferFrom(msg.sender, address(this), mintAmount), "Transfer failed");
        
        // cToken 발행
        accountTokens[msg.sender] += mintTokens;
        _mint(msg.sender, mintTokens);
        
        emit Mint(msg.sender, mintAmount, mintTokens);
        return 0;
    }
    
    // 대출 (Borrow)
    function borrow(uint borrowAmount) external nonReentrant returns (uint) {
        accrueInterest();
        return borrowInternal(borrowAmount);
    }
    
    function borrowInternal(uint borrowAmount) internal returns (uint) {
        // 유동성 체크 (Comptroller에서)
        uint allowed = comptroller.borrowAllowed(address(this), msg.sender, borrowAmount);
        require(allowed == 0, "Borrow not allowed");
        
        require(getCash() >= borrowAmount, "Insufficient cash");
        
        // 대출 잔고 업데이트
        BorrowSnapshot storage borrowSnapshot = accountBorrowSnapshots[msg.sender];
        borrowSnapshot.principal = borrowBalanceStoredInternal(msg.sender);
        borrowSnapshot.interestIndex = borrowIndex;
        
        uint accountBorrowsNew = borrowSnapshot.principal + borrowAmount;
        uint totalBorrowsNew = totalBorrows + borrowAmount;
        
        accountBorrowSnapshots[msg.sender].principal = accountBorrowsNew;
        totalBorrows = totalBorrowsNew;
        
        // 토큰 전송
        require(IERC20(underlying).transfer(msg.sender, borrowAmount), "Transfer failed");
        
        emit Borrow(msg.sender, borrowAmount, accountBorrowsNew, totalBorrowsNew);
        return 0;
    }
    
    // 상환 (Repay)
    function repayBorrow(uint repayAmount) external nonReentrant returns (uint) {
        accrueInterest();
        return repayBorrowInternal(repayAmount);
    }
    
    function repayBorrowInternal(uint repayAmount) internal returns (uint) {
        uint accountBorrowsPrev = borrowBalanceStoredInternal(msg.sender);
        uint repayAmountFinal = repayAmount > accountBorrowsPrev ? accountBorrowsPrev : repayAmount;
        
        // 토큰 전송
        require(IERC20(underlying).transferFrom(msg.sender, address(this), repayAmountFinal), "Transfer failed");
        
        // 대출 잔고 업데이트
        uint accountBorrowsNew = accountBorrowsPrev - repayAmountFinal;
        uint totalBorrowsNew = totalBorrows - repayAmountFinal;
        
        accountBorrowSnapshots[msg.sender].principal = accountBorrowsNew;
        accountBorrowSnapshots[msg.sender].interestIndex = borrowIndex;
        totalBorrows = totalBorrowsNew;
        
        emit RepayBorrow(msg.sender, msg.sender, repayAmountFinal, accountBorrowsNew, totalBorrowsNew);
        return 0;
    }
    
    // 인출 (Redeem)
    function redeem(uint redeemTokens) external nonReentrant returns (uint) {
        accrueInterest();
        return redeemInternal(redeemTokens);
    }
    
    function redeemInternal(uint redeemTokens) internal returns (uint) {
        uint exchangeRateMantissa = exchangeRateStoredInternal();
        uint redeemAmount = (redeemTokens * exchangeRateMantissa) / 1e18;
        
        require(getCash() >= redeemAmount, "Insufficient cash");
        
        // 유동성 체크
        uint allowed = comptroller.redeemAllowed(address(this), msg.sender, redeemTokens);
        require(allowed == 0, "Redeem not allowed");
        
        // cToken 소각
        accountTokens[msg.sender] -= redeemTokens;
        _burn(msg.sender, redeemTokens);
        
        // 토큰 전송
        require(IERC20(underlying).transfer(msg.sender, redeemAmount), "Transfer failed");
        
        emit Redeem(msg.sender, redeemAmount, redeemTokens);
        return 0;
    }
    
    // Helper functions
    function getCash() public view returns (uint) {
        return IERC20(underlying).balanceOf(address(this));
    }
    
    function exchangeRateStoredInternal() internal view returns (uint) {
        uint _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            return 1e18; // Initial exchange rate
        } else {
            uint totalCash = getCash();
            uint cashPlusBorrowsMinusReserves = totalCash + totalBorrows - totalReserves;
            return (cashPlusBorrowsMinusReserves * 1e18) / _totalSupply;
        }
    }
    
    function borrowBalanceStoredInternal(address account) internal view returns (uint) {
        BorrowSnapshot storage borrowSnapshot = accountBorrowSnapshots[account];
        if (borrowSnapshot.principal == 0) {
            return 0;
        }
        
        return (borrowSnapshot.principal * borrowIndex) / borrowSnapshot.interestIndex;
    }
}